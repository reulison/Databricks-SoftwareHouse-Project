-- A história que as ferramentas não guardam: uma linha por projeto e por sexta.
-- PV (o que o cronograma prometia), EV (o que o status dizia) e AC (o que foi gasto).
-- O "hoje" do dataset é 16/10/2026 — nunca current_date().

CREATE OR REFRESH MATERIALIZED VIEW lakehouse_vertice.gold.fato_projeto_semana (
  CONSTRAINT pv_nao_negativo       EXPECT (pv >= 0) ON VIOLATION FAIL UPDATE,
  CONSTRAINT ev_dentro_do_orcamento EXPECT (ev <= orcamento) ON VIOLATION FAIL UPDATE
)
COMMENT 'Uma linha por projeto e semana (sexta), da semana de início até 16/10/2026: PV, EV, AC, SPI, CPI, EAC, farol do gerente e horas das pessoas naquela semana.'
AS
WITH semanas AS (
  -- A grade de sextas de cada projeto: date_trunc('WEEK') dá a segunda, +4 dá a sexta.
  SELECT
    p.projeto_id,
    p.orcamento_custo,
    explode(
      sequence(
        date_add(date_trunc('WEEK', p.data_inicio), 4),
        DATE'2026-10-16',
        INTERVAL 1 WEEK
      )
    ) AS semana
  FROM lakehouse_vertice.silver.projetos p
),
peso AS (
  -- PV: orçamento × Σ(horas × fração do baseline decorrida até a semana) ÷ Σ horas.
  SELECT
    s.projeto_id,
    s.semana,
    SUM(t.horas * greatest(0.0, least(1.0,
      coalesce(
        try_divide(datediff(s.semana, t.inicio_baseline),
                   nullif(datediff(t.fim_baseline, t.inicio_baseline), 0)),
        1.0)
    ))) AS horas_ponderadas,
    SUM(t.horas) AS horas_total
  FROM semanas s
  JOIN lakehouse_vertice.silver.tarefas t ON t.projeto_id = s.projeto_id
  GROUP BY s.projeto_id, s.semana
),
status_carregado AS (
  -- EV: o % do status daquela sexta. Projeto concluído para de publicar:
  -- o último % publicado continua valendo (last_value com ignoreNulls).
  SELECT
    s.projeto_id,
    s.semana,
    last_value(st.pct_concluido, true) OVER w AS pct_status,
    last_value(st.farol, true)         OVER w AS farol_gerente
  FROM semanas s
  LEFT JOIN lakehouse_vertice.silver.status_semanal st
    ON st.projeto_id = s.projeto_id
   AND st.data_status = s.semana
  WINDOW w AS (
    PARTITION BY s.projeto_id
    ORDER BY s.semana
    ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
  )
),
acumulado AS (
  -- AC: tudo que foi lançado no projeto até a semana.
  SELECT
    s.projeto_id,
    s.semana,
    SUM(c.valor) AS ac
  FROM semanas s
  JOIN lakehouse_vertice.silver.custos c
    ON c.projeto_id = s.projeto_id
   AND c.semana <= s.semana
  GROUP BY s.projeto_id, s.semana
),
horas AS (
  SELECT
    projeto_id,
    semana,
    SUM(horas_disponiveis) AS horas_disponiveis,
    SUM(horas_apontadas)   AS horas_apontadas
  FROM lakehouse_vertice.silver.apontamentos
  GROUP BY projeto_id, semana
),
base AS (
  SELECT
    s.projeto_id,
    s.semana,
    s.orcamento_custo                                                   AS orcamento,
    s.orcamento_custo * coalesce(pe.horas_ponderadas, 0) / nullif(pe.horas_total, 0) AS pv,
    s.orcamento_custo * coalesce(sc.pct_status, 0) / 100.0              AS ev,
    coalesce(a.ac, 0)                                                   AS ac,
    sc.farol_gerente,
    coalesce(h.horas_disponiveis, 0)                                    AS horas_disponiveis,
    coalesce(h.horas_apontadas, 0)                                      AS horas_apontadas
  FROM semanas s
  LEFT JOIN peso pe             ON pe.projeto_id = s.projeto_id AND pe.semana = s.semana
  LEFT JOIN status_carregado sc ON sc.projeto_id = s.projeto_id AND sc.semana = s.semana
  LEFT JOIN acumulado a         ON a.projeto_id  = s.projeto_id AND a.semana  = s.semana
  LEFT JOIN horas h             ON h.projeto_id  = s.projeto_id AND h.semana  = s.semana
)
SELECT
  projeto_id,
  semana,
  ROUND(orcamento, 2)                                   AS orcamento,
  ROUND(coalesce(pv, 0), 2)                             AS pv,
  ROUND(ev, 2)                                          AS ev,
  ROUND(ac, 2)                                          AS ac,
  ROUND(try_divide(ev, coalesce(pv, 0)), 4)             AS spi,
  ROUND(try_divide(ev, nullif(ac, 0)), 4)               AS cpi,
  ROUND(try_divide(orcamento, try_divide(ev, nullif(ac, 0))), 2) AS eac,
  farol_gerente                                         AS farol_do_gerente,
  ROUND(horas_disponiveis, 1)                           AS horas_disponiveis,
  ROUND(horas_apontadas, 1)                             AS horas_apontadas,
  ROUND(horas_disponiveis - horas_apontadas, 1)         AS horas_ociosas
FROM base;
