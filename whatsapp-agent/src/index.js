// Agente de IA para WhatsApp da Hamsa (Baileys + Claude).
//
// Dois modos:
//   - ADMIN: chat "você mesmo" (mensagem para si próprio) e números em
//     ADMIN_NUMBERS -> assistente pessoal completo + comandos "!".
//   - CLIENTE: qualquer outro contato -> assistente de atendimento da
//     corretora, com regras restritas (ver prompts.js).
//
// Handoff humano: se o Sérgio responder um cliente manualmente pelo celular,
// o bot pausa naquele chat por HANDOFF_PAUSE_MINUTES.
'use strict';

const makeWASocket = require('@whiskeysockets/baileys').default;
const {
  useMultiFileAuthState,
  DisconnectReason,
  jidNormalizedUser,
  fetchLatestBaileysVersion,
} = require('@whiskeysockets/baileys');
const pino = require('pino');
const qrcode = require('qrcode-terminal');
const path = require('path');

const config = require('./config');
const store = require('./store');
const { generateReply } = require('./agent');
const media = require('./media');

const logger = pino({ level: process.env.LOG_LEVEL || 'warn' });

// ids das mensagens enviadas pelo próprio bot (para distinguir de respostas
// manuais do Sérgio, que também chegam como fromMe)
const sentByBot = new Set();
function rememberSent(id) {
  if (!id) return;
  sentByBot.add(id);
  if (sentByBot.size > 2000) {
    for (const old of sentByBot) {
      sentByBot.delete(old);
      if (sentByBot.size <= 1000) break;
    }
  }
}

// fila por chat: evita respostas concorrentes na mesma conversa
const chatQueues = new Map();
function enqueue(jid, task) {
  const prev = chatQueues.get(jid) || Promise.resolve();
  const next = prev.then(task).catch((err) => console.error(`Erro no chat ${jid}:`, err));
  chatQueues.set(jid, next);
  return next;
}

function numberOf(jid) {
  return (jid || '').split('@')[0].split(':')[0].replace(/\D/g, '');
}

function extractText(msg) {
  const m = msg.message || {};
  return (
    m.conversation ||
    m.extendedTextMessage?.text ||
    m.imageMessage?.caption ||
    m.videoMessage?.caption ||
    ''
  ).trim();
}

async function sendText(sock, jid, text) {
  const sent = await sock.sendMessage(jid, { text });
  rememberSent(sent?.key?.id);
  return sent;
}

// ---------- comandos de admin ----------

const HELP = [
  '*Comandos do agente:*',
  '!ajuda — esta lista',
  '!status — estado do agente',
  '!pausar <numero> — pausa o bot num chat de cliente',
  '!ativar <numero> — reativa o bot num chat',
  '!limpar [numero|tudo] — apaga histórico (sem número: deste chat)',
].join('\n');

async function handleCommand(sock, jid, text) {
  const [cmd, ...args] = text.slice(1).trim().split(/\s+/);
  const arg = (args[0] || '').replace(/\D/g, '');
  const argJid = arg ? `${arg}@s.whatsapp.net` : null;

  switch (cmd.toLowerCase()) {
    case 'ajuda':
    case 'help':
      return sendText(sock, jid, HELP);

    case 'status': {
      const paused = store.pausedChats();
      const lines = [
        `*${config.botName}* — online ✅`,
        `Modelo: ${config.model} (effort: ${config.effort})`,
        `Modo clientes: ${config.clientMode}`,
        `Conversas na memória: ${store.conversationCount()}`,
        paused.length
          ? `Chats pausados:\n${paused.map((p) => `- ${numberOf(p.jid)} (${p.minutesLeft} min restantes)`).join('\n')}`
          : 'Nenhum chat pausado.',
      ];
      return sendText(sock, jid, lines.join('\n'));
    }

    case 'pausar':
      if (!argJid) return sendText(sock, jid, 'Uso: !pausar 5511999999999');
      store.pauseChat(argJid, 60 * 24 * 365); // pausa "permanente" (1 ano)
      return sendText(sock, jid, `Bot pausado para ${arg}. Use !ativar ${arg} para voltar.`);

    case 'ativar':
      if (!argJid) return sendText(sock, jid, 'Uso: !ativar 5511999999999');
      store.resumeChat(argJid);
      return sendText(sock, jid, `Bot reativado para ${arg}.`);

    case 'limpar':
      if (args[0] === 'tudo') {
        store.clearHistory('*');
        return sendText(sock, jid, 'Histórico de TODAS as conversas apagado.');
      }
      store.clearHistory(argJid || jid);
      return sendText(sock, jid, `Histórico apagado (${arg || 'este chat'}).`);

    default:
      return sendText(sock, jid, `Comando desconhecido: !${cmd}\n\n${HELP}`);
  }
}

// ---------- resposta com IA ----------

async function respond(sock, jid, text, admin, msg) {
  // Se veio imagem/PDF, baixa para o agente analisar o documento.
  let attachment = null;
  if (msg && media.detectMedia(msg)) {
    try {
      attachment = await media.download(sock, msg, logger);
    } catch (err) {
      if (err.tooLarge) {
        return sendText(
          sock,
          jid,
          'O arquivo enviado é muito grande para eu analisar. Por gentileza, ' +
            'reenvie uma versão menor ou uma foto mais nítida do documento.'
        );
      }
      console.error(`Falha ao baixar mídia de ${numberOf(jid)}:`, err.message);
      // segue sem o anexo (responde ao texto/legenda, se houver)
    }
  }

  // Texto guardado no histórico: legenda, ou uma nota indicando o anexo.
  let stored = text;
  if (attachment && !stored) {
    stored = attachment.kind === 'pdf' ? '(enviou um documento PDF)' : '(enviou uma imagem)';
  }
  if (!stored) return; // nada de útil (ex.: áudio/figurinha sem legenda)

  store.pushMessage(jid, 'user', stored);

  await sock.presenceSubscribe(jid).catch(() => {});
  await sock.sendPresenceUpdate('composing', jid).catch(() => {});

  const reply = await generateReply(store.history(jid), admin, attachment);

  await sock.sendPresenceUpdate('paused', jid).catch(() => {});
  await sendText(sock, jid, reply);
  store.pushMessage(jid, 'assistant', reply);
}

// ---------- loop principal ----------

async function start() {
  const authDir = path.join(config.dataDir, 'auth');
  const { state, saveCreds } = await useMultiFileAuthState(authDir);
  const { version } = await fetchLatestBaileysVersion().catch(() => ({ version: undefined }));

  const sock = makeWASocket({
    version,
    auth: state,
    logger,
    markOnlineOnConnect: false, // não rouba as notificações do celular
    syncFullHistory: false,
  });

  sock.ev.on('creds.update', saveCreds);

  sock.ev.on('connection.update', ({ connection, lastDisconnect, qr }) => {
    if (qr) {
      console.log('\nEscaneie o QR code abaixo no WhatsApp do celular');
      console.log('(WhatsApp > Configurações > Dispositivos conectados > Conectar dispositivo):\n');
      qrcode.generate(qr, { small: true });
    }
    if (connection === 'open') {
      console.log(`✅ Conectado como ${sock.user?.id} — ${config.botName} no ar.`);
    }
    if (connection === 'close') {
      const code = lastDisconnect?.error?.output?.statusCode;
      if (code === DisconnectReason.loggedOut) {
        console.error(
          'Sessão encerrada no celular (logged out). Apague a pasta data/auth e reinicie para parear de novo.'
        );
        process.exit(1);
      }
      console.log(`Conexão caiu (código ${code}). Reconectando em 3s...`);
      setTimeout(() => start().catch(console.error), 3000);
    }
  });

  sock.ev.on('messages.upsert', ({ messages, type }) => {
    if (type !== 'notify') return;
    const selfJid = jidNormalizedUser(sock.user?.id || '');

    for (const msg of messages) {
      const jid = msg.key?.remoteJid;
      if (!msg.message || !jid) continue;
      if (jid === 'status@broadcast' || jid.endsWith('@g.us') || jid.endsWith('@broadcast')) continue;

      const text = extractText(msg);
      const hasMedia = !!media.detectMedia(msg);

      if (msg.key.fromMe) {
        if (sentByBot.has(msg.key.id)) continue; // mensagem do próprio bot

        if (jid === selfJid) {
          // chat "você mesmo" = console do admin
          if (!text && !hasMedia) continue;
          enqueue(jid, () =>
            text.startsWith('!')
              ? handleCommand(sock, jid, text)
              : respond(sock, jid, text, true, msg)
          );
        } else if (config.handoffPauseMinutes > 0) {
          // resposta manual do dono a um cliente -> bot sai de cena
          store.pauseChat(jid, config.handoffPauseMinutes);
          console.log(
            `Handoff: resposta manual em ${numberOf(jid)} — bot pausado por ${config.handoffPauseMinutes} min.`
          );
        }
        continue;
      }

      // mensagem recebida de terceiros
      const sender = numberOf(jid);
      const isAdmin = config.adminNumbers.includes(sender);

      if (!text && !hasMedia) continue; // áudio/figurinha sem legenda: ignora

      if (isAdmin) {
        enqueue(jid, () =>
          text.startsWith('!')
            ? handleCommand(sock, jid, text)
            : respond(sock, jid, text, true, msg)
        );
        continue;
      }

      // modo cliente
      if (config.clientMode === 'off') continue;
      if (config.clientMode === 'allowlist' && !config.allowedNumbers.includes(sender)) continue;
      if (store.isPaused(jid)) continue;

      enqueue(jid, () => respond(sock, jid, text, false, msg));
    }
  });
}

console.log(`${config.botName} iniciando (modelo ${config.model})...`);
start().catch((err) => {
  console.error('Falha fatal ao iniciar:', err);
  process.exit(1);
});
