-- O texto livre do status vira coluna: causa do bloqueio, o que está travado,
-- quem destrava e quantos dias de impacto. Roda como sql_task no warehouse.
--
-- Três métodos, do mais barato para o mais caro:
--   regra          -> status vazio ou texto que já diz "sem bloqueios"
--   ia             -> últimos 90 dias (163 status): ai_classify + ai_extract 2.0
--   palavra_chave  -> histórico anterior a 18/07/2026, por RLIKE
--
-- A tabela ACUMULA (CREATE TABLE IF NOT EXISTS + MERGE): a IA custa ~5 s por
-- texto e não pode ser refeita a cada execução. Só entra o que ainda não está.

CREATE TABLE IF NOT EXISTS lakehouse_vertice.gold.status_estruturado (
  projeto_id       STRING    COMMENT 'Projeto do status (PRJ-xxx).',
  data_status      DATE      COMMENT 'Sexta a que o status se refere.',
  farol            STRING    COMMENT 'Farol declarado pelo gerente naquela semana: verde, amarelo ou vermelho.',
  causa_bloqueio   STRING    COMMENT 'Causa do bloqueio: change_freeze, falta_sre, dependencia_fornecedor, rotatividade, mudanca_escopo, bug_retrabalho, aprovacao_cliente, sem_bloqueio ou nao_reportado.',
  bloqueio         STRING    COMMENT 'O que está travado, extraído do texto livre do status (só na IA).',
  quem_destrava    STRING    COMMENT 'Quem precisa agir para destravar o projeto, extraído do texto (só na IA).',
  dias_impacto     DOUBLE    COMMENT 'Dias de impacto declarados no status (1 semana = 7 dias).',
  metodo           STRING    COMMENT 'Como a linha foi classificada: regra, ia ou palavra_chave.',
  texto_status     STRING    COMMENT 'Texto original do status semanal, preservado para auditoria.',
  _classificado_em TIMESTAMP COMMENT 'Quando a linha foi classificada e gravada.'
)
COMMENT 'O texto livre do status semanal estruturado: causa do bloqueio, o que está travado, quem destrava e dias de impacto. A IA classifica só os últimos 90 dias; o histórico vem por regra e palavra-chave.';

MERGE INTO lakehouse_vertice.gold.status_estruturado AS alvo
USING (
WITH pendentes AS (
  -- LEFT ANTI JOIN: só o status que ainda não está na tabela. É o que impede
  -- a IA de rodar de novo em cima do que já foi classificado.
  SELECT s.*
  FROM lakehouse_vertice.silver.status_semanal s
  LEFT ANTI JOIN lakehouse_vertice.gold.status_estruturado t
    ON t.projeto_id = s.projeto_id
   AND t.data_status = s.data_status
),
classificado AS (
  SELECT
    projeto_id,
    data_status,
    farol,
    texto_status,
    status_vazio,
    lower(coalesce(texto_status, '')) AS texto,
    CASE
      WHEN status_vazio                                                     THEN 'regra'
      WHEN lower(coalesce(texto_status, '')) LIKE '%bloqueios: nenhum%'
        OR lower(coalesce(texto_status, '')) LIKE '%sem bloqueios%'
        OR lower(coalesce(texto_status, '')) LIKE '%nada relevante%'        THEN 'regra'
      WHEN data_status >= DATE'2026-07-18'                                  THEN 'ia'
      ELSE 'palavra_chave'
    END AS metodo
  FROM pendentes
),
com_regra AS (
  SELECT
    *,
    CASE
      WHEN status_vazio          THEN 'nao_reportado'
      WHEN metodo = 'regra'      THEN 'sem_bloqueio'
      WHEN metodo = 'palavra_chave' THEN
        CASE
          WHEN texto RLIKE 'freeze|congelamento|janela de deploy'                THEN 'change_freeze'
          WHEN texto RLIKE 'sre|infraestrutura|ambiente de homologação'           THEN 'falta_sre'
          WHEN texto RLIKE 'forge|consultoria|fornecedor'                         THEN 'dependencia_fornecedor'
          WHEN texto RLIKE 'saída de|rotatividade|onboarding'                     THEN 'rotatividade'
          WHEN texto RLIKE 'escopo|change request|regra de negócio'               THEN 'mudanca_escopo'
          WHEN texto RLIKE 'bugs|regressão|refazendo'                             THEN 'bug_retrabalho'
          WHEN texto RLIKE 'aprovação do cliente|homologação do cliente'          THEN 'aprovacao_cliente'
          ELSE 'sem_bloqueio'
        END
    END AS causa_bloqueio,
    -- Fora da IA o impacto vem do padrão do texto: "N dias" ou "1 semana".
    CASE WHEN metodo <> 'ia' THEN
      coalesce(
        try_cast(regexp_extract(texto, 'impacto estimado de ([0-9]+) dias', 1) AS DOUBLE),
        CASE WHEN texto RLIKE 'impacto estimado: 1 semana' THEN 7.0 END
      )
    END AS dias_impacto
  FROM classificado
),
ia AS (
  -- Só os 163 status com bloqueio dos últimos 90 dias passam por aqui.
  SELECT
    projeto_id,
    data_status,
    ai_classify(
      texto_status,
      '["change_freeze","falta_sre","dependencia_fornecedor","rotatividade","mudanca_escopo","bug_retrabalho","aprovacao_cliente","sem_bloqueio"]',
      map('version', '2.0')
    ):response[0]::STRING AS causa_ia,
    ai_extract(
      texto_status,
      '{"bloqueio":{"type":"string"},"quem_destrava":{"type":"string"},"dias_impacto":{"type":"number","description":"dias de impacto declarados no texto, 1 semana = 7 dias"}}',
      map('version', '2.0')
    ) AS extracao
  FROM classificado
  WHERE metodo = 'ia'
)
SELECT
  r.projeto_id,
  r.data_status,
  r.farol,
  coalesce(i.causa_ia, r.causa_bloqueio)      AS causa_bloqueio,
  i.extracao:response:bloqueio::STRING        AS bloqueio,
  i.extracao:response:quem_destrava::STRING   AS quem_destrava,
  coalesce(i.extracao:response:dias_impacto::DOUBLE, r.dias_impacto) AS dias_impacto,
  r.metodo,
  r.texto_status,
  current_timestamp()                         AS _classificado_em
FROM com_regra r
LEFT JOIN ia i
  ON i.projeto_id = r.projeto_id
 AND i.data_status = r.data_status
) AS origem
ON alvo.projeto_id = origem.projeto_id
AND alvo.data_status = origem.data_status
WHEN NOT MATCHED THEN INSERT (
  projeto_id, data_status, farol, causa_bloqueio, bloqueio, quem_destrava,
  dias_impacto, metodo, texto_status, _classificado_em
)
VALUES (
  origem.projeto_id, origem.data_status, origem.farol, origem.causa_bloqueio,
  origem.bloqueio, origem.quem_destrava, origem.dias_impacto, origem.metodo,
  origem.texto_status, origem._classificado_em
);

SELECT
  metodo,
  causa_bloqueio,
  count(*)              AS status,
  ROUND(avg(dias_impacto), 1) AS media_dias_impacto
FROM lakehouse_vertice.gold.status_estruturado
GROUP BY metodo, causa_bloqueio
ORDER BY metodo, status DESC;
