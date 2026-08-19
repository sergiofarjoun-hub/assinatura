// Envio de e-mail de notificação (nodemailer via SMTP).
// Usado para avisar o dono, por e-mail, sempre que um documento de cliente é
// arquivado. Fica DESLIGADO silenciosamente se o SMTP/destino não estiverem
// configurados (o agente continua funcionando normalmente).
'use strict';

const nodemailer = require('nodemailer');
const config = require('./config');

let transporter = null;
let warned = false;

function enabled() {
  const s = config.smtp;
  const ok = !!(s.host && s.user && s.pass && config.notifyEmail);
  if (!ok && !warned) {
    console.warn(
      'Notificação por e-mail desligada: defina SMTP_HOST, SMTP_USER, SMTP_PASS ' +
        'e NOTIFY_EMAIL no .env para ativar.'
    );
    warned = true;
  }
  return ok;
}

function getTransport() {
  if (!transporter) {
    transporter = nodemailer.createTransport({
      host: config.smtp.host,
      port: config.smtp.port,
      secure: config.smtp.secure,
      auth: { user: config.smtp.user, pass: config.smtp.pass },
    });
  }
  return transporter;
}

// Envia um e-mail de texto simples. Nunca lança — em erro só registra no log.
async function sendMail(subject, text) {
  if (!enabled()) return false;
  try {
    await getTransport().sendMail({
      from: config.smtp.from || config.smtp.user,
      to: config.notifyEmail,
      subject,
      text,
    });
    return true;
  } catch (err) {
    console.error('Falha ao enviar e-mail de notificação:', err.message);
    return false;
  }
}

module.exports = { enabled, sendMail };
