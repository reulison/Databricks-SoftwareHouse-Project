# Projeto Farol · Vértice Tecnologia

Torre de controle de portfólio sobre o Databricks. Um único bundle cria a
ingestão, o medalhão (bronze → silver → gold), a classificação por IA do texto
livre dos status, os testes de qualidade e o dashboard executivo — tudo rodando
sozinho toda segunda-feira às 6h.

O problema: 60 projetos e 520 pessoas espalhados por Excel, ClickUp e MS Project.
A Torre consolida as três ferramentas num modelo só e responde quatro perguntas:

1. Quais projetos estão atrasados, e de quais clientes?
2. Quanto esse atraso vai custar?
3. Tenho gente parada enquanto outro projeto pede gente?
4. O que vai dar errado no próximo mês?

> Os dados são **sintéticos**. O catálogo `lakehouse_vertice` não contém
> informação real de clientes ou pessoas.

## Arquitetura

```
job vertice_farol · toda segunda às 6h (America/Sao_Paulo)
│
├── ingestao_feriados      notebook  BrasilAPI → bronze.feriados
├── ingestao_data_lake     notebook  storage S3 → volume bronze.raw → 9 tabelas
│        │
│        ▼
├── conferencia_bronze     sql_task  valida a bronze antes de transformar
│        │
│        ▼
├── medalhao               pipeline  silver ×7 → gold ×3
│        │
│        ├── testes_de_qualidade   sql_task  10 testes; falha derruba a tarefa
│        └── status_com_ia         sql_task  ai_classify + ai_extract no status
│
└── dashboard_portfolio    AI/BI dashboard (recurso do bundle)
```

- **Bronze**: 9 tabelas cruas, com a sujeira preservada (datas em dois formatos,
  vírgula decimal, status escrito de 12 jeitos, linhas de TOTAL, tarefas-resumo).
- **Silver**: `projetos`, `tarefas` (as três ferramentas num modelo só),
  `status_semanal`, `custos`, `colaboradores`, `apontamentos`,
  `entregas_fornecedor`.
- **Gold**: `fato_projeto_semana`, `projeto_situacao_atual`,
  `utilizacao_pessoa_semana` e `status_estruturado`.

`gold.status_estruturado` acumula: `MERGE` só insere status novos. A IA roda uma
única vez sobre os status com bloqueio dos últimos 90 dias; o histórico anterior
é classificado por palavra-chave e o texto sem bloqueio por regra.

## Estrutura do repositório

```
databricks.yml                        bundle, variáveis e targets
resources/
  vertice.job.yml                     job completo (6 tarefas + agendamento)
  vertice_medalhao.pipeline.yml       pipeline declarativo silver + gold
  dashboard.dashboard.yml             recurso do dashboard
  dashboard-portfolio.lvdash.json     dashboard gerado (AI/BI, GRID_V1)
scripts/
  gerar_dashboard.py                  gera o JSON do dashboard
  run_sql.py                          executa SQL no warehouse pela API de statements
src/
  ingestao/                           notebooks serverless de ingestão
  conferencia/                        conferência da bronze
  silver/                             limpeza e integração
  gold/                               KPIs, histórico e utilização
  ia/                                 status estruturado com AI Functions
  testes/                             testes de qualidade
```

## Como rodar

Pré-requisitos: Databricks CLI autenticada e um SQL warehouse serverless.

```bash
# 1. autentique-se no seu workspace
databricks auth login --host https://<seu-workspace>.cloud.databricks.com

# 2. crie o arquivo local com as chaves do data lake (não versionado)
#    .databricks/bundle/dev/variable-overrides.json
#    {"s3_access_key_id": "...", "s3_secret_access_key": "..."}

# 3. valide, faça o deploy e rode
databricks bundle validate --profile <perfil>
databricks bundle deploy --profile <perfil>
databricks bundle run vertice_farol --profile <perfil>
```

### Dashboard

O dashboard é gerado a partir do código:

```bash
python scripts/gerar_dashboard.py
databricks bundle deploy --profile <perfil>
```

![Porfólio](/dashboard/screencapture-dbc-973f5fb1-b24a-cloud-databricks-dashboardsv3.png)
![Pessoas](/dashboard/screencapture-dbc-973f5fb1-b24a-cloud-databricks-dashboardsv3-01f1d18dec8b1bee9f76dcdde8765c7e.png)
![Fornecedores](/dashboard/screencapture-dbc-973f5fb1-b24a-cloud-databricks-dashboardsv3-01f1d18dec8b1bee9f76dcdde8765c7e-published.png)


Variáveis do bundle: `catalog` (padrão `lakehouse_vertice`), `warehouse_id`
(resolvido pelo nome `Serverless Starter Warehouse`), `s3_access_key_id`,
`s3_secret_access_key` e `aws_default_region`.

## Segurança

- As chaves do data lake chegam ao notebook como parâmetros da tarefa.
- O valor fica em `.databricks/bundle/<target>/variable-overrides.json`, fora do Git.
- O `.gitignore` bloqueia estado local, segredos, arquivos de ambiente e IDE.
- Nenhuma chave, token ou credencial é versionada.

## Números de referência (dataset sintético)

| Indicador | Valor |
|---|---|
| Tarefas na silver | 4.917 (Excel 1.643, ClickUp 2.119, MS Project 1.155) |
| Projetos em andamento | 41 (19 concluídos) |
| Projetos críticos / em atenção | 7 / 10 |
| Estouro previsto | R$ 6,47 mi |
| SPI / CPI da carteira | 0,92 / 0,97 |
| Melancias | 4 |
| Custo real total | R$ 193,35 mi |
| Status classificados pela IA | 163 |
