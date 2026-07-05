// Persistência simples em JSON: histórico de conversas + chats pausados.
// Arquivo: <dataDir>/state.json (gravação com debounce).
'use strict';

const fs = require('fs');
const path = require('path');
const config = require('./config');

const FILE = path.join(config.dataDir, 'state.json');

let state = { conversations: {}, paused: {} };
let saveTimer = null;

function load() {
  try {
    state = JSON.parse(fs.readFileSync(FILE, 'utf8'));
    state.conversations = state.conversations || {};
    state.paused = state.paused || {};
  } catch {
    state = { conversations: {}, paused: {} };
  }
}

function save() {
  if (saveTimer) return;
  saveTimer = setTimeout(() => {
    saveTimer = null;
    fs.mkdirSync(config.dataDir, { recursive: true });
    fs.writeFileSync(FILE, JSON.stringify(state));
  }, 500);
}

function history(jid) {
  return state.conversations[jid] || [];
}

function pushMessage(jid, role, content) {
  const conv = state.conversations[jid] || (state.conversations[jid] = []);
  conv.push({ role, content });
  // mantém só as últimas N mensagens, começando sempre em "user"
  while (conv.length > config.maxHistory || (conv.length && conv[0].role !== 'user')) {
    conv.shift();
  }
  save();
}

function clearHistory(jid) {
  if (jid === '*') state.conversations = {};
  else delete state.conversations[jid];
  save();
}

function pauseChat(jid, minutes) {
  state.paused[jid] = Date.now() + minutes * 60_000;
  save();
}

function resumeChat(jid) {
  delete state.paused[jid];
  save();
}

function isPaused(jid) {
  const until = state.paused[jid];
  if (!until) return false;
  if (Date.now() > until) {
    delete state.paused[jid];
    save();
    return false;
  }
  return true;
}

function pausedChats() {
  const now = Date.now();
  return Object.entries(state.paused)
    .filter(([, until]) => until > now)
    .map(([jid, until]) => ({ jid, minutesLeft: Math.ceil((until - now) / 60_000) }));
}

function conversationCount() {
  return Object.keys(state.conversations).length;
}

load();

module.exports = {
  history,
  pushMessage,
  clearHistory,
  pauseChat,
  resumeChat,
  isPaused,
  pausedChats,
  conversationCount,
};
