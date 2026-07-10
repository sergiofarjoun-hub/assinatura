# Hamsa Agent — agente autônomo estilo Manus, auto-hospedado

Resposta prática à pergunta *"dá pra criar um software tipo Manus?"* — **sim**, e este
módulo é a implementação. É um app web onde você descreve uma tarefa em linguagem
natural e um agente de IA (Claude) **planeja e executa sozinho**, usando ferramentas
reais, mostrando cada passo num painel de atividade (como o "computador" do Manus).

## O que ele consegue fazer

O agente roda um loop autônomo com 5 ferramentas:

| Ferramenta | Onde executa | Para quê |
|---|---|---|
| `bash` | no container (NAS) | rodar comandos, scripts Python, git, curl... |
| editor de arquivos | no container | criar/ler/editar arquivos no workspace da sessão |
| `browser` (Chromium) | no container | páginas com JavaScript, cliques, formulários, screenshots (o modelo **vê** a página) |
| `web_search` | servidores da Anthropic | pesquisar na web |
| `web_fetch` | servidores da Anthropic | ler o conteúdo de páginas simples |

Exemplos de tarefas: "pesquise X e gere um relatório em markdown", "escreva um script
Python que converta este CSV", "abra o site Y, tire um screenshot e me diga o que mudou".
Os arquivos gerados aparecem na UI com link de download e ficam em `workspace/<sessão>/`.

## Segurança embutida

- **Login por senha** (`AGENT_PASSWORD`): a UI pede senha e todas as APIs exigem token.
  Se a variável ficar vazia, o app roda aberto — só aceitável dentro da tailnet.
- **Aprovação humana** (`APPROVAL_MODE=sensitive`, padrão): comandos bash sensíveis
  (`rm`, `sudo`, `git push`, `ssh`, `docker`, POSTs via curl...) pausam o agente e
  mostram um cartão **Aprovar / Negar** no chat. `all` pede para todo comando; `off` desativa.
- **Confinamento de caminhos**: o editor de arquivos e os downloads só enxergam o
  workspace da sessão (path traversal bloqueado).
- **Timeout** de 120 s por comando bash e limite de 40 rodadas por tarefa.

## Persistência

O histórico de cada sessão é salvo em `sessions/<id>.json` (fora do workspace, para o
agente não editar o próprio histórico) e sobrevive a restart do container — ao reabrir
a UI, a conversa é recarregada. Os arquivos ficam em `workspace/<id>/`.

## Arquitetura

```
navegador ──► Express (server.js) ──► Claude API (claude-opus-4-8, tool use)
   ▲  SSE (texto + atividade         │
   └──── + pedidos de aprovação) ────┘
    bash/editor/chromium executam no container; busca/leitura web no lado da Anthropic
```

- Loop agêntico manual sobre a **Claude API** (`@anthropic-ai/sdk`), com streaming,
  adaptive thinking e prompt caching.
- Navegador via `playwright-core` usando o Chromium do sistema (`CHROME_PATH`).
- Sem banco de dados: sessões em JSON + arquivos no filesystem. Simples de operar.

## Rodando localmente (teste)

```bash
cd manus
npm install
export ANTHROPIC_API_KEY=sk-ant-...   # crie em https://platform.claude.com
export AGENT_PASSWORD=uma-senha-forte
npm start
# abra http://localhost:3010
```

## Deploy no NAS (padrão dos outros apps Hamsa)

```bash
cd manus
cp .env.example .env    # preencha ANTHROPIC_API_KEY e AGENT_PASSWORD
docker compose up -d --build
# expor via tailnet, como os demais apps:
tailscale serve --bg --https=3010 http://localhost:3010
```

Depois é instalável como PWA/atalho igual aos outros 6 apps (porta própria, raiz própria).

## Custos e limites

- Usa `claude-opus-4-8` por padrão (US$ 5 / US$ 25 por milhão de tokens de entrada/saída).
  Uma tarefa típica com pesquisa + alguns comandos custa centavos de dólar; tarefas longas
  (e screenshots, que consomem tokens de imagem) podem custar mais. Para reduzir custo,
  defina `MODEL=claude-sonnet-5` no `.env`.
- Limite de 40 rodadas por tarefa (`MAX_TURNS`) e timeout de 120 s por comando bash.
- Uma tarefa por vez por sessão (novas mensagens na mesma sessão aguardam a atual).

## Avisos

- O agente **executa comandos de verdade** no container. Rode sempre via Docker (o
  `docker-compose.yml` isola o filesystem; só `workspace/` e `sessions/` são montados).
- Mesmo com login, o recomendado é manter o acesso restrito à tailnet, como os outros apps.
- A `ANTHROPIC_API_KEY` e a `AGENT_PASSWORD` ficam só no `.env` (ignorado pelo git).
- Pendências conhecidas: teste ponta-a-ponta com chave real (exige `ANTHROPIC_API_KEY`
  válida) e isolamento de container por sessão (hoje as sessões compartilham o container,
  cada uma com seu diretório).
