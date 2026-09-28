# Agente de IA para WhatsApp — Hamsa

Bot de WhatsApp movido pelo **Claude** (Anthropic) para a corretora Hamsa, com
**dois modos no mesmo número**:

| Modo | Quem aciona | O que faz |
|------|-------------|-----------|
| **Admin** (assistente pessoal) | O chat **"você mesmo"** (mensagem para si próprio) e os números em `ADMIN_NUMBERS` | Assistente completo: redige respostas para clientes, resume conversas, traduz, explica termos de IPMI, rascunha e-mails para seguradoras. Também aceita comandos `!`. |
| **Cliente** (atendimento) | Qualquer outro contato que mandar mensagem | Assistente da corretora com regras restritas: explica seguro-saúde internacional, coleta dados para cotação, **não cita preços nem promete cobertura**, e escala para o Sérgio quando necessário. PT-BR por padrão (segue o idioma do cliente). |

**Conexão:** [Baileys](https://github.com/WhiskeySockets/Baileys) — o bot entra como
**dispositivo conectado** (igual ao WhatsApp Web) via QR code. Não precisa de conta
Meta Business. ⚠️ É uma integração não-oficial: uso normal 1:1 costuma ser tranquilo,
mas evite disparos em massa (risco de bloqueio do número pela Meta).

## Comportamentos importantes

- **Handoff humano automático:** se o Sérgio responder um cliente manualmente pelo
  celular, o bot **pausa naquele chat** por `HANDOFF_PAUSE_MINUTES` (padrão 60 min).
- **Grupos e status são ignorados.** Mídia sem texto (áudio, figurinha) é ignorada.
- **Memória por conversa:** últimas `MAX_HISTORY` mensagens de cada chat, persistidas
  em `data/state.json` (sobrevive a restart).
- O bot **não marca "online"** ao conectar (não rouba notificações do celular).

## Comandos (só admin)

```
!ajuda                     lista de comandos
!status                    modelo, modo, chats pausados
!pausar 5511999999999      pausa o bot num chat de cliente
!ativar 5511999999999      reativa
!limpar [numero|tudo]      apaga histórico de conversa
```

Qualquer outra mensagem no chat "você mesmo" vai direto para o assistente pessoal.

## Rodando local (teste)

Requisitos: Node 20+ e uma chave da API Anthropic (<https://console.anthropic.com>).

```bash
cd whatsapp-agent
cp .env.example .env        # edite e coloque a ANTHROPIC_API_KEY
npm install
npm start
```

No primeiro start aparece um **QR code no terminal** — escaneie no celular:
WhatsApp → Configurações → **Dispositivos conectados** → Conectar dispositivo.
A sessão fica salva em `data/auth/` (não precisa escanear de novo).

Teste: mande uma mensagem para **você mesmo** no WhatsApp → o bot responde como
assistente pessoal. Peça para alguém mandar mensagem no seu número → modo cliente.

## Deploy no NAS `hamsa-usa` (Docker)

O NAS já roda os outros apps Hamsa em Docker. Via SSH:

```bash
# 1. copiar a pasta whatsapp-agent para o NAS, ex.:
#    /volume1/docker/hamsa-whatsapp-agent
cd /volume1/docker/hamsa-whatsapp-agent

# 2. configurar
cp .env.example .env && vi .env      # ANTHROPIC_API_KEY etc.

# 3. subir
sudo docker compose up -d --build

# 4. parear (só na primeira vez): o QR aparece nos logs
sudo docker compose logs -f whatsapp-agent
#    escaneie o QR; Ctrl+C sai dos logs sem parar o container
```

O volume `./data` guarda a sessão e o histórico — **faça backup dessa pasta** e
não a apague, ou será preciso escanear o QR de novo.

Atualizar depois de mudar o código:

```bash
sudo docker compose up -d --build
```

## Custo

Modelo padrão: `claude-opus-4-8` (US$ 5 / US$ 25 por milhão de tokens de
entrada/saída). Uma conversa típica de WhatsApp custa fração de centavo por
mensagem; o system prompt é cacheado pela API para reduzir custo. Para volume
alto de clientes, `AGENT_MODEL=claude-sonnet-4-6` corta o custo em ~40%.

## Solução de problemas

| Sintoma | Causa provável / ação |
|---|---|
| `Sessão encerrada no celular (logged out)` | O dispositivo foi desconectado no WhatsApp. Apague `data/auth/` e reinicie para escanear de novo. |
| Bot não responde um cliente | Chat pausado (handoff ou `!pausar`) → `!status` mostra; ou `CLIENT_MODE=off/allowlist`. |
| `ANTHROPIC_API_KEY inválida` nos logs | Chave errada/ausente no `.env`. |
| Respostas truncadas | Aumente `MAX_TOKENS`. |
