#!/usr/bin/env python3
"""Gera resources/dashboard-portfolio.lvdash.json (AI/BI, GRID_V1).

As queries da gold usam o nome PURO da tabela: o recurso do bundle
(resources/dashboard.dashboard.yml) informa dataset_catalog=${var.catalog} e
dataset_schema=gold. A silver.entregas_fornecedor vai com o nome completo,
porque não é do schema gold.

Uso:
  python scripts/gerar_dashboard.py
"""
import json
from pathlib import Path

RAIZ = Path(__file__).resolve().parent.parent
SAIDA = RAIZ / "resources" / "dashboard-portfolio.lvdash.json"


def sql(texto: str) -> list[str]:
    """queryLines: cada linha termina em \\n (o dashboard concatena sem separador)."""
    linhas = [l.strip() for l in texto.strip().splitlines()]
    return [l + "\n" for l in linhas]


def texto(nome: str, linhas: list[str], y: int, altura: int = 2) -> dict:
    return {
        "widget": {
            "name": nome,
            "multilineTextboxSpec": {"lines": linhas},
        },
        "position": {"x": 0, "y": y, "width": 12, "height": altura},
    }


def campo(nome: str, expressao: str, agrupado: bool = False) -> dict:
    return {
        "name": nome,
        "expression": expressao,
        "disaggregated": agrupado,
    }


def kpi(nome, titulo, medida, x, y, largura, formato, altura=3):
    return {
        "widget": {
            "name": nome,
            "queries": [
                {
                    "name": "main_query",
                    "query": {
                        "datasetName": "ds_projetos",
                        "fields": [
                            {"name": f"measure({medida})", "expression": f"MEASURE(`{medida}`)"}
                        ],
                        "disaggregated": False,
                    },
                }
            ],
            "spec": {
                "version": 2,
                "widgetType": "counter",
                "encodings": {
                    "value": {
                        "fieldName": f"measure({medida})",
                        "displayName": titulo,
                        "format": formato,
                    }
                },
                "frame": {"title": titulo, "showTitle": True},
            },
        },
        "position": {"x": x, "y": y, "width": largura, "height": altura},
    }


MOEDA = {
    "type": "number-currency",
    "currencyCode": "BRL",
    "abbreviation": "compact",
    "decimalPlaces": {"type": "max", "places": 2},
}
DECIMAL = {"type": "number-plain", "decimalPlaces": {"type": "max", "places": 2}}
INTEIRO = {"type": "number-plain", "decimalPlaces": {"type": "max", "places": 0}}
PERCENTUAL = {"type": "number-percent", "decimalPlaces": {"type": "max", "places": 1}}


# --------------------------------------------------------------------------
# Datasets

ds_projetos = {
    "name": "ds_projetos",
    "displayName": "Projetos em andamento",
    "queryLines": sql(
        """
        SELECT projeto_id, projeto, nome_projeto, cliente, segmento, tipo_projeto,
               ferramenta, gerente_projeto, valor_contrato, orcamento, pv, ev, ac,
               spi, cpi, eac, estouro_previsto, margem_projetada,
               atraso_projetado_dias, situacao, farol_do_gerente, farol_calculado,
               CASE WHEN melancia THEN 'sim' ELSE 'não' END AS melancia
        FROM projeto_situacao_atual
        WHERE status = 'em_andamento'
        ORDER BY estouro_previsto DESC
        """
    ),
    "columns": [
        {"displayName": "Carteira", "expression": "SUM(`valor_contrato`)"},
        {"displayName": "SPI", "expression": "SUM(`ev`) / SUM(`pv`)"},
        {"displayName": "CPI", "expression": "SUM(`ev`) / SUM(`ac`)"},
        {"displayName": "Estouro", "expression": "SUM(`estouro_previsto`)"},
        {
            "displayName": "Em Risco",
            "expression": "SUM(CASE WHEN `situacao` IN ('atenção','crítico') THEN 1 ELSE 0 END)",
        },
        {
            "displayName": "Críticos",
            "expression": "SUM(CASE WHEN `situacao` = 'crítico' THEN 1 ELSE 0 END)",
        },
        {
            "displayName": "Melancias",
            "expression": "SUM(CASE WHEN `melancia` = 'sim' THEN 1 ELSE 0 END)",
        },
    ],
}

ds_estouro = {
    "name": "ds_estouro",
    "displayName": "Estouro previsto por projeto",
    "queryLines": sql(
        """
        SELECT projeto, situacao, estouro_previsto
        FROM projeto_situacao_atual
        WHERE status = 'em_andamento' AND estouro_previsto > 0
        ORDER BY estouro_previsto DESC
        """
    ),
}

ds_serie = {
    "name": "ds_serie",
    "displayName": "SPI e CPI semanais da carteira",
    "queryLines": sql(
        """
        SELECT semana,
               ROUND(SUM(ev) / SUM(pv), 4) AS spi,
               ROUND(SUM(ev) / SUM(ac), 4) AS cpi
        FROM fato_projeto_semana
        WHERE semana >= DATE'2025-03-07'
        GROUP BY semana
        ORDER BY semana
        """
    ),
}

ds_pessoas_top = {
    "name": "ds_pessoas_top",
    "displayName": "Top 15 pessoas por custo do ócio",
    "queryLines": sql(
        """
        SELECT nome, papel, colaborador_id,
               SUM(custo_ocioso) AS custo_ocioso,
               SUM(horas_ociosas) AS horas_ociosas,
               ROUND(SUM(horas_apontadas) / SUM(horas_disponiveis), 4) AS utilizacao
        FROM utilizacao_pessoa_semana
        WHERE semana > DATE'2026-07-24'
        GROUP BY nome, papel, colaborador_id
        ORDER BY custo_ocioso DESC
        LIMIT 15
        """
    ),
}

ds_utilizacao = {
    "name": "ds_utilizacao",
    "displayName": "Utilização por pessoa e projeto",
    "queryLines": sql(
        """
        SELECT colaborador_id, nome, papel, projeto_id,
               SUM(horas_disponiveis) AS horas_disponiveis,
               SUM(horas_apontadas) AS horas_apontadas,
               SUM(horas_ociosas) AS horas_ociosas,
               SUM(custo_ocioso) AS custo_ocioso,
               ROUND(SUM(horas_apontadas) / SUM(horas_disponiveis), 4) AS utilizacao
        FROM utilizacao_pessoa_semana
        WHERE semana > DATE'2026-07-24'
        GROUP BY colaborador_id, nome, papel, projeto_id
        ORDER BY utilizacao ASC
        """
    ),
}

ds_causas = {
    "name": "ds_causas",
    "displayName": "Causas de bloqueio por projeto",
    "queryLines": sql(
        """
        WITH top_projetos AS (
          SELECT projeto_id, COUNT(*) AS bloqueios
          FROM status_estruturado
          WHERE data_status >= DATE'2026-07-18'
            AND causa_bloqueio NOT IN ('sem_bloqueio', 'nao_reportado')
          GROUP BY projeto_id
          ORDER BY bloqueios DESC
          LIMIT 12
        )
        SELECT p.projeto, s.causa_bloqueio, COUNT(*) AS bloqueios
        FROM status_estruturado s
        JOIN top_projetos t ON t.projeto_id = s.projeto_id
        JOIN projeto_situacao_atual p ON p.projeto_id = s.projeto_id
        WHERE s.data_status >= DATE'2026-07-18'
          AND s.causa_bloqueio NOT IN ('sem_bloqueio', 'nao_reportado')
        GROUP BY p.projeto, s.causa_bloqueio
        ORDER BY p.projeto, s.causa_bloqueio
        """
    ),
}

ds_fornecedor = {
    "name": "ds_fornecedor",
    "displayName": "Fornecedores",
    "queryLines": sql(
        """
        SELECT fornecedor,
               COUNT(DISTINCT fornecedor_como_veio) AS grafias,
               COUNT(*) AS entregas,
               ROUND(AVG(prazo_real_dias / prazo_prometido_dias), 2) AS prazo_real_sobre_prometido,
               ROUND(SUM(CASE WHEN status = 'entregue' AND prazo_real_dias <= prazo_prometido_dias THEN 1 ELSE 0 END)
                     / COUNT(CASE WHEN status = 'entregue' THEN 1 END), 3) AS pct_no_prazo,
               SUM(CASE WHEN em_atraso THEN 1 ELSE 0 END) AS em_atraso_hoje
        FROM lakehouse_vertice.silver.entregas_fornecedor
        GROUP BY fornecedor
        ORDER BY entregas DESC
        """
    ),
}

ds_atrasos = {
    "name": "ds_atrasos",
    "displayName": "Entregas em atraso hoje",
    "queryLines": sql(
        """
        SELECT entrega_id, projeto_id, fornecedor, item, data_prometida,
               prazo_prometido_dias,
               DATEDIFF(DATE'2026-10-16', data_prometida) AS dias_de_atraso_hoje
        FROM lakehouse_vertice.silver.entregas_fornecedor
        WHERE em_atraso
        ORDER BY data_prometida
        """
    ),
}


# --------------------------------------------------------------------------
# Página 1: Portfólio

kpis_portfolio = [
    kpi("kpi-carteira", "Carteira em andamento", "Carteira", 0, 2, 3, MOEDA),
    kpi("kpi-spi", "SPI da carteira", "SPI", 3, 2, 3, DECIMAL),
    kpi("kpi-cpi", "CPI da carteira", "CPI", 6, 2, 3, DECIMAL),
    kpi("kpi-estouro", "Estouro previsto", "Estouro", 9, 2, 3, MOEDA),
    kpi("kpi-risco", "Projetos em risco", "Em Risco", 0, 5, 4, INTEIRO),
    kpi("kpi-criticos", "Projetos críticos", "Críticos", 4, 5, 4, INTEIRO),
    kpi("kpi-melancias", "Melancias", "Melancias", 8, 5, 4, INTEIRO),
]

barra_estouro = {
    "widget": {
        "name": "barra-estouro",
        "queries": [
            {
                "name": "main_query",
                "query": {
                    "datasetName": "ds_estouro",
                    "fields": [
                        {"name": "sum(estouro_previsto)", "expression": "SUM(`estouro_previsto`)"},
                        {"name": "projeto", "expression": "`projeto`"},
                        {"name": "situacao", "expression": "`situacao`"},
                    ],
                    "disaggregated": False,
                },
            }
        ],
        "spec": {
            "version": 3,
            "widgetType": "bar",
            "encodings": {
                "x": {
                    "fieldName": "sum(estouro_previsto)",
                    "scale": {"type": "quantitative"},
                    "displayName": "Estouro previsto (R$)",
                },
                "y": {
                    "fieldName": "projeto",
                    "scale": {"type": "categorical", "sort": {"by": "value"}},
                },
                "color": {
                    "fieldName": "situacao",
                    "scale": {
                        "type": "categorical",
                        "mappings": [
                            {"value": "crítico", "color": "#FF5F46"},
                            {"value": "atenção", "color": "#F6C344"},
                            {"value": "ok", "color": "#22C2F4"},
                        ],
                    },
                },
            },
            "frame": {
                "showTitle": True,
                "title": "Estouro previsto por projeto (só quem estoura)",
            },
        },
    },
    "position": {"x": 0, "y": 8, "width": 7, "height": 12},
}

dispersao = {
    "widget": {
        "name": "dispersao-spi-cpi",
        "queries": [
            {
                "name": "main_query",
                "query": {
                    "datasetName": "ds_projetos",
                    "fields": [
                        {"name": "spi", "expression": "`spi`"},
                        {"name": "cpi", "expression": "`cpi`"},
                        {"name": "projeto", "expression": "`projeto`"},
                        {"name": "situacao", "expression": "`situacao`"},
                        {"name": "cliente", "expression": "`cliente`"},
                    ],
                    "disaggregated": True,
                },
            }
        ],
        "spec": {
            "version": 3,
            "widgetType": "scatter",
            "encodings": {
                "x": {
                    "fieldName": "spi",
                    "scale": {"type": "quantitative"},
                    "displayName": "SPI",
                },
                "y": {
                    "fieldName": "cpi",
                    "scale": {"type": "quantitative"},
                    "displayName": "CPI",
                },
                "color": {
                    "fieldName": "situacao",
                    "scale": {
                        "type": "categorical",
                        "mappings": [
                            {"value": "crítico", "color": "#FF5F46"},
                            {"value": "atenção", "color": "#F6C344"},
                            {"value": "ok", "color": "#22C2F4"},
                        ],
                    },
                },
                "extra": [
                    {"fieldName": "projeto", "displayName": "Projeto"},
                    {"fieldName": "cliente", "displayName": "Cliente"},
                ],
            },
            "frame": {
                "showTitle": True,
                "title": "SPI × CPI — um ponto por projeto",
            },
        },
    },
    "position": {"x": 7, "y": 8, "width": 5, "height": 12},
}

linha_spi_cpi = {
    "widget": {
        "name": "linha-spi-cpi",
        "queries": [
            {
                "name": "main_query",
                "query": {
                    "datasetName": "ds_serie",
                    "fields": [
                        {"name": "semana", "expression": "`semana`"},
                        {"name": "spi", "expression": "`spi`"},
                        {"name": "cpi", "expression": "`cpi`"},
                    ],
                    "disaggregated": True,
                },
            }
        ],
        "spec": {
            "version": 3,
            "widgetType": "line",
            "encodings": {
                "x": {
                    "fieldName": "semana",
                    "scale": {"type": "temporal"},
                    "displayName": "Semana",
                },
                "y": {
                    "scale": {"type": "quantitative"},
                    "fields": [
                        {"fieldName": "spi", "displayName": "SPI"},
                        {"fieldName": "cpi", "displayName": "CPI"},
                    ],
                },
            },
            "annotations": [
                {
                    "type": "horizontal-line",
                    "encodings": {
                        "y": {"dataValue": "0.9", "dataType": "DOUBLE"},
                        "label": {"value": "atenção (0,90)"},
                        "color": {"value": {"hex": "#F6C344"}},
                    },
                },
                {
                    "type": "horizontal-line",
                    "encodings": {
                        "y": {"dataValue": "0.8", "dataType": "DOUBLE"},
                        "label": {"value": "crítico (0,80)"},
                        "color": {"value": {"hex": "#FF5F46"}},
                    },
                },
            ],
            "frame": {
                "showTitle": True,
                "title": "SPI e CPI da carteira, semana a semana",
            },
        },
    },
    "position": {"x": 0, "y": 20, "width": 12, "height": 6},
}

tabela_projetos = {
    "widget": {
        "name": "tabela-projetos",
        "queries": [
            {
                "name": "main_query",
                "query": {
                    "datasetName": "ds_projetos",
                    "fields": [
                        {"name": "projeto", "expression": "`projeto`"},
                        {"name": "cliente", "expression": "`cliente`"},
                        {"name": "situacao", "expression": "`situacao`"},
                        {"name": "spi", "expression": "`spi`"},
                        {"name": "cpi", "expression": "`cpi`"},
                        {"name": "farol_do_gerente", "expression": "`farol_do_gerente`"},
                        {"name": "farol_calculado", "expression": "`farol_calculado`"},
                        {"name": "melancia", "expression": "`melancia`"},
                        {"name": "estouro_previsto", "expression": "`estouro_previsto`"},
                    ],
                    "disaggregated": True,
                },
            }
        ],
        "spec": {
            "version": 2,
            "widgetType": "table",
            "encodings": {
                "columns": [
                    {"fieldName": "projeto", "displayName": "Projeto"},
                    {"fieldName": "cliente", "displayName": "Cliente"},
                    {"fieldName": "situacao", "displayName": "Situação"},
                    {
                        "fieldName": "spi",
                        "displayName": "SPI",
                        "format": {"type": "number-plain", "decimalPlaces": {"type": "exact", "places": 2}},
                    },
                    {
                        "fieldName": "cpi",
                        "displayName": "CPI",
                        "format": {"type": "number-plain", "decimalPlaces": {"type": "exact", "places": 2}},
                    },
                    {"fieldName": "farol_do_gerente", "displayName": "Farol do gerente"},
                    {"fieldName": "farol_calculado", "displayName": "Farol pelo número"},
                    {"fieldName": "melancia", "displayName": "Melancia"},
                    {
                        "fieldName": "estouro_previsto",
                        "displayName": "Estouro previsto",
                        "format": MOEDA,
                    },
                ]
            },
            "frame": {
                "showTitle": True,
                "title": "Farol do gerente × farol pelo número",
            },
        },
    },
    "position": {"x": 0, "y": 26, "width": 12, "height": 8},
}

pagina_portfolio = {
    "name": "portfolio",
    "displayName": "Portfólio",
    "pageType": "PAGE_TYPE_CANVAS",
    "layoutVersion": "GRID_V1",
    "layout": [
        texto(
            "titulo-portfolio",
            [
                "## Projeto Farol · Portfólio\n",
                "\n",
                "**Quais projetos estão atrasados, e de quais clientes?** A carteira em andamento "
                "(41 projetos, R$ 208,6 mi) tem SPI 0,92 e CPI 0,97. Sete projetos estão críticos e "
                "dez em atenção; quatro têm farol verde do gerente com SPI abaixo de 0,90 — as melancias. "
                "O estouro previsto somado é de R$ 6,47 mi.",
            ],
            0,
            3,
        ),
        *kpis_portfolio,
        barra_estouro,
        dispersao,
        linha_spi_cpi,
        tabela_projetos,
    ],
}


# --------------------------------------------------------------------------
# Página 2: Pessoas

barra_pessoas = {
    "widget": {
        "name": "barra-pessoas",
        "queries": [
            {
                "name": "main_query",
                "query": {
                    "datasetName": "ds_pessoas_top",
                    "fields": [
                        {"name": "sum(custo_ocioso)", "expression": "SUM(`custo_ocioso`)"},
                        {"name": "nome", "expression": "`nome`"},
                        {"name": "papel", "expression": "`papel`"},
                        {"name": "horas_ociosas", "expression": "`horas_ociosas`"},
                        {"name": "utilizacao", "expression": "`utilizacao`"},
                    ],
                    "disaggregated": False,
                },
            }
        ],
        "spec": {
            "version": 3,
            "widgetType": "bar",
            "encodings": {
                "x": {
                    "fieldName": "sum(custo_ocioso)",
                    "scale": {"type": "quantitative"},
                    "displayName": "Custo do ócio (R$)",
                },
                "y": {
                    "fieldName": "nome",
                    "scale": {"type": "categorical", "sort": {"by": "value"}},
                },
                "color": {"fieldName": "papel", "scale": {"type": "categorical"}},
                "extra": [
                    {"fieldName": "horas_ociosas", "displayName": "Horas paradas"},
                    {"fieldName": "utilizacao", "displayName": "Utilização"},
                ],
            },
            "frame": {
                "showTitle": True,
                "title": "Top 15 por custo da hora parada (12 semanas)",
            },
        },
    },
    "position": {"x": 0, "y": 3, "width": 6, "height": 10},
}

barra_causas = {
    "widget": {
        "name": "barra-causas",
        "queries": [
            {
                "name": "main_query",
                "query": {
                    "datasetName": "ds_causas",
                    "fields": [
                        {"name": "sum(bloqueios)", "expression": "SUM(`bloqueios`)"},
                        {"name": "projeto", "expression": "`projeto`"},
                        {"name": "causa_bloqueio", "expression": "`causa_bloqueio`"},
                    ],
                    "disaggregated": False,
                },
            }
        ],
        "spec": {
            "version": 3,
            "widgetType": "bar",
            "encodings": {
                "x": {
                    "fieldName": "sum(bloqueios)",
                    "scale": {"type": "quantitative"},
                    "displayName": "Semanas com bloqueio",
                },
                "y": {
                    "fieldName": "projeto",
                    "scale": {"type": "categorical", "sort": {"by": "value"}},
                },
                "color": {"fieldName": "causa_bloqueio", "scale": {"type": "categorical"}},
            },
            "frame": {
                "showTitle": True,
                "title": "Causas de bloqueio por projeto (90 dias)",
            },
        },
    },
    "position": {"x": 6, "y": 3, "width": 6, "height": 10},
}

tabela_utilizacao = {
    "widget": {
        "name": "tabela-utilizacao",
        "queries": [
            {
                "name": "main_query",
                "query": {
                    "datasetName": "ds_utilizacao",
                    "fields": [
                        {"name": "colaborador_id", "expression": "`colaborador_id`"},
                        {"name": "nome", "expression": "`nome`"},
                        {"name": "papel", "expression": "`papel`"},
                        {"name": "projeto_id", "expression": "`projeto_id`"},
                        {"name": "horas_disponiveis", "expression": "`horas_disponiveis`"},
                        {"name": "horas_apontadas", "expression": "`horas_apontadas`"},
                        {"name": "horas_ociosas", "expression": "`horas_ociosas`"},
                        {"name": "utilizacao", "expression": "`utilizacao`"},
                        {"name": "custo_ocioso", "expression": "`custo_ocioso`"},
                    ],
                    "disaggregated": True,
                },
            }
        ],
        "spec": {
            "version": 2,
            "widgetType": "table",
            "encodings": {
                "columns": [
                    {"fieldName": "colaborador_id", "displayName": "Pessoa"},
                    {"fieldName": "nome", "displayName": "Nome"},
                    {"fieldName": "papel", "displayName": "Papel"},
                    {"fieldName": "projeto_id", "displayName": "Projeto"},
                    {
                        "fieldName": "horas_disponiveis",
                        "displayName": "Horas disponíveis",
                        "format": {"type": "number-plain", "decimalPlaces": {"type": "max", "places": 1}},
                    },
                    {
                        "fieldName": "horas_apontadas",
                        "displayName": "Horas apontadas",
                        "format": {"type": "number-plain", "decimalPlaces": {"type": "max", "places": 1}},
                    },
                    {
                        "fieldName": "horas_ociosas",
                        "displayName": "Horas ociosas",
                        "format": {"type": "number-plain", "decimalPlaces": {"type": "max", "places": 1}},
                    },
                    {"fieldName": "utilizacao", "displayName": "Utilização", "format": PERCENTUAL},
                    {"fieldName": "custo_ocioso", "displayName": "Custo do ócio", "format": MOEDA},
                ]
            },
            "frame": {
                "showTitle": True,
                "title": "Utilização por pessoa e projeto — da mais parada à mais ocupada",
            },
        },
    },
    "position": {"x": 0, "y": 13, "width": 12, "height": 10},
}

pagina_pessoas = {
    "name": "pessoas",
    "displayName": "Pessoas",
    "pageType": "PAGE_TYPE_CANVAS",
    "layoutVersion": "GRID_V1",
    "layout": [
        texto(
            "titulo-pessoas",
            [
                "## Projeto Farol · Pessoas\n",
                "\n",
                "**Tenho gente parada enquanto outro projeto pede gente?** Nas últimas 12 semanas, "
                "duas SREs do PRJ-007 (COL0017 e COL0018) ficaram abaixo de 6% de utilização — "
                "juntas, mais de R$ 179 mil de hora parada. Já o PRJ-011 declara falta de SRE há "
                "12 semanas seguidas.",
            ],
            0,
            3,
        ),
        barra_pessoas,
        barra_causas,
        tabela_utilizacao,
    ],
}


# --------------------------------------------------------------------------
# Página 3: Fornecedores

tabela_fornecedor = {
    "widget": {
        "name": "tabela-fornecedor",
        "queries": [
            {
                "name": "main_query",
                "query": {
                    "datasetName": "ds_fornecedor",
                    "fields": [
                        {"name": "fornecedor", "expression": "`fornecedor`"},
                        {"name": "grafias", "expression": "`grafias`"},
                        {"name": "entregas", "expression": "`entregas`"},
                        {"name": "prazo_real_sobre_prometido", "expression": "`prazo_real_sobre_prometido`"},
                        {"name": "pct_no_prazo", "expression": "`pct_no_prazo`"},
                        {"name": "em_atraso_hoje", "expression": "`em_atraso_hoje`"},
                    ],
                    "disaggregated": True,
                },
            }
        ],
        "spec": {
            "version": 2,
            "widgetType": "table",
            "encodings": {
                "columns": [
                    {"fieldName": "fornecedor", "displayName": "Fornecedor"},
                    {"fieldName": "grafias", "displayName": "Grafias no cadastro"},
                    {"fieldName": "entregas", "displayName": "Entregas"},
                    {
                        "fieldName": "prazo_real_sobre_prometido",
                        "displayName": "Prazo real ÷ prometido",
                        "format": {"type": "number-plain", "decimalPlaces": {"type": "exact", "places": 2}},
                    },
                    {"fieldName": "pct_no_prazo", "displayName": "% no prazo", "format": PERCENTUAL},
                    {"fieldName": "em_atraso_hoje", "displayName": "Em atraso hoje"},
                ]
            },
            "frame": {
                "showTitle": True,
                "title": "Fornecedores — prazo, confiabilidade e atraso",
            },
        },
    },
    "position": {"x": 0, "y": 3, "width": 12, "height": 5},
}

tabela_atrasos = {
    "widget": {
        "name": "tabela-atrasos",
        "queries": [
            {
                "name": "main_query",
                "query": {
                    "datasetName": "ds_atrasos",
                    "fields": [
                        {"name": "entrega_id", "expression": "`entrega_id`"},
                        {"name": "projeto_id", "expression": "`projeto_id`"},
                        {"name": "fornecedor", "expression": "`fornecedor`"},
                        {"name": "item", "expression": "`item`"},
                        {"name": "data_prometida", "expression": "`data_prometida`"},
                        {"name": "prazo_prometido_dias", "expression": "`prazo_prometido_dias`"},
                        {"name": "dias_de_atraso_hoje", "expression": "`dias_de_atraso_hoje`"},
                    ],
                    "disaggregated": True,
                },
            }
        ],
        "spec": {
            "version": 2,
            "widgetType": "table",
            "encodings": {
                "columns": [
                    {"fieldName": "entrega_id", "displayName": "Entrega"},
                    {"fieldName": "projeto_id", "displayName": "Projeto"},
                    {"fieldName": "fornecedor", "displayName": "Fornecedor"},
                    {"fieldName": "item", "displayName": "Item"},
                    {"fieldName": "data_prometida", "displayName": "Prometida em"},
                    {"fieldName": "prazo_prometido_dias", "displayName": "Prazo (dias)"},
                    {"fieldName": "dias_de_atraso_hoje", "displayName": "Dias de atraso hoje"},
                ]
            },
            "frame": {
                "showTitle": True,
                "title": "Entregas em atraso hoje",
            },
        },
    },
    "position": {"x": 0, "y": 8, "width": 12, "height": 5},
}

pagina_fornecedores = {
    "name": "fornecedores",
    "displayName": "Fornecedores",
    "pageType": "PAGE_TYPE_CANVAS",
    "layoutVersion": "GRID_V1",
    "layout": [
        texto(
            "titulo-fornecedores",
            [
                "## Projeto Farol · Fornecedores\n",
                "\n",
                "**O que vai dar errado no próximo mês?** A CodeForge concentra as cinco entregas "
                "em atraso hoje e leva 1,41× o prazo que promete (0% no prazo). Quatro grafias no "
                "cadastro escondem um fornecedor só — e o atraso dele alimenta o bloqueio de "
                "dependência de fornecedor em vários projetos.",
            ],
            0,
            3,
        ),
        tabela_fornecedor,
        tabela_atrasos,
    ],
}


# --------------------------------------------------------------------------

dashboard = {
    "datasets": [
        ds_projetos,
        ds_estouro,
        ds_serie,
        ds_pessoas_top,
        ds_utilizacao,
        ds_causas,
        ds_fornecedor,
        ds_atrasos,
    ],
    "pages": [pagina_portfolio, pagina_pessoas, pagina_fornecedores],
    "uiSettings": {
        "theme": {
            "canvasBackgroundColor": {"light": "#F7F9FC", "dark": "#14141A"},
            "widgetBackgroundColor": {"light": "#FFFFFF", "dark": "#1C1D24"},
            "widgetBorderColor": {"light": "#FFFFFF", "dark": "#1C1D24"},
            "fontColor": {"light": "#14141A", "dark": "#F2F4F8"},
            "selectionColor": {"light": "#0059DB", "dark": "#22C2F4"},
            "visualizationColors": [
                "#0059DB",
                "#22C2F4",
                "#7B61FF",
                "#00B37E",
                "#F6C344",
                "#FF5F46",
                "#94A3B8",
            ],
            "widgetHeaderAlignment": "LEFT",
            "widgetCornerRadius": 12,
        }
    },
}

SAIDA.write_text(json.dumps(dashboard, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
print(f"gerado {SAIDA.relative_to(RAIZ)} · {len(dashboard['datasets'])} datasets · "
      f"{len(dashboard['pages'])} páginas")
