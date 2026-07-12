// Busca de BROCHURAS de produto (PDFs originais) no cofre de conhecimento.
//
// A ingestão (src/ingest-produtos.js) já lê as brochuras das seguradoras para
// destilar as FICHAS DE PRODUTO (texto) usadas pelo bot para responder
// dúvidas. Além disso, ela copia o PDF original de cada brochura para dentro
// do cofre, em <PRODUTOS_KB_DIR>/<Seguradora>/Brochuras/<arquivo>.pdf — este
// módulo procura ali quando o cliente pede o ARQUIVO da brochura (não só uma
// explicação). O cofre já é montado (read-only) no bot em produção, então
// nenhuma configuração extra é necessária para enviar.
'use strict';

const fs = require('fs');
const path = require('path');
const config = require('./config');

function norm(s) {
  return (s || '')
    .normalize('NFD')
    .replace(/[̀-ͯ]/g, '')
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, ' ')
    .trim();
}

function enabled() {
  return !!config.produtosKbDir && fs.existsSync(config.produtosKbDir);
}

function walkPdfs(dir, depth, cb, rel) {
  let entries;
  try {
    entries = fs.readdirSync(dir, { withFileTypes: true });
  } catch {
    return;
  }
  for (const e of entries) {
    if (e.name.startsWith('.') || e.name === '@eaDir' || e.name === '#recycle') continue;
    const full = path.join(dir, e.name);
    if (e.isDirectory()) {
      if (depth > 0) walkPdfs(full, depth - 1, cb, rel ? path.join(rel, e.name) : e.name);
    } else if (e.isFile() && e.name.toLowerCase().endsWith('.pdf')) {
      cb(full, rel || '', e.name);
    }
  }
}

// Acha brochuras de produto que casam com o pedido (ex.: "brochura VUMI",
// "produto Universal da Ever"). Pontua por número de termos casados (nome da
// seguradora, do produto etc.) contra a subpasta + nome do arquivo; em
// empate, o arquivo mais recente primeiro. Só considera o que a ingestão
// copiou para Brochuras/ (nunca a pasta de apólices/contratos).
function findBrochura(query, limit = 5) {
  if (!enabled()) return [];
  const qtokens = norm(query).split(' ').filter(Boolean);
  if (!qtokens.length) return [];
  const out = [];
  walkPdfs(config.produtosKbDir, 4, (full, rel, name) => {
    if (!norm(rel).includes('brochura')) return;
    const hay = norm(`${rel} ${name}`);
    const score = qtokens.filter((t) => hay.includes(t)).length;
    if (score > 0) out.push({ path: full, name, rel, score });
  });

  // SEMPRE a edição mais recente: várias edições da mesma brochura convivem na
  // pasta (2023, 2024...). Desempate por (1) ano mais alto citado no nome/pasta
  // e (2) data do arquivo — nunca enviar edição antiga havendo mais nova.
  const year = (d) => {
    const m = `${d.rel} ${d.name}`.match(/20\d{2}/g);
    return m ? Math.max(...m.map(Number)) : 0;
  };
  const mtime = (d) => {
    try {
      return fs.statSync(d.path).mtimeMs;
    } catch {
      return 0;
    }
  };
  out.sort((a, b) => {
    if (b.score !== a.score) return b.score - a.score;
    const ya = year(a);
    const yb = year(b);
    if (ya && yb && ya !== yb) return yb - ya;
    return mtime(b) - mtime(a);
  });

  return out.slice(0, limit);
}

module.exports = { enabled, findBrochura };
