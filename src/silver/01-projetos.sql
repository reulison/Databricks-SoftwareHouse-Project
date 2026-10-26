-- O cadastro do PMO. É o de-para: ferramenta + código na ferramenta ligam
-- cada tarefa ao seu projeto. Tudo que está em texto na bronze vira tipo aqui.

CREATE OR REFRESH MATERIALIZED VIEW projetos (
  CONSTRAINT data_inicio_obrigatoria EXPECT (data_inicio IS NOT NULL) ON VIOLATION FAIL UPDATE,
  CONSTRAINT ferramenta_conhecida EXPECT (ferramenta IN ('excel', 'clickup', 'msproject')) ON VIOLATION FAIL UPDATE
)
COMMENT 'Cadastro dos 60 projetos da Vértice: cliente, segmento, contrato, orçamento e o de-para (ferramenta + código na ferramenta) que liga as tarefas ao projeto.'
AS
SELECT
  projeto_id,
  nome_projeto,
  cliente,
  segmento,
  tipo_projeto,
  ferramenta AS ferramenta_como_veio,
  -- "Ferramenta" escrita de 8 jeitos: Excel / Planilha / excel, ClickUp / clickup, MS Project / Project / msproject.
  CASE
    WHEN lower(ferramenta) LIKE '%excel%'    THEN 'excel'
    WHEN lower(ferramenta) LIKE '%planilha%' THEN 'excel'
    WHEN lower(ferramenta) LIKE '%clickup%'  THEN 'clickup'
    WHEN lower(ferramenta) LIKE '%project%'  THEN 'msproject'
  END AS ferramenta,
  -- Dois projetos vieram sem código: a tarefa se acha pelo nome do arquivo (Excel) ou da lista (ClickUp).
  nullif(trim(codigo_ferramenta), '') AS codigo_ferramenta,
  cast(replace(valor_contrato, ',', '.') AS DECIMAL(18, 2))     AS valor_contrato,
  cast(replace(orcamento_custo, ',', '.') AS DECIMAL(18, 2))    AS orcamento_custo,
  -- 24 de 60 vêm em dd/MM/yyyy e o resto em yyyy-MM-dd.
  coalesce(
    try_to_date(data_inicio, 'yyyy-MM-dd'),
    try_to_date(data_inicio, 'dd/MM/yyyy')
  ) AS data_inicio,
  try_to_date(data_fim_baseline, 'yyyy-MM-dd') AS data_fim_baseline,
  status,
  gerente_projeto
FROM lakehouse_vertice.bronze.projetos;
