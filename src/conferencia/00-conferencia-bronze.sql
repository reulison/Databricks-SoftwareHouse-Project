-- Conferência da bronze: a ingestão carregou o que a seed 42 promete?
-- Uma linha por tabela, com o esperado e o obtido. Se alguma divergir, o
-- raise_error abaixo derruba a tarefa dizendo qual tabela olhar.

CREATE OR REPLACE TEMPORARY VIEW conferencia_bronze AS
WITH esperado AS (
  SELECT 'projetos'           AS tabela, 60    AS esperado
  UNION ALL SELECT 'status_semanal',      3911
  UNION ALL SELECT 'excel_tarefas',       1663
  UNION ALL SELECT 'clickup_tarefas',     2119
  UNION ALL SELECT 'msproject_tarefas',   1260
  UNION ALL SELECT 'colaboradores',        523
  UNION ALL SELECT 'apontamentos',       30883
  UNION ALL SELECT 'custos',             23640
  UNION ALL SELECT 'entregas_fornecedor',  640
),
obtido AS (
  SELECT 'projetos' AS tabela, COUNT(*) AS obtido FROM lakehouse_vertice.bronze.projetos
  UNION ALL SELECT 'status_semanal',      COUNT(*) FROM lakehouse_vertice.bronze.status_semanal
  UNION ALL SELECT 'excel_tarefas',       COUNT(*) FROM lakehouse_vertice.bronze.excel_tarefas
  UNION ALL SELECT 'clickup_tarefas',     COUNT(*) FROM lakehouse_vertice.bronze.clickup_tarefas
  UNION ALL SELECT 'msproject_tarefas',   COUNT(*) FROM lakehouse_vertice.bronze.msproject_tarefas
  UNION ALL SELECT 'colaboradores',       COUNT(*) FROM lakehouse_vertice.bronze.colaboradores
  UNION ALL SELECT 'apontamentos',        COUNT(*) FROM lakehouse_vertice.bronze.apontamentos
  UNION ALL SELECT 'custos',              COUNT(*) FROM lakehouse_vertice.bronze.custos
  UNION ALL SELECT 'entregas_fornecedor', COUNT(*) FROM lakehouse_vertice.bronze.entregas_fornecedor
)
SELECT e.tabela,
       e.esperado,
       o.obtido,
       o.obtido - e.esperado AS diferenca,
       CASE WHEN o.obtido = e.esperado THEN 'ok' ELSE 'DIVERGENTE' END AS situacao
FROM esperado e
JOIN obtido o USING (tabela);

SELECT raise_error(concat('bronze.', tabela, ': esperado ', esperado, ', obtido ', obtido,
                          '. Olhe a saída da tarefa ingestao_data_lake e a pasta do raw.'))
FROM conferencia_bronze
WHERE diferenca <> 0
LIMIT 1;

SELECT * FROM conferencia_bronze
ORDER BY situacao, tabela;
