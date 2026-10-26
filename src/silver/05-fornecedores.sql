-- As entregas das consultorias: o prometido contra o entregue. É a pergunta 4
-- (o que vai dar errado no próximo mês) na parte de fornecedor.

CREATE OR REFRESH MATERIALIZED VIEW entregas_fornecedor (
  CONSTRAINT prazo_conhecido EXPECT (data_prometida IS NOT NULL) ON VIOLATION FAIL UPDATE
)
COMMENT 'As 640 entregas das consultorias: o que foi prometido, o que foi entregue, o prazo contratado e se a entrega está em aberto ou em atraso.'
AS
WITH base AS (
  SELECT
    *,
    -- A CodeForge aparece de 4 jeitos: 'CodeForge Consultoria Ltda', 'Codeforge Consultoria',
    -- 'CODEFORGE CONSULTORIA LTDA' e 'Code Forge Consultoria'.
    CASE
      WHEN replace(lower(fornecedor), ' ', '') LIKE '%codeforge%' THEN 'CodeForge Consultoria Ltda'
      ELSE trim(fornecedor)
    END AS fornecedor_normalizado,
    try_to_date(data_pedido, 'yyyy-MM-dd')     AS pedido,
    try_to_date(data_prometida, 'yyyy-MM-dd')  AS prometido,
    try_to_date(data_entrega, 'yyyy-MM-dd')    AS entregue
  FROM lakehouse_vertice.bronze.entregas_fornecedor
)
SELECT
  entrega_id,
  projeto_id,
  fornecedor                                   AS fornecedor_como_veio,
  fornecedor_normalizado                       AS fornecedor,
  item,
  try_cast(replace(valor, ',', '.') AS DECIMAL(18, 2)) AS valor,
  pedido                                       AS data_pedido,
  prometido                                    AS data_prometida,
  entregue                                     AS data_entrega,
  try_cast(prazo_contratado_dias AS INT)       AS prazo_contratado_dias,
  status,
  datediff(prometido, pedido)                  AS prazo_prometido_dias,
  datediff(entregue, pedido)                   AS prazo_real_dias,
  datediff(entregue, prometido)                AS dias_de_atraso_na_entrega,
  -- Data de entrega vazia não é sujeira: é uma entrega que ainda não aconteceu.
  entregue IS NULL                             AS em_aberto,
  entregue IS NULL AND prometido < DATE'2026-10-16' AS em_atraso
FROM base;
