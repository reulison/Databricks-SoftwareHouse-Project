-- Quem são as pessoas e quanto cada uma trabalhou. É a base da pergunta 3
-- (gente parada enquanto outro projeto pede gente).

CREATE OR REFRESH MATERIALIZED VIEW colaboradores (
  CONSTRAINT colaborador_unico EXPECT (colaborador_id IS NOT NULL) ON VIOLATION FAIL UPDATE
)
COMMENT 'Cadastro das 520 pessoas da Vértice, uma linha por colaborador: papel, senioridade, custo/hora, admissão e desligamento.'
AS
WITH deduplicado AS (
  SELECT
    *,
    -- Três pessoas vieram cadastradas duas vezes (COL0102, COL0257, COL0433),
    -- a segunda cópia com nome e papel em CAIXA ALTA. Fica o cadastro com papel em minúsculas.
    row_number() OVER (
      PARTITION BY colaborador_id
      ORDER BY (papel = lower(papel)) DESC, nome
    ) AS ordem
  FROM lakehouse_vertice.bronze.colaboradores
)
SELECT
  colaborador_id,
  nome,
  lower(trim(papel))                                    AS papel,
  senioridade,
  try_cast(custo_hora AS DECIMAL(10, 2))                AS custo_hora,
  try_to_date(data_admissao, 'yyyy-MM-dd')              AS data_admissao,
  try_to_date(data_desligamento, 'yyyy-MM-dd')          AS data_desligamento
FROM deduplicado
WHERE ordem = 1;

CREATE OR REFRESH MATERIALIZED VIEW apontamentos (
  CONSTRAINT horas_nao_negativas EXPECT (horas_apontadas >= 0) ON VIOLATION FAIL UPDATE
)
COMMENT 'Timesheet semanal: para cada pessoa e projeto, as horas disponíveis e as horas apontadas na semana. A semana é identificada pela sexta.'
AS
SELECT
  colaborador_id,
  projeto_id,
  try_to_date(semana_inicio, 'yyyy-MM-dd')                        AS semana_inicio,
  date_add(try_to_date(semana_inicio, 'yyyy-MM-dd'), 4)           AS semana,
  try_cast(horas_disponiveis AS DOUBLE)                           AS horas_disponiveis,
  try_cast(horas_apontadas AS DOUBLE)                             AS horas_apontadas
FROM lakehouse_vertice.bronze.apontamentos;
