-- O que o gerente conta toda sexta e o que o financeiro lançou.
-- O status é o único lugar onde existe história: as ferramentas só guardam o % de hoje.

CREATE OR REFRESH MATERIALIZED VIEW status_semanal (
  CONSTRAINT farol_valido EXPECT (farol IN ('verde', 'amarelo', 'vermelho')) ON VIOLATION FAIL UPDATE
)
COMMENT 'O status que cada gerente escreve toda sexta: % concluído, farol do gerente e o texto livre com os bloqueios. É a fonte do histórico de avanço.'
AS
SELECT
  projeto_id,
  try_to_date(data_status, 'yyyy-MM-dd') AS data_status,
  gerente,
  lower(trim(farol))                     AS farol,
  try_cast(pct_concluido AS INT)         AS pct_concluido,
  texto_status,
  -- 51 status vieram vazios ('', 'N/A', 'ver ata da reunião'): não descarta, sinaliza.
  lower(trim(coalesce(texto_status, ''))) IN ('', 'n/a', 'ver ata da reunião') AS status_vazio
FROM lakehouse_vertice.bronze.status_semanal;

CREATE OR REFRESH MATERIALIZED VIEW custos (
  CONSTRAINT valor_numerico EXPECT (valor IS NOT NULL) ON VIOLATION FAIL UPDATE
)
COMMENT 'Lançamentos de custo real por projeto e categoria (pessoal, consultoria, cloud, licenças, despesas). 671 linhas vieram com vírgula decimal e 331 são estornos negativos.'
AS
SELECT
  lancamento_id,
  projeto_id,
  try_to_date(data, 'yyyy-MM-dd')                                        AS data,
  categoria,
  descricao,
  -- 671 valores vêm como '12345,67'. O replace vem ANTES do cast: try_cast jogaria
  -- R$ 5,4 mi fora em silêncio.
  cast(replace(valor, ',', '.') AS DECIMAL(18, 2))                       AS valor,
  -- Estorno é custo negativo: fica (o custo é líquido) e vai sinalizado.
  cast(replace(valor, ',', '.') AS DECIMAL(18, 2)) < 0                   AS estorno,
  centro_custo,
  -- A semana é a sexta: segunda + 4 dias.
  date_add(date_trunc('WEEK', try_to_date(data, 'yyyy-MM-dd')), 4)       AS semana
FROM lakehouse_vertice.bronze.custos;
