-- Os 10 testes de qualidade. Cada bloco devolve uma linha SÓ quando o teste falha,
-- então a lista `falhas` vazia é o sucesso. No fim, se houver qualquer linha,
-- o raise_error derruba a tarefa dizendo qual teste falhou e onde olhar.

CREATE OR REPLACE TEMPORARY VIEW falhas AS
SELECT '1. os 60 projetos têm cronograma na silver.tarefas' AS teste,
       concat(n, ' projeto(s) sem tarefa na silver') AS detalhe
FROM (
  SELECT COUNT(*) AS n
  FROM lakehouse_vertice.silver.projetos p
  WHERE NOT EXISTS (
    SELECT 1 FROM lakehouse_vertice.silver.tarefas t WHERE t.projeto_id = p.projeto_id
  )
) x
WHERE n > 0

UNION ALL
SELECT '2. cada projeto veio de UMA ferramenta, a do cadastro do PMO',
       concat(n, ' projeto(s) com ferramenta divergente')
FROM (
  SELECT COUNT(*) AS n
  FROM (
    SELECT t.projeto_id
    FROM lakehouse_vertice.silver.tarefas t
    JOIN lakehouse_vertice.silver.projetos p ON p.projeto_id = t.projeto_id
    GROUP BY t.projeto_id, p.ferramenta
    HAVING COUNT(DISTINCT t.ferramenta) > 1 OR max(t.ferramenta) <> p.ferramenta
  ) y
) x
WHERE n > 0

UNION ALL
SELECT '3. as horas do Excel na silver = a soma das linhas de TOTAL das planilhas',
       concat('silver ', ROUND(s.h, 1), ' × planilhas ', ROUND(b.h, 1))
FROM (SELECT SUM(horas) AS h FROM lakehouse_vertice.silver.tarefas WHERE ferramenta = 'excel') s
CROSS JOIN (
  SELECT SUM(try_cast(replace(horas_previstas, 'h', '') AS DOUBLE)) AS h
  FROM lakehouse_vertice.bronze.excel_tarefas
  WHERE tarefa = 'TOTAL'
) b
WHERE abs(s.h - b.h) > 0.01

UNION ALL
SELECT '4. uma linha por pessoa na silver',
       concat(n, ' linha(s) duplicada(s)')
FROM (
  SELECT COUNT(*) - COUNT(DISTINCT colaborador_id) AS n
  FROM lakehouse_vertice.silver.colaboradores
) x
WHERE n > 0

UNION ALL
SELECT '5. a CodeForge virou um fornecedor só',
       concat(n, ' grafia(s) de CodeForge')
FROM (
  SELECT COUNT(DISTINCT fornecedor) AS n
  FROM lakehouse_vertice.silver.entregas_fornecedor
  WHERE lower(replace(fornecedor, ' ', '')) LIKE '%codeforge%'
) x
WHERE n <> 1

UNION ALL
SELECT '6. a limpeza não mudou o custo total',
       concat('silver ', ROUND(s.t, 2), ' × bronze ', ROUND(b.t, 2))
FROM (SELECT SUM(valor) AS t FROM lakehouse_vertice.silver.custos) s
CROSS JOIN (
  SELECT SUM(try_cast(replace(valor, ',', '.') AS DOUBLE)) AS t
  FROM lakehouse_vertice.bronze.custos
) b
WHERE abs(s.t - b.t) > 0.01

UNION ALL
SELECT '7. os 60 projetos têm fotografia de hoje',
       concat(n, ' linha(s) na projeto_situacao_atual')
FROM (SELECT COUNT(*) AS n FROM lakehouse_vertice.gold.projeto_situacao_atual) x
WHERE n <> 60

UNION ALL
SELECT '8. todo projeto em andamento tem SPI e CPI',
       concat(n, ' projeto(s) em andamento sem SPI ou CPI')
FROM (
  SELECT COUNT(*) AS n
  FROM lakehouse_vertice.gold.projeto_situacao_atual
  WHERE status = 'em_andamento' AND (spi IS NULL OR cpi IS NULL)
) x
WHERE n > 0

UNION ALL
SELECT '9. o EV de hoje do status semanal bate com o das ferramentas (diferença < 1%)',
       concat('status ', ROUND(s.ev, 2), ' × tarefas ', ROUND(t.ev, 2))
FROM (
  SELECT SUM(p.orcamento_custo * st.pct / 100.0) AS ev
  FROM lakehouse_vertice.silver.projetos p
  JOIN (
    SELECT projeto_id, max_by(pct_concluido, data_status) AS pct
    FROM lakehouse_vertice.silver.status_semanal
    WHERE data_status <= DATE'2026-10-16'
    GROUP BY projeto_id
  ) st ON st.projeto_id = p.projeto_id
  WHERE p.status = 'em_andamento'
) s
CROSS JOIN (
  SELECT SUM(p.orcamento_custo * x.frac) AS ev
  FROM lakehouse_vertice.silver.projetos p
  JOIN (
    SELECT projeto_id, SUM(horas * coalesce(pct_concluido, 0) / 100.0) / SUM(horas) AS frac
    FROM lakehouse_vertice.silver.tarefas
    GROUP BY projeto_id
  ) x ON x.projeto_id = p.projeto_id
  WHERE p.status = 'em_andamento'
) t
WHERE abs(s.ev - t.ev) > 0.01 * s.ev

UNION ALL
SELECT '10. AC de hoje no fato = a soma dos lançamentos até hoje',
       concat('fato ', ROUND(f.ac, 2), ' × custos ', ROUND(c.ac, 2))
FROM (
  SELECT SUM(ac) AS ac
  FROM lakehouse_vertice.gold.fato_projeto_semana
  WHERE semana = DATE'2026-10-16'
) f
CROSS JOIN (
  SELECT SUM(valor) AS ac
  FROM lakehouse_vertice.silver.custos
  WHERE semana <= DATE'2026-10-16'
) c
WHERE abs(f.ac - c.ac) > 0.01;

SELECT raise_error(concat('TESTE ', teste, ' FALHOU: ', detalhe)) AS erro
FROM falhas;
