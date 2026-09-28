// Detecção e download de mídia (imagem / PDF) das mensagens do WhatsApp,
// para o agente analisar documentos (nota fiscal, pedido médico, etc.).
'use strict';

const { downloadMediaMessage } = require('@whiskeysockets/baileys');

// Limite de tamanho do arquivo para enviar ao Claude (bytes). Acima disso,
// pedimos ao cliente para reenviar menor/mais nítido.
const MAX_BYTES = 8 * 1024 * 1024; // 8 MB

const IMAGE_TYPES = ['image/jpeg', 'image/png', 'image/webp', 'image/gif'];

// Retorna um descritor { kind, mimetype, filename } se a mensagem contém
// imagem ou PDF analisável; caso contrário null.
function detectMedia(msg) {
  const m = msg.message || {};
  const doc = m.documentMessage || m.documentWithCaptionMessage?.message?.documentMessage;

  if (m.imageMessage) {
    return { kind: 'image', mimetype: m.imageMessage.mimetype || 'image/jpeg' };
  }
  if (doc) {
    const mt = doc.mimetype || '';
    if (mt === 'application/pdf') {
      return { kind: 'pdf', mimetype: 'application/pdf', filename: doc.fileName };
    }
    if (IMAGE_TYPES.includes(mt)) {
      return { kind: 'image', mimetype: mt, filename: doc.fileName };
    }
  }
  return null;
}

// Baixa a mídia e devolve { kind, mediaType, dataB64 } pronto para o Claude,
// ou lança um objeto { tooLarge: true } / erro em caso de falha.
async function download(sock, msg, logger) {
  const info = detectMedia(msg);
  if (!info) return null;

  const buffer = await downloadMediaMessage(
    msg,
    'buffer',
    {},
    { logger, reuploadRequest: sock.updateMediaMessage }
  );

  if (!buffer || buffer.length === 0) throw new Error('download vazio');
  if (buffer.length > MAX_BYTES) {
    const err = new Error('arquivo grande demais');
    err.tooLarge = true;
    throw err;
  }

  return {
    kind: info.kind,
    mediaType: info.mimetype,
    dataB64: buffer.toString('base64'),
    filename: info.filename,
  };
}

module.exports = { detectMedia, download, MAX_BYTES };
