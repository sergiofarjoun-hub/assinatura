# Plaud → Obsidian Sync

Importa automaticamente as gravações do Plaud (resumo de IA + transcrição completa) como
notas Markdown no vault **BASE_CONHECIMENTO** do Obsidian. Sem Zapier, sem custo, sem
intervenção: um agente `launchd` roda o sync de hora em hora no Mac.

## Como funciona

```
Plaud (nuvem) ──API oficial──▶ plaud-sync.mjs (Mac, a cada 1h) ──▶ <vault>/Plaud/*.md
```

- **Autenticação**: reaproveita o login do Plaud CLI (`~/.plaud/tokens.json`), com
  renovação automática de token — login uma vez, funciona para sempre.
- **Incremental e idempotente**: cada gravação vira uma nota única
  (`2026-08-06 1432 - Reunião VUMI (a1b2c3d4).md`); o que já foi importado nunca é
  duplicado. Estado em `<vault>/Plaud/.plaud-sync-state.json` (oculto no Obsidian).
- **Gravações ainda processando** no Plaud ficam pendentes e são re-checadas a cada
  execução por até 7 dias.
- **Mount do NAS fora?** O script detecta e sai em silêncio; importa tudo na próxima
  execução com o mount ativo. Escrita é atômica (tmp + rename) — nada de nota pela metade.

## Formato da nota

```markdown
---
plaud_id: "..."
title: "Reunião VUMI"
data: "2026-08-06 14:32"
duracao: "42m 10s"
dispositivo: "PLAUD-XXXX"
tags:
  - plaud
---

# Reunião VUMI

## Resumo (IA)
…resumo em Markdown gerado pelo Plaud…

## Transcrição (polida)
\[00:03\] **Speaker 1**: …
```

Usa a transcrição polida (`transaction_polish`) quando existe; senão, a bruta.

## Instalação (no Mac)

```bash
bash install.sh
```

O instalador: verifica Node ≥18 → detecta o vault (`~/SERVER/BASE_CONHECIMENTO`) →
faz login no Plaud se preciso (abre o navegador) → instala em `~/.plaud-obsidian-sync/` →
registra o agente launchd (`com.hamsa.plaud-sync`, 1h em 1h + ao logar) → roda o
primeiro sync (últimos 30 dias) na hora.

## Operação

| Ação | Comando |
|---|---|
| Rodar agora | `node ~/.plaud-obsidian-sync/plaud-sync.mjs --verbose` |
| Simular sem escrever | `node ~/.plaud-obsidian-sync/plaud-sync.mjs --dry-run --verbose` |
| Ver log | `tail -f ~/Library/Logs/plaud-sync.log` |
| Refazer login | `npx -y @plaud-ai/cli login` |
| Mudar pasta/janela | editar `~/.plaud-obsidian-sync/config.json` |
| Desinstalar | `launchctl bootout gui/$(id -u)/com.hamsa.plaud-sync && rm -rf ~/Library/LaunchAgents/com.hamsa.plaud-sync.plist ~/.plaud-obsidian-sync` |

## Notas técnicas

- API: `https://platform.plaud.ai/developer/api/open/third-party/files/` (a mesma que o
  Plaud CLI oficial usa; contrato extraído do bundle `@plaud-ai/cli`).
- Token: mesmo formato/arquivo do CLI — os dois convivem sem conflito (o MCP usa
  `tokens-mcp.json`, separado).
- Timestamps de segmento vêm em **milissegundos** (convenção do CLI oficial).
- Lock em `~/.plaud-obsidian-sync/sync.lock` impede execuções sobrepostas (stale após 30min).
