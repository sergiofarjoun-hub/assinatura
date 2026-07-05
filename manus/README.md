# Hamsa Agent — agente autônomo estilo Manus, auto-hospedado

Resposta prática à pergunta *"dá pra criar um software tipo Manus?"* — **sim**, e este
módulo é um protótipo funcional. É um app web onde você descreve uma tarefa em
linguagem natural e um agente de IA (Claude) **planeja e executa sozinho**, usando
ferramentas reais, mostrando cada passo num painel de atividade (como o "computador"
do Manus).

## O que ele consegue fazer

O agente roda um loop autônomo com 4 ferramentas:

| Ferramenta | Onde executa | Para quê |
|---|---|---|
| `bash` | no container (NAS) | rodar comandos, scripts Python, git, curl... |
| editor de arquivos | no container | criar/ler/editar arquivos no workspace da sessão |
| `web_search` | servidores da Anthropic | pesquisar na web |
| `web_fetch` | servidores da Anthropic | ler o conteúdo de páginas específicas |

Exemplos de tarefas: "pesquise X e gere um relatório em markdown", "escreva um script
Python que converta este CSV", "leia esta página e resuma as mudanças". Os arquivos
gerados aparecem na UI com link de download e ficam em `workspace/<sessão>/`.

## Arquitetura

```
navegador ──► Express (server.js) ──► Claude API (claude-opus-4-8, tool use)
   ▲  SSE (texto + atividade)   │
   └────────────────────────────┘
        bash/editor executam no container; busca/leitura web no lado da Anthropic
```

- Loop agêntico manual sobre a **Claude API** (`@anthropic-ai/sdk`), com streaming,
  adaptive thinking e prompt caching.
- Sem banco de dados: sessões em memória + arquivos no filesystem. Simples de operar.

## Rodando localmente (teste)

```bash
cd manus
npm install
export ANTHROPIC_API_KEY=sk-ant-...   # crie em https://platform.claude.com
npm start
# abra http://localhost:3010
```

## Deploy no NAS (padrão dos outros apps Hamsa)

```bash
cd manus
cp .env.example .env    # e preencha a ANTHROPIC_API_KEY
docker compose up -d --build
# expor via tailnet, como os demais apps:
tailscale serve --bg --https=3010 http://localhost:3010
```

Depois é instalável como PWA/atalho igual aos outros 6 apps (porta própria, raiz própria).

## Custos e limites

- Usa `claude-opus-4-8` por padrão (US$ 5 / US$ 25 por milhão de tokens de entrada/saída).
  Uma tarefa típica com pesquisa + alguns comandos custa centavos de dólar; tarefas longas
  podem custar mais. Para reduzir custo, defina `MODEL=claude-sonnet-5` no `.env`.
- Limite de 40 rodadas por tarefa (`MAX_TURNS`) e timeout de 120 s por comando bash.

## Segurança — leia antes de expor

- O agente **executa comandos de verdade** no container. Rode sempre via Docker (o
  `docker-compose.yml` isola o filesystem; só a pasta `workspace/` é montada).
- Mantenha o acesso restrito à tailnet (como os outros apps) — **não** exponha na
  internet pública: não há autenticação de usuários neste protótipo.
- A `ANTHROPIC_API_KEY` fica só no `.env` (ignorado pelo git).

## O que falta para ficar "Manus completo" (próximos passos possíveis)

- Navegação web com browser real (Playwright) para sites que exigem interação.
- Persistência de sessões em disco/Postgres (hoje o histórico morre no restart).
- Autenticação de usuários e múltiplos agentes em paralelo.
- Botão de "aprovar antes de executar" para comandos sensíveis.
