-- A fotografia de hoje (16/10/2026) e a foto de cada pessoa por semana.
-- Não existe dim_projeto: o cadastro já vem na fotografia, e fornecedor é lido
-- direto da silver.entregas_fornecedor.

CREATE OR REFRESH MATERIALIZED VIEW lakehouse_vertice.gold.projeto_situacao_atual (
  CONSTRAINT spi_e_cpi_em_andamento
    EXPECT (status <> 'em_andamento' OR (spi IS NOT NULL AND cpi IS NOT NULL)) ON VIOLATION FAIL UPDATE
)
COMMENT 'A fotografia de 16/10/2026 dos 60 projetos: cadastro do PMO + PV, EV, AC, SPI, CPI, EAC, estouro previsto, margem, atraso projetado, situação, farol do gerente, farol calculado e melancia.'
AS
WITH peso AS (
  -- Aqui o EV usa o % de HOJE das ferramentas (o status semanal é o histórico).
  SELECT
    projeto_id,
    SUM(horas * greatest(0.0, least(1.0,
      coalesce(
        try_divide(datediff(DATE'2026-10-16', inicio_baseline),
                   nullif(datediff(fim_baseline, inicio_baseline), 0)),
        1.0)
    ))) AS horas_ponderadas_prazo,
    SUM(horas * coalesce(pct_concluido, 0) / 100.0) AS horas_ev,
    SUM(horas) AS horas_total
  FROM lakehouse_vertice.silver.tarefas
  GROUP BY projeto_id
),
custo AS (
  SELECT projeto_id, SUM(valor) AS ac
  FROM lakehouse_vertice.silver.custos
  GROUP BY projeto_id
),
status_hoje AS (
  SELECT projeto_id, farol
  FROM (
    SELECT
      projeto_id,
      farol,
      row_number() OVER (PARTITION BY projeto_id ORDER BY data_status DESC) AS ordem
    FROM lakehouse_vertice.silver.status_semanal
    WHERE data_status <= DATE'2026-10-16'
  )
  WHERE ordem = 1
),
base AS (
  SELECT
    p.projeto_id,
    concat_ws(' · ', p.projeto_id, p.nome_projeto) AS projeto,
    p.nome_projeto,
    p.cliente,
    p.segmento,
    p.tipo_projeto,
    p.ferramenta,
    p.gerente_projeto,
    p.valor_contrato,
    p.orcamento_custo AS orcamento,
    p.data_inicio,
    p.data_fim_baseline,
    datediff(p.data_fim_baseline, p.data_inicio) AS duracao_baseline_dias,
    p.status,
    p.orcamento_custo * coalesce(pe.horas_ponderadas_prazo, 0) / nullif(pe.horas_total, 0) AS pv,
    p.orcamento_custo * coalesce(pe.horas_ev, 0) / nullif(pe.horas_total, 0)              AS ev,
    coalesce(c.ac, 0) AS ac,
    sh.farol AS farol_do_gerente
  FROM lakehouse_vertice.silver.projetos p
  LEFT JOIN peso        pe ON pe.projeto_id = p.projeto_id
  LEFT JOIN custo       c  ON c.projeto_id  = p.projeto_id
  LEFT JOIN status_hoje sh ON sh.projeto_id = p.projeto_id
),
kpi AS (
  SELECT
    *,
    try_divide(ev, pv)               AS spi,
    try_divide(ev, nullif(ac, 0))    AS cpi
  FROM base
)
SELECT
  projeto_id,
  projeto,
  nome_projeto,
  cliente,
  segmento,
  tipo_projeto,
  ferramenta,
  gerente_projeto,
  valor_contrato,
  orcamento,
  data_inicio,
  data_fim_baseline,
  duracao_baseline_dias,
  status,
  ROUND(pv, 2) AS pv,
  ROUND(ev, 2) AS ev,
  ROUND(ac, 2) AS ac,
  ROUND(spi, 4) AS spi,
  ROUND(cpi, 4) AS cpi,
  ROUND(try_divide(orcamento, cpi), 2)                                          AS eac,
  ROUND(greatest(try_divide(orcamento, cpi) - orcamento, 0), 2)                 AS estouro_previsto,
  ROUND(try_divide(valor_contrato - try_divide(orcamento, cpi), valor_contrato), 4) AS margem_projetada,
  ROUND(try_divide(duracao_baseline_dias, spi) - duracao_baseline_dias, 1)      AS atraso_projetado_dias,
  date_add(
    data_fim_baseline,
    cast(round(try_divide(duracao_baseline_dias, spi) - duracao_baseline_dias) AS INT)
  )                                                                             AS termino_projetado,
  CASE
    WHEN status <> 'em_andamento'      THEN 'concluído'
    WHEN spi < 0.8 OR cpi < 0.8        THEN 'crítico'
    WHEN spi < 0.9 OR cpi < 0.9        THEN 'atenção'
    ELSE 'ok'
  END                                                                           AS situacao,
  farol_do_gerente,
  CASE
    WHEN spi >= 0.95 THEN 'verde'
    WHEN spi >= 0.90 THEN 'amarelo'
    ELSE 'vermelho'
  END                                                                           AS farol_calculado,
  (status = 'em_andamento' AND farol_do_gerente = 'verde' AND spi < 0.9)        AS melancia
FROM kpi;

CREATE OR REFRESH MATERIALIZED VIEW lakehouse_vertice.gold.utilizacao_pessoa_semana (
  CONSTRAINT horas_apontadas_nao_negativas EXPECT (horas_apontadas >= 0) ON VIOLATION FAIL UPDATE
)
COMMENT 'Pessoa × projeto × semana: horas disponíveis, apontadas e ociosas, utilização, custo do ócio e o SPI do projeto naquela semana. É a base da pergunta 3.'
AS
SELECT
  a.colaborador_id,
  c.nome,
  c.papel,
  c.senioridade,
  a.projeto_id,
  a.semana,
  a.horas_disponiveis,
  a.horas_apontadas,
  a.horas_disponiveis - a.horas_apontadas                                  AS horas_ociosas,
  ROUND(try_divide(a.horas_apontadas, a.horas_disponiveis), 4)             AS utilizacao,
  ROUND((a.horas_disponiveis - a.horas_apontadas) * c.custo_hora, 2)       AS custo_ocioso,
  f.spi                                                                    AS spi_do_projeto
FROM lakehouse_vertice.silver.apontamentos a
JOIN lakehouse_vertice.silver.colaboradores c
  ON c.colaborador_id = a.colaborador_id
LEFT JOIN lakehouse_vertice.gold.fato_projeto_semana f
  ON f.projeto_id = a.projeto_id
 AND f.semana = a.semana;
