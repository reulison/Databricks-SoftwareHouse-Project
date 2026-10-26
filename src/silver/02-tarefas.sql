-- A integração: as três ferramentas viram UMA tabela.
-- Cada temp view abaixo entrega as MESMAS colunas, e o UNION ALL no fim
-- transforma Excel, ClickUp e MS Project num modelo só.

-- 1) Excel: as 20 planilhas. Datas em texto OU número de série, % em três
--    formatos, horas com "h" e uma linha de TOTAL no fim de cada planilha.
CREATE TEMPORARY VIEW tarefas_excel AS
SELECT
  coalesce(p.projeto_id, regexp_extract(e.arquivo, 'PRJ-[0-9]{3}', 0)) AS projeto_id,
  'excel'                                                              AS ferramenta,
  cast(e.id AS STRING)                                                 AS id_na_ferramenta,
  e.fase                                                               AS fase,
  e.tarefa                                                             AS tarefa,
  e.responsavel                                                        AS responsavel,
  coalesce(
    try_to_date(e.inicio_previsto, 'dd/MM/yyyy'),
    date_add(DATE'1899-12-30', try_cast(e.inicio_previsto AS INT))
  )                                                                    AS inicio_baseline,
  coalesce(
    try_to_date(e.termino_previsto, 'dd/MM/yyyy'),
    date_add(DATE'1899-12-30', try_cast(e.termino_previsto AS INT))
  )                                                                    AS fim_baseline,
  coalesce(
    try_to_date(e.inicio_real, 'dd/MM/yyyy'),
    date_add(DATE'1899-12-30', try_cast(e.inicio_real AS INT))
  )                                                                    AS inicio_real,
  coalesce(
    try_to_date(e.termino_real, 'dd/MM/yyyy'),
    date_add(DATE'1899-12-30', try_cast(e.termino_real AS INT))
  )                                                                    AS fim_real,
  -- '45%' e '10,5%' têm o sinal; '0.45' é fração e vira 45.
  CASE
    WHEN instr(e.pct_concluido, '%') > 0
      THEN try_cast(replace(replace(e.pct_concluido, '%', ''), ',', '.') AS DOUBLE)
    ELSE try_cast(replace(e.pct_concluido, ',', '.') AS DOUBLE) * 100
  END                                                                  AS pct_como_veio,
  try_cast(replace(e.horas_previstas, 'h', '') AS DOUBLE)              AS horas,
  cast(NULL AS STRING)                                                 AS status_na_ferramenta
FROM lakehouse_vertice.bronze.excel_tarefas e
LEFT JOIN lakehouse_vertice.bronze.projetos p
  ON p.codigo_ferramenta = e.arquivo
WHERE e.tarefa <> 'TOTAL';

-- 2) ClickUp: datas em milissegundos e %/baseline/fase dentro de custom_fields.
CREATE TEMPORARY VIEW tarefas_clickup AS
SELECT
  coalesce(pc.projeto_id, pn.projeto_id)                               AS projeto_id,
  'clickup'                                                            AS ferramenta,
  c.id                                                                 AS id_na_ferramenta,
  filter(c.custom_fields, f -> f.name = 'Fase')[0].value               AS fase,
  c.name                                                               AS tarefa,
  array_join(transform(c.assignees, a -> a.username), ', ')            AS responsavel,
  to_date(timestamp_millis(try_cast(filter(c.custom_fields, f -> f.name = 'Início baseline')[0].value AS BIGINT))) AS inicio_baseline,
  to_date(timestamp_millis(try_cast(filter(c.custom_fields, f -> f.name = 'Fim baseline')[0].value AS BIGINT)))    AS fim_baseline,
  to_date(timestamp_millis(try_cast(c.start_date AS BIGINT)))          AS inicio_real,
  to_date(timestamp_millis(try_cast(c.date_done AS BIGINT)))           AS fim_real,
  try_cast(filter(c.custom_fields, f -> f.name = 'Progresso (%)')[0].value AS DOUBLE) AS pct_como_veio,
  c.time_estimate / 3600000.0                                          AS horas,
  -- 12 jeitos de escrever status, três estados de verdade.
  CASE
    WHEN lower(c.status.status) IN ('done', 'closed', 'concluído', 'concluida', 'concluída') THEN 'concluida'
    WHEN lower(c.status.status) IN ('backlog', 'to do', 'a fazer')                            THEN 'a_fazer'
    ELSE 'em_andamento'
  END                                                                  AS status_na_ferramenta
FROM lakehouse_vertice.bronze.clickup_tarefas c
LEFT JOIN lakehouse_vertice.bronze.projetos pc
  ON pc.codigo_ferramenta = c.list_id
LEFT JOIN lakehouse_vertice.bronze.projetos pn
  ON pn.nome_projeto = c.list_name;

-- 3) MS Project: só as tarefas folha (Summary = 0; as resumo somam as de baixo),
--    a fase é a última tarefa-resumo de nível 1 acima (por isso a janela roda
--    ANTES do filtro) e as horas vêm como 'PT40H0M0S'.
CREATE TEMPORARY VIEW tarefas_msproject AS
WITH com_fase AS (
  SELECT
    m.*,
    last_value(CASE WHEN m.OutlineLevel = 1 THEN m.Name END, true)
      OVER (PARTITION BY m.arquivo ORDER BY m.UID) AS fase_calculada
  FROM lakehouse_vertice.bronze.msproject_tarefas m
)
SELECT
  p.projeto_id                                                         AS projeto_id,
  'msproject'                                                          AS ferramenta,
  cast(f.UID AS STRING)                                                AS id_na_ferramenta,
  f.fase_calculada                                                     AS fase,
  f.Name                                                               AS tarefa,
  cast(NULL AS STRING)                                                 AS responsavel,
  to_date(f.Baseline.Start)                                            AS inicio_baseline,
  to_date(f.Baseline.Finish)                                           AS fim_baseline,
  to_date(f.ActualStart)                                               AS inicio_real,
  to_date(f.ActualFinish)                                              AS fim_real,
  cast(f.PercentComplete AS DOUBLE)                                    AS pct_como_veio,
  try_cast(regexp_extract(f.Work, 'PT([0-9]+)H', 1) AS DOUBLE)         AS horas,
  cast(NULL AS STRING)                                                 AS status_na_ferramenta
FROM com_fase f
LEFT JOIN lakehouse_vertice.bronze.projetos p
  ON p.codigo_ferramenta = f.arquivo
WHERE f.Summary = 0;

-- 4) O modelo só: 4.917 tarefas (Excel 1.643, ClickUp 2.119, MS Project 1.155).
CREATE OR REFRESH MATERIALIZED VIEW tarefas (
  CONSTRAINT achou_o_projeto  EXPECT (projeto_id IS NOT NULL) ON VIOLATION FAIL UPDATE,
  CONSTRAINT pct_entre_0_e_100 EXPECT (pct_concluido BETWEEN 0 AND 100) ON VIOLATION FAIL UPDATE,
  CONSTRAINT horas_positivas  EXPECT (horas > 0) ON VIOLATION FAIL UPDATE
)
COMMENT 'As tarefas das três ferramentas (Excel, ClickUp e MS Project) num modelo único, com projeto, fase, baseline, realizado, % concluído e horas.'
AS
WITH uniao AS (
  SELECT * FROM tarefas_excel
  UNION ALL
  SELECT * FROM tarefas_clickup
  UNION ALL
  SELECT * FROM tarefas_msproject
)
SELECT
  projeto_id,
  ferramenta,
  concat_ws('-', projeto_id, ferramenta, id_na_ferramenta) AS tarefa_id,
  id_na_ferramenta,
  fase,
  tarefa,
  responsavel,
  inicio_baseline,
  fim_baseline,
  inicio_real,
  fim_real,
  pct_como_veio,
  -- 11 tarefas vieram acima de 100%: o teto é 100, mas a sujeira fica sinalizada.
  least(pct_como_veio, 100)       AS pct_concluido,
  pct_como_veio > 100             AS pct_veio_acima_de_100,
  horas,
  status_na_ferramenta
FROM uniao;
