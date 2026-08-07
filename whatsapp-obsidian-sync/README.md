# WhatsApp (Android) → Obsidian Sync

Converte o backup local criptografado do WhatsApp em notas Markdown no vault
**BASE_CONHECIMENTO**: uma nota por conversa em `Clientes/WhatsApp/`, atualizada
diariamente. Sem tocar na conta do WhatsApp — **zero risco de banimento** — porque
tudo é feito lendo o backup que o próprio app já gera todo dia.

## Arquitetura

```
Android: WhatsApp gera msgstore.db.crypt15 toda madrugada (automático)
   └─ App Synology Drive no celular (tarefa de backup) ──▶ pasta no NAS
        └─ Mac 07:15 (launchd): wa-sync.sh
             ├─ wtsexporter: descriptografa (chave de 64 dígitos) → JSON
             └─ wa2vault.py: JSON → uma nota .md por conversa no vault
```

- **Incremental**: só reescreve notas de conversas com mensagens novas; nome do
  arquivo é estável (links do Obsidian não quebram).
- **Filtros**: grupos ficam de fora por padrão (`includeGroups`), conversas com
  menos de 5 mensagens são ignoradas (`minMessages`).
- **Nomes**: usa o nome do contato disponível no backup; para nomear tudo
  certinho, exporte seus contatos do Google em `.vcf` e informe no install
  (`contactsVcf`) — o exporter cruza pelo telefone (código do país padrão: 55).
- **Higiene**: o banco descriptografado vive só numa pasta de trabalho local
  durante a execução e é apagado ao final; a chave fica em
  `~/.wa-obsidian-sync/config.json` com `chmod 600`.
- **Mount do NAS fora / backup ainda não chegou**: sai em silêncio e tenta no
  dia seguinte.

## Pré-requisitos (uma vez só)

1. **Chave de 64 dígitos**: WhatsApp → Configurações → Conversas → Backup →
   Backup criptografado de ponta a ponta → ativar com "chave de 64 dígitos" e
   guardar a chave.
2. **App Synology Drive** no Android (Mais → Tarefas de backup) fazendo backup de
   `Android/media/com.whatsapp/WhatsApp/Databases/` para uma pasta do Team Folder
   SERVER (que aparece no Mac via mount `~/SERVER/...`).
3. Python 3 no Mac (vem com o sistema/Xcode CLT).

## Instalação (no Mac)

```bash
bash install.sh
```

Pergunta o vault, a pasta dos backups, a chave e o `.vcf` opcional; instala em
`~/.wa-obsidian-sync/`, agenda via launchd (`com.hamsa.wa-sync`, diário às
07:15) e roda a primeira conversão na hora.

## Operação

| Ação | Comando |
|---|---|
| Rodar agora | `~/.wa-obsidian-sync/wa-sync.sh` |
| Ver log | `tail -f ~/Library/Logs/wa-sync.log` |
| Ajustar filtros/pastas | editar `~/.wa-obsidian-sync/config.json` |
| Desinstalar | `launchctl bootout gui/$(id -u)/com.hamsa.wa-sync && rm -rf ~/Library/LaunchAgents/com.hamsa.wa-sync.plist ~/.wa-obsidian-sync` |

## Formato da nota

```markdown
---
contato: "Fulano de Tal"
telefone: "+5511999999999"
tipo: "individual"
mensagens: 342
ultima_mensagem: "2026-08-05 18:40"
tags:
  - whatsapp
---

# WhatsApp — Fulano de Tal

## 2026-08-05
- 18:39 **Contato**: Sergio, como fica o reajuste?
- 18:40 **Sergio**: Te mando a proposta amanhã cedo.
```

## Notas técnicas e privacidade

- Descriptografia/parse: [WhatsApp-Chat-Exporter](https://github.com/KnugiHK/WhatsApp-Chat-Exporter)
  (`pip install whatsapp-chat-exporter`), formato crypt15 (backup E2E do WhatsApp).
- As conversas contêm dados sensíveis de clientes (LGPD): tudo permanece dentro
  da infraestrutura própria (celular → NAS via Tailscale → vault no NAS).
  Nenhum dado passa por serviço de terceiros.
- Mensagens de sistema (chamadas, entradas em grupo) e mídia não são incluídas;
  mídia aparece como `_[image/jpeg]_` com a legenda, se houver.
