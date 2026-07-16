// Registro de APRENDIZADO do bot: feedback dos clientes e lacunas de
// conhecimento, capturados durante o atendimento via etiquetas internas
// ([[FEEDBACK: ...]] e [[LACUNA: ...]] — ver prompts.js).
//
// Cada evento vira uma linha JSON em <dataDir>/aprendizado.jsonl. O script
// src/analyze-fichas.js consome esse log (junto com as fichas dos clientes)
// para gerar o relatório de melhoria e atualizar o FAQ_APRENDIDO.md no cofre.
// Nunca lança — falha de gravação só aparece no log do agente.
'use strict';

const fs = require('fs');
const path = require('path');
const config = require('./config');

const FILE = path.join(config.dataDir, 'aprendizado.jsonl');

// tipo: 'feedback' (ex.: "positivo — posição da franquia") ou
//       'lacuna'   (pergunta que o bot não soube responder pela base)
function log(tipo, texto, profile, numero) {
  try {
    const p = profile || {};
    const ev = {
      ts: new Date().toISOString(),
      tipo,
      texto: (texto || '').trim(),
      cliente: p.nome || '',
      operadora: p.operadora || '',
      plano: p.plano || '',
      numero: numero || '',
    };
    fs.mkdirSync(path.dirname(FILE), { recursive: true });
    fs.appendFileSync(FILE, JSON.stringify(ev) + '\n');
  } catch (err) {
    console.error('Falha ao registrar evento de aprendizado:', err.message);
  }
}

// Lê todos os eventos ainda não processados. Linhas corrompidas são ignoradas.
function readAll() {
  let raw;
  try {
    raw = fs.readFileSync(FILE, 'utf8');
  } catch {
    return [];
  }
  const out = [];
  for (const line of raw.split('\n')) {
    if (!line.trim()) continue;
    try {
      out.push(JSON.parse(line));
    } catch {
      /* ignora linha corrompida */
    }
  }
  return out;
}

// Arquiva o log atual após uma análise bem-sucedida (evita recontar os mesmos
// eventos na próxima rodada). Mantém o histórico em aprendizado-<data>.jsonl.
function archive() {
  try {
    if (!fs.existsSync(FILE)) return false;
    const stamp = new Date().toISOString().slice(0, 10);
    let dest = path.join(config.dataDir, `aprendizado-${stamp}.jsonl`);
    let n = 1;
    while (fs.existsSync(dest)) {
      dest = path.join(config.dataDir, `aprendizado-${stamp}-${n++}.jsonl`);
    }
    fs.renameSync(FILE, dest);
    return true;
  } catch (err) {
    console.error('Falha ao arquivar log de aprendizado:', err.message);
    return false;
  }
}

module.exports = { log, readAll, archive, FILE };
