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
const { generateReply, extractIdentity } = require('./agent');
const media = require('./media');
const clientes = require('./clientes');

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

// Remove emojis e símbolos pictográficos (formalidade no atendimento a clientes).
function stripEmojis(text) {
  return text
    .replace(
      /[\u{1F000}-\u{1FAFF}\u{2600}-\u{27BF}\u{2B00}-\u{2BFF}\u{2190}-\u{21FF}\u{FE00}-\u{FE0F}\u{1F1E6}-\u{1F1FF}\u{200D}\u{20E3}\u{2122}\u{2139}]/gu,
      ''
    )
    .replace(/[ \t]{2,}/g, ' ')
    .replace(/ +\n/g, '\n')
    .trim();
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

  // Identificação do cliente + salvamento de documentos (só no modo cliente,
  // e só se a pasta de clientes existir).
  let systemNote = '';
  if (!admin && clientes.enabled()) {
    let profile = store.getProfile(jid);

    // enquanto não confirmado, tenta captar nome/apólice/operadora da conversa
    if (!profile.confirmed) {
      const found = await extractIdentity(store.history(jid));
      if (found.nome || found.apolice || found.operadora) {
        profile = store.setProfile(jid, found);
      }
    }

    // salva documento recebido (só arquiva no cliente se já confirmado)
    if (attachment) {
      const saved = clientes.saveDocument(profile, attachment, numberOf(jid));
      if (saved && saved.identified) {
        console.log(`Documento salvo: ${saved.path}`);
      } else if (saved) {
        console.log(`Documento em retenção: ${saved.path}`);
        // só avisa o dono se realmente não há cadastro correspondente
        if (!clientes.resolveFolder(profile)) {
          await notifyOwner(
            sock,
            `📎 Documento recebido de ${numberOf(jid)}, mas o cadastro do cliente ` +
              `não foi localizado. Salvo em retenção "_a_identificar". Favor conferir.`
          ).catch(() => {});
        }
      }
    }

    // nota do sistema para o agente confirmar o cadastro antes de arquivar
    if (!profile.confirmed) {
      const m = clientes.resolveFolder(profile);
      if (m) {
        systemNote =
          `[SISTEMA] Cadastro localizado: cliente "${m.nome}" na operadora ` +
          `"${m.operadora}". Antes de considerar os documentos arquivados, CONFIRME ` +
          `com o cliente de forma cortês (ex.: "Localizei o cadastro de ${m.nome} na ` +
          `${m.operadora}. O(a) senhor(a) confirma?"). Quando o cliente CONFIRMAR que ` +
          `é o cadastro correto, inclua na ÚLTIMA linha da resposta a etiqueta ` +
          `[[CLIENTE_CONFIRMADO]] (sinal interno; o cliente não a vê).`;
      } else if (profile.nome || profile.apolice) {
        systemNote =
          '[SISTEMA] Ainda não foi possível localizar o cadastro com os dados ' +
          'informados. Peça com cortesia o NOME COMPLETO exato e a OPERADORA ' +
          '(ex.: VUMI, Cigna) para localizar. NÃO afirme que localizou o cadastro.';
      }
    }
  }

  await sock.presenceSubscribe(jid).catch(() => {});
  await sock.sendPresenceUpdate('composing', jid).catch(() => {});

  const raw = await generateReply(store.history(jid), admin, attachment, systemNote);

  // Marcadores internos do agente (removidos antes de enviar ao cliente):
  //  [[HANDOFF]]            -> cliente quer o Concierge (pausa + avisa dono)
  //  [[CLIENTE_CONFIRMADO]] -> cliente confirmou o cadastro (arquiva documentos)
  const wantsConcierge = !admin && raw.includes('[[HANDOFF]]');
  const clienteConfirmado = !admin && raw.includes('[[CLIENTE_CONFIRMADO]]');
  let reply = raw.replace(/\s*\[\[(HANDOFF|CLIENTE_CONFIRMADO)\]\]\s*/g, '').trim();
  // Garantia extra de formalidade: nenhum emoji vai para o cliente.
  if (!admin) reply = stripEmojis(reply);

  await sock.sendPresenceUpdate('paused', jid).catch(() => {});
  await sendText(sock, jid, reply);
  store.pushMessage(jid, 'assistant', reply);

  // Cliente confirmou o cadastro: marca confirmado e move documentos retidos
  // (enviados antes da confirmação) para a pasta do cliente.
  if (clienteConfirmado) {
    const prof = store.setProfile(jid, { confirmed: true });
    const moved = clientes.moveRetained(numberOf(jid), prof);
    if (moved > 0) console.log(`${moved} documento(s) movido(s) para a pasta de ${prof.nome}.`);
  }

  if (wantsConcierge) {
    // Avisa o dono, mas NÃO pausa o bot: o cliente pode mudar de ideia e
    // continuar (reembolso, etc.). O bot só se cala quando o dono responder o
    // cliente manualmente (handoff automático via fromMe).
    const prof = store.getProfile(jid);
    const quem = prof.nome ? `${prof.nome} (${numberOf(jid)})` : numberOf(jid);
    console.log(`Concierge solicitado por ${quem}.`);
    await notifyOwner(
      sock,
      `🔔 *Concierge solicitado*\nCliente: ${quem}` +
        (prof.apolice ? `\nApólice: ${prof.apolice}` : '') +
        `\nO cliente pediu atendimento humano. O assistente continua disponível ` +
        `caso ele siga escrevendo; assuma a conversa quando puder.`
    ).catch((e) => console.error('Falha ao notificar dono:', e.message));
  }
}

// Envia um aviso ao dono (chat "você mesmo" e/ou números ADMIN configurados).
async function notifyOwner(sock, text) {
  const selfJid = jidNormalizedUser(sock.user?.id || '');
  const targets = new Set();
  if (selfJid) targets.add(selfJid);
  for (const n of config.adminNumbers) targets.add(`${n}@s.whatsapp.net`);
  for (const t of targets) {
    await sendText(sock, t, text).catch(() => {});
  }
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

      // log de diagnóstico: registra TODA mensagem recebida
      console.log(
        `[msg] de=${numberOf(jid)} fromMe=${!!msg.key.fromMe} midia=${hasMedia} texto=${JSON.stringify(
          (text || '').slice(0, 80)
        )}`
      );

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
