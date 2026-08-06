#!/usr/bin/env node
/**
 * plaud-sync — importa gravações do Plaud para o vault do Obsidian como notas Markdown.
 *
 * Fala direto com a API oficial (platform.plaud.ai), reaproveitando o login do
 * Plaud CLI (~/.plaud/tokens.json, criado por `npx -y @plaud-ai/cli login`).
 * Incremental e idempotente: gravações já importadas são puladas; gravações sem
 * transcrição/resumo ficam pendentes e são re-checadas nas próximas execuções.
 *
 * Uso:  node plaud-sync.mjs [--verbose] [--dry-run]
 * Config: ~/.plaud-obsidian-sync/config.json  { "vaultDir": "...", "subdir": "Plaud", "firstRunDays": 30 }
 * Estado: <vault>/<subdir>/.plaud-sync-state.json
 */

import { readFile, writeFile, mkdir, rename, rm, readdir, stat } from 'fs/promises';
import { existsSync } from 'fs';
import { join } from 'path';
import { homedir } from 'os';

// ---------------------------------------------------------------- constantes

const API_BASE = process.env.PLAUD_API_BASE ?? 'https://platform.plaud.ai/developer/api';
const REFRESH_URL = process.env.PLAUD_REFRESH_URL ?? 'https://platform.plaud.ai/developer/api/oauth/third-party/access-token/refresh';
const TOKENS_PATH = process.env.PLAUD_TOKENS_PATH ?? join(homedir(), '.plaud', 'tokens.json');
const CONFIG_PATH = process.env.PLAUD_SYNC_CONFIG ?? join(homedir(), '.plaud-obsidian-sync', 'config.json');
const LOCK_PATH = join(homedir(), '.plaud-obsidian-sync', 'sync.lock');

const PAGE_SIZE = 100;          // máximo aceito pela API
const MAX_PAGES = 10;           // trava de segurança na paginação
const PENDING_RETRY_DAYS = 7;   // por quantos dias re-checar gravação sem conteúdo
const MARGIN_MS = 3 * 24 * 3600 * 1000; // margem de re-verificação após o último sync
const LOCK_STALE_MS = 30 * 60 * 1000;

const VERBOSE = process.argv.includes('--verbose');
const DRY_RUN = process.argv.includes('--dry-run');

const log = (msg) => console.log(`[${new Date().toISOString()}] ${msg}`);
const vlog = (msg) => { if (VERBOSE) log(msg); };

// ------------------------------------------------------------------- tokens

async function loadTokens() {
  try {
    return JSON.parse(await readFile(TOKENS_PATH, 'utf-8'));
  } catch {
    return null;
  }
}

async function refreshTokens(tokenSet) {
  const res = await fetch(REFRESH_URL, {
    method: 'POST',
    headers: { 'Content-Type': 'application/x-www-form-urlencoded', Accept: 'application/json' },
    body: new URLSearchParams({ refresh_token: tokenSet.refresh_token }),
  });
  if (!res.ok) throw new Error(`Falha ao renovar token: HTTP ${res.status} ${await res.text()}`);
  const data = await res.json();
  const next = {
    access_token: data.access_token,
    refresh_token: data.refresh_token ?? tokenSet.refresh_token,
    token_type: data.token_type ?? 'Bearer',
    expires_at: data.expires_in ? Date.now() + data.expires_in * 1000 : undefined,
  };
  // mesmo formato que o Plaud CLI usa, para os dois continuarem compatíveis
  await writeFile(TOKENS_PATH, JSON.stringify(next, null, 2), 'utf-8');
  vlog('Token renovado e salvo.');
  return next;
}

async function getAccessToken(state) {
  if (!state.tokens) state.tokens = await loadTokens();
  if (!state.tokens?.access_token) {
    throw new Error(`Nenhum login encontrado em ${TOKENS_PATH}. Rode: npx -y @plaud-ai/cli login`);
  }
  const t = state.tokens;
  if (t.expires_at && Date.now() > t.expires_at - 60_000) {
    if (!t.refresh_token) throw new Error('Token expirado e sem refresh_token. Rode: npx -y @plaud-ai/cli login');
    state.tokens = await refreshTokens(t);
  }
  return state.tokens.access_token;
}

async function api(state, path) {
  const call = async () => {
    const token = await getAccessToken(state);
    return fetch(`${API_BASE}${path}`, {
      headers: { Authorization: `Bearer ${token}`, Accept: 'application/json' },
    });
  };
  let res = await call();
  if (res.status === 401 && state.tokens?.refresh_token) {
    // access token pode ter sido invalidado antes do expires_at — força renovação
    vlog('HTTP 401 — forçando renovação de token e repetindo.');
    state.tokens = await refreshTokens(state.tokens);
    res = await call();
  }
  if (!res.ok) throw new Error(`API ${path}: HTTP ${res.status} ${res.statusText}`);
  return res.json();
}

// ------------------------------------------------------------------ helpers

function sanitizeFilename(name) {
  return (name || 'Gravação')
    .replace(/[\\/:*?"<>|#^\[\]{}]/g, ' ')
    .replace(/\s+/g, ' ')
    .trim()
    .slice(0, 80) || 'Gravação';
}

function yamlString(s) {
  return `"${String(s ?? '').replace(/\\/g, '\\\\').replace(/"/g, '\\"').replace(/\r?\n/g, ' ')}"`;
}

function pad(n) { return String(n).padStart(2, '0'); }

function localStamp(iso) {
  const d = iso ? new Date(iso) : new Date();
  if (isNaN(d)) return { date: 'sem-data', time: '0000', pretty: iso ?? '-' };
  return {
    date: `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}`,
    time: `${pad(d.getHours())}${pad(d.getMinutes())}`,
    pretty: `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())} ${pad(d.getHours())}:${pad(d.getMinutes())}`,
  };
}

function formatDuration(ms) {
  if (!ms || ms <= 0) return '-';
  const total = Math.round(ms / 1000);
  const h = Math.floor(total / 3600);
  const m = Math.floor((total % 3600) / 60);
  const s = total % 60;
  if (h > 0) return `${h}h ${pad(m)}m`;
  if (m > 0) return `${m}m ${pad(s)}s`;
  return `${s}s`;
}

function formatTime(ms) {
  if (ms == null || isNaN(ms)) return '??:??';
  // start_time/end_time vêm em milissegundos (mesma convenção do Plaud CLI)
  const t = Math.floor(ms / 1000);
  const h = Math.floor(t / 3600);
  const m = Math.floor((t % 3600) / 60);
  const s = t % 60;
  return h > 0 ? `${pad(h)}:${pad(m)}:${pad(s)}` : `${pad(m)}:${pad(s)}`;
}

async function loadBlockContent(block) {
  if (!block) return '';
  if (typeof block.data_content === 'string' && block.data_content.length > 0) return block.data_content;
  if (typeof block.data_link === 'string' && block.data_link.length > 0) {
    const res = await fetch(block.data_link);
    if (!res.ok) throw new Error(`Falha ao baixar conteúdo (data_link): HTTP ${res.status}`);
    return res.text();
  }
  return '';
}

function renderTranscript(rawJson) {
  let segments;
  try {
    segments = JSON.parse(rawJson);
  } catch {
    return rawJson.trim(); // já veio como texto puro
  }
  if (!Array.isArray(segments)) return String(rawJson).trim();
  return segments
    .map((seg) => {
      const time = `\\[${formatTime(seg.start_time)}\\]`;
      const speaker = seg.speaker ? `**${seg.speaker}**` : '';
      const text = seg.content ?? seg.topic ?? '';
      return `${time} ${speaker}${speaker ? ': ' : ''}${text}`.trim();
    })
    .filter(Boolean)
    .join('\n');
}

// ------------------------------------------------------------------- estado

async function loadState(statePath) {
  try {
    const s = JSON.parse(await readFile(statePath, 'utf-8'));
    return { imported: {}, pending: {}, skipped: {}, lastRunAt: 0, ...s };
  } catch {
    return { imported: {}, pending: {}, skipped: {}, lastRunAt: 0 };
  }
}

async function saveState(statePath, state) {
  if (DRY_RUN) return;
  const tmp = `${statePath}.tmp`;
  await writeFile(tmp, JSON.stringify(state, null, 2), 'utf-8');
  await rename(tmp, statePath);
}

/** IDs recuperados dos nomes de arquivo — rede de segurança caso o estado se perca.
 *  O padrão precisa casar com shortIdOf(): alfanumérico minúsculo, não só hex. */
async function idsFromExistingFiles(dir) {
  const ids = new Set();
  try {
    for (const f of await readdir(dir)) {
      const m = f.match(/\(([0-9a-z]{8})\)\.md$/);
      if (m) ids.add(m[1]);
    }
  } catch { /* pasta ainda não existe */ }
  return ids;
}

/** Remove .tmp-* órfãos de execuções que morreram no meio (ocultos no Obsidian, mas lixo). */
async function cleanStaleTmp(dir) {
  try {
    for (const f of await readdir(dir)) {
      if (f.startsWith('.tmp-')) await rm(join(dir, f), { force: true });
    }
  } catch { /* ok */ }
}

// --------------------------------------------------------------------- lock

async function acquireLock() {
  try {
    const st = await stat(LOCK_PATH);
    if (Date.now() - st.mtimeMs < LOCK_STALE_MS) return false;
    vlog('Lock antigo encontrado — assumindo execução travada e prosseguindo.');
  } catch { /* sem lock */ }
  await mkdir(join(homedir(), '.plaud-obsidian-sync'), { recursive: true });
  await writeFile(LOCK_PATH, String(process.pid), 'utf-8');
  return true;
}

async function releaseLock() {
  try { await rm(LOCK_PATH); } catch { /* ok */ }
}

// ------------------------------------------------------------------ nota .md

async function buildNote(file) {
  const noteList = file.note_list ?? [];
  const sourceList = file.source_list ?? [];

  const summaryBlock = noteList.find((n) => n.data_type === 'auto_sum_note');
  const summary = (await loadBlockContent(summaryBlock)).trim();

  const polished = sourceList.find((s) => s.data_type === 'transaction_polish');
  const raw = sourceList.find((s) => s.data_type === 'transaction');
  const transcriptRaw = (await loadBlockContent(polished ?? raw)).trim();
  const transcript = transcriptRaw ? renderTranscript(transcriptRaw) : '';

  if (!summary && !transcript) return null; // ainda processando no Plaud

  // resumo e transcrição podem ficar prontos em momentos diferentes; para a nota
  // não nascer pela metade, espera os dois — mas só nas primeiras 24h da gravação
  const ageMs = Date.now() - (Date.parse(file.start_at ?? file.created_at ?? '') || Date.now());
  if ((!summary || !transcript) && ageMs < 24 * 3600 * 1000) return null;

  const when = localStamp(file.start_at ?? file.created_at);
  const title = file.name || 'Gravação sem título';

  const fm = [
    '---',
    `plaud_id: ${yamlString(file.id)}`,
    `title: ${yamlString(title)}`,
    `data: ${yamlString(when.pretty)}`,
    `duracao: ${yamlString(formatDuration(file.duration))}`,
    `dispositivo: ${yamlString(file.serial_number ?? '-')}`,
    `importado_em: ${yamlString(new Date().toISOString())}`,
    'tags:',
    '  - plaud',
    '---',
  ].join('\n');

  const parts = [fm, '', `# ${title}`, ''];
  if (summary) parts.push('## Resumo (IA)', '', summary, '');
  if (transcript) {
    parts.push('## Transcrição' + (polished ? ' (polida)' : ''), '', transcript, '');
  }
  return parts.join('\n');
}

function noteFilename(file) {
  const when = localStamp(file.start_at ?? file.created_at);
  const shortId = String(file.id).replace(/[^0-9a-zA-Z]/g, '').slice(0, 8).toLowerCase().padEnd(8, '0');
  return `${when.date} ${when.time} - ${sanitizeFilename(file.name)} (${shortId}).md`;
}

function shortIdOf(file) {
  return String(file.id).replace(/[^0-9a-zA-Z]/g, '').slice(0, 8).toLowerCase().padEnd(8, '0');
}

// --------------------------------------------------------------------- main

async function main() {
  // config
  let config;
  try {
    config = JSON.parse(await readFile(CONFIG_PATH, 'utf-8'));
  } catch {
    console.error(`Config não encontrada em ${CONFIG_PATH}. Rode o install.sh primeiro.`);
    process.exit(2);
  }
  const vaultDir = config.vaultDir;
  const subdir = config.subdir ?? 'Plaud';
  const firstRunDays = config.firstRunDays ?? 30;

  // o vault vive no mount do NAS — se o mount caiu, sai em silêncio e tenta na próxima
  if (!existsSync(vaultDir)) {
    log(`Vault indisponível (${vaultDir}) — mount do NAS fora? Tentando na próxima execução.`);
    return;
  }

  if (!(await acquireLock())) {
    vlog('Outra execução em andamento — saindo.');
    return;
  }

  try {
    const targetDir = join(vaultDir, subdir);
    await mkdir(targetDir, { recursive: true });
    await cleanStaleTmp(targetDir);

    const statePath = join(targetDir, '.plaud-sync-state.json');
    const state = await loadState(statePath);
    const onDisk = await idsFromExistingFiles(targetDir);
    const apiState = { tokens: null };

    const now = Date.now();
    const cutoff = state.lastRunAt
      ? Math.min(state.lastRunAt - MARGIN_MS, now)
      : now - firstRunDays * 24 * 3600 * 1000;
    vlog(`Cutoff: ${new Date(cutoff).toISOString()}`);

    // 1. coleta candidatos: páginas até passar do cutoff
    const candidates = new Map();
    for (let page = 1; page <= MAX_PAGES; page++) {
      const result = await api(apiState, `/open/third-party/files/?page=${page}&page_size=${PAGE_SIZE}`);
      const items = result.data ?? [];
      if (items.length === 0) break;
      let anyRecent = false;
      for (const it of items) {
        const ts = Date.parse(it.created_at ?? '') || 0;
        if (ts >= cutoff) anyRecent = true;
        candidates.set(it.id, it);
      }
      if (!anyRecent || items.length < PAGE_SIZE) break;
    }

    // 2. pendentes de execuções anteriores continuam na fila mesmo fora da janela
    for (const id of Object.keys(state.pending)) {
      if (!candidates.has(id)) candidates.set(id, { id });
    }

    // 3. filtra os que ainda precisam de trabalho
    const todo = [];
    for (const [id, item] of candidates) {
      const sid = shortIdOf(item);
      if (state.imported[id] || state.skipped[id] || onDisk.has(sid)) continue;
      const ts = Date.parse(item.created_at ?? '') || now;
      if (ts < cutoff && !state.pending[id]) continue;
      todo.push(item);
    }

    todo.sort((a, b) => (Date.parse(a.created_at ?? '') || 0) - (Date.parse(b.created_at ?? '') || 0));
    log(`Gravações para processar: ${todo.length} (importadas até hoje: ${Object.keys(state.imported).length})`);

    let imported = 0, waiting = 0, failed = 0;
    for (const item of todo) {
      try {
        const file = await api(apiState, `/open/third-party/files/${item.id}`);
        const note = await buildNote(file);
        if (note === null) {
          const firstSeen = state.pending[item.id] ?? now;
          if (now - firstSeen > PENDING_RETRY_DAYS * 24 * 3600 * 1000) {
            state.skipped[item.id] = 'sem transcrição/resumo após período de espera';
            delete state.pending[item.id];
            vlog(`${item.id}: sem conteúdo após ${PENDING_RETRY_DAYS} dias — desistindo.`);
          } else {
            state.pending[item.id] = firstSeen;
            waiting++;
            vlog(`${file.name ?? item.id}: transcrição ainda não pronta — fica pendente.`);
          }
          continue;
        }

        const filename = noteFilename(file);
        const finalPath = join(targetDir, filename);
        if (DRY_RUN) {
          log(`[dry-run] criaria: ${filename}`);
        } else {
          const tmpPath = join(targetDir, `.tmp-${shortIdOf(file)}`);
          await writeFile(tmpPath, note, 'utf-8');
          await rename(tmpPath, finalPath);
        }
        state.imported[item.id] = { file: filename, at: new Date().toISOString() };
        delete state.pending[item.id];
        imported++;
        log(`Importada: ${filename}`);
        await saveState(statePath, state); // estado salvo a cada nota — falha no meio não repete trabalho
      } catch (err) {
        failed++;
        // marca como pendente para a falha ser re-tentada nas próximas execuções,
        // mesmo depois que a gravação sair da janela de paginação
        state.pending[item.id] = state.pending[item.id] ?? now;
        log(`ERRO em ${item.id}: ${err.message}`);
      }
    }

    state.lastRunAt = now;
    await saveState(statePath, state);
    log(`Concluído: ${imported} importadas, ${waiting} aguardando transcrição, ${failed} erros.`);
    if (failed > 0) process.exitCode = 1;
  } finally {
    await releaseLock();
  }
}

main().catch((err) => {
  console.error(`[${new Date().toISOString()}] FATAL: ${err.message}`);
  process.exit(2);
});
