// Configuração via variáveis de ambiente (ver .env.example)
'use strict';

// Carrega o .env quando rodando localmente (npm start). No Docker do NAS as
// variáveis vêm do env_file do compose, e o .env pode não existir — o dotenv
// simplesmente ignora nesse caso.
require('dotenv').config();

const path = require('path');

function parseNumbers(raw) {
  return (raw || '')
    .split(',')
    .map((s) => s.replace(/\D/g, ''))
    .filter(Boolean);
}

const config = {
  // Claude
  model: process.env.AGENT_MODEL || 'claude-opus-4-8',
  effort: process.env.AGENT_EFFORT || 'medium', // low | medium | high
  maxTokens: parseInt(process.env.MAX_TOKENS || '1024', 10),

  // Identidade
  botName: process.env.BOT_NAME || 'Assistente Hamsa',

  // Números com acesso de administrador (além do próprio chat "você mesmo").
  // Formato: só dígitos com DDI, separados por vírgula. Ex.: 5511999999999
  adminNumbers: parseNumbers(process.env.ADMIN_NUMBERS),

  // Números que RECEBEM os avisos do bot (🔔 concierge, documentos etc.) sem
  // virar admin — o atendimento deles segue normal (modo cliente). Use para o
  // celular pessoal do dono. Mesmo formato do ADMIN_NUMBERS.
  notifyNumbers: parseNumbers(process.env.NOTIFY_NUMBERS),

  // Modo de atendimento a clientes:
  //   all       -> responde qualquer número que mandar mensagem
  //   allowlist -> responde só ALLOWED_NUMBERS
  //   off       -> não responde clientes (só modo admin)
  clientMode: process.env.CLIENT_MODE || 'all',
  allowedNumbers: parseNumbers(process.env.ALLOWED_NUMBERS),

  // Quando o Sérgio responde um cliente manualmente pelo celular,
  // o bot pausa naquele chat por este tempo (minutos).
  handoffPauseMinutes: parseInt(process.env.HANDOFF_PAUSE_MINUTES || '60', 10),

  // Memória de conversa: quantas mensagens manter por chat
  maxHistory: parseInt(process.env.MAX_HISTORY || '40', 10),

  // Memória de longo prazo por cliente (ficha _FICHA.md na pasta da rede,
  // com resumo da relação + controle de claims/franquia). Requer CLIENTES_DIR.
  // Defina FICHA_ENABLED=false para desligar.
  fichaEnabled: (process.env.FICHA_ENABLED || 'true') !== 'false',

  // Pasta de dados (sessão do WhatsApp + histórico)
  dataDir: process.env.DATA_DIR || 'data',

  // Conhecimento de produto: ingestão dos materiais das seguradoras.
  // PRODUTOS_DIR = pasta "SEGUROS SAUDE" montada no container (ex.: /produtos).
  // Só as subpastas de PRODUTOS_SUBPASTAS são lidas (foco em condições e
  // brochuras; ignora vídeos/treinamentos/etc.). As fichas destiladas ficam em
  // PRODUTOS_KB_DIR e são carregadas pelo bot.
  produtosDir: process.env.PRODUTOS_DIR || '',
  produtosSubpastas: (process.env.PRODUTOS_SUBPASTAS || 'BROCHURAS,APOLICES')
    .split(',')
    .map((s) => s.trim())
    .filter(Boolean),
  produtosKbDir: process.env.PRODUTOS_KB_DIR || path.join('data', 'produtos'),
  produtosMaxChars: parseInt(process.env.PRODUTOS_MAX_CHARS || '300000', 10),
  // Filtro opcional de seguradoras (vírgula). Vazio = todas as pastas.
  produtosCarriers: (process.env.PRODUTOS_CARRIERS || '')
    .split(',')
    .map((s) => s.trim())
    .filter(Boolean),

  // DEBUG temporário: espelha no WhatsApp do dono o resultado da localização do
  // cadastro (o que foi extraído e se casou). Desligue com RESOLVE_DEBUG=false.
  resolveDebug: (process.env.RESOLVE_DEBUG || 'false') === 'true',

  // Envio de documentos da pasta ao cliente: automático (true) ou sob aprovação
  // do dono (false). Automático só vale para cliente já CONFIRMADO; o dono
  // recebe um registro (WhatsApp + e-mail) de cada envio.
  docSendAuto: (process.env.DOC_SEND_AUTO || 'true') !== 'false',

  // Notificação por e-mail quando um documento é arquivado (quem submeteu).
  // Requer SMTP_* e NOTIFY_EMAIL; sem eles, o recurso fica desligado.
  notifyEmail: process.env.NOTIFY_EMAIL || '',
  smtp: {
    host: process.env.SMTP_HOST || '',
    port: parseInt(process.env.SMTP_PORT || '587', 10),
    secure: (process.env.SMTP_SECURE || 'false') === 'true', // true = porta 465
    user: process.env.SMTP_USER || '',
    pass: process.env.SMTP_PASS || '',
    from: process.env.SMTP_FROM || process.env.SMTP_USER || '',
  },
};

if (!process.env.ANTHROPIC_API_KEY) {
  console.error('ERRO: defina ANTHROPIC_API_KEY no ambiente (.env)');
  process.exit(1);
}

module.exports = config;
