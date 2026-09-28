// Consulta o banco do RENOVACOES APP (SQLite) para obter o PLANO e a FRANQUIA
// ATUAIS do cliente — os da ÚLTIMA renovação (a coluna plano/franquia da tabela
// apolices, mantida pelo sync das seguradoras). Fonte de verdade do plano atual.
//
// Requer RENOVACOES_DB apontando para o renovacoes.db montado (só leitura). Como
// o banco é WAL e está vivo, copiamos os arquivos para /tmp antes de abrir
// (mesma tática do gerar_emails_renovacao.py) — evita trava e lê o estado atual.
// Sem RENOVACOES_DB ou em qualquer erro, devolve null e o bot usa o fallback.
'use strict';

const fs = require('fs');

let Database = null;
try {
  Database = require('better-sqlite3');
} catch {
  Database = null;
}

const DB_PATH = process.env.RENOVACOES_DB || '';
const TMP = '/tmp/renovacoes_ro.db';
const TTL_MS = 10 * 60 * 1000; // recopia no máximo a cada 10 min

let db = null;
let copiedAt = 0;

function norm(s) {
  return (s || '')
    .normalize('NFD')
    .replace(/[̀-ͯ]/g, '')
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, ' ')
    .trim();
}

function open() {
  if (!Database || !DB_PATH) return null;
  const now = Date.now();
  if (db && now - copiedAt < TTL_MS) return db;
  try {
    if (!fs.existsSync(DB_PATH)) {
      console.warn(`renovacoes.db não encontrado: ${DB_PATH}`);
      return null;
    }
    // copia db (+ wal/shm) para um local gravável e abre a cópia
    fs.copyFileSync(DB_PATH, TMP);
    for (const ext of ['-wal', '-shm']) {
      try {
        if (fs.existsSync(DB_PATH + ext)) fs.copyFileSync(DB_PATH + ext, TMP + ext);
      } catch {
        /* ignora */
      }
    }
    if (db) {
      try {
        db.close();
      } catch {
        /* ignora */
      }
    }
    db = new Database(TMP, { readonly: true, fileMustExist: true });
    copiedAt = now;
    return db;
  } catch (e) {
    console.warn('renovacoes.db indisponível:', e.message);
    db = null;
    return null;
  }
}

function fmtFranquia(v) {
  if (v == null || v === '') return '';
  const n = Number(v);
  if (!Number.isFinite(n) || n === 0) return String(v);
  return `US$ ${n.toLocaleString('en-US')}`;
}

function mostRecent(rows) {
  return rows
    .slice()
    .sort((a, b) =>
      String(b.data_inicio_vigencia || '').localeCompare(String(a.data_inicio_vigencia || ''))
    )[0];
}

// Retorna { plano, franquia, apolice, operadora } da última renovação, ou null.
function lookup({ nome, apolice, operadora } = {}) {
  const d = open();
  if (!d) return null;
  try {
    const rows = d
      .prepare(
        `SELECT c.nome AS cliente, a.numero_apolice, a.seguradora, a.plano, a.franquia,
                a.data_inicio_vigencia
           FROM apolices a JOIN clientes c ON a.cliente_id = c.id
          WHERE a.status = 'ativo'`
      )
      .all();
    if (!rows.length) return null;

    const pick = (r) => ({
      plano: (r.plano || '').trim(),
      franquia: fmtFranquia(r.franquia),
      apolice: r.numero_apolice || '',
      operadora: r.seguradora || '',
    });

    // 1) por número de apólice (mais confiável)
    const dig = (apolice || '').replace(/\D/g, '');
    if (dig.length >= 4) {
      const hits = rows.filter((r) => String(r.numero_apolice || '').replace(/\D/g, '').includes(dig));
      if (hits.length) return pick(mostRecent(hits));
    }

    // 2) por nome (+ operadora, se houver)
    const nn = norm(nome);
    if (nn) {
      let cands = rows;
      const nop = norm(operadora);
      if (nop) {
        const f = cands.filter((r) => {
          const co = norm(r.seguradora);
          return co && (co.includes(nop) || nop.includes(co));
        });
        if (f.length) cands = f;
      }
      const exact = cands.filter((r) => norm(r.cliente) === nn);
      if (exact.length) return pick(mostRecent(exact));
      const toks = nn.split(' ').filter(Boolean);
      if (toks.length >= 2) {
        const m = cands.filter((r) => {
          const fn = norm(r.cliente);
          return toks.every((t) => fn.includes(t));
        });
        if (m.length === 1 || (m.length && new Set(m.map((r) => r.numero_apolice)).size === 1)) {
          return pick(mostRecent(m));
        }
      }
    }
    return null;
  } catch (e) {
    console.error('Falha ao consultar renovacoes.db:', e.message);
    return null;
  }
}

function available() {
  return !!open();
}

module.exports = { lookup, available };
