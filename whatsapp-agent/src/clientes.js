// Localiza a pasta do cliente na rede/HD e salva os documentos recebidos.
//
// Caminho base configurável em CLIENTES_DIR (padrão: /Users/hamsa/server/clientes).
// Se a pasta base não existir, o recurso fica DESLIGADO silenciosamente — o
// agente continua funcionando normalmente (útil no NAS, onde esse caminho não
// existe). Estrutura criada:  <base>/<Nome do Cliente>/reembolsos/<arquivo>
'use strict';

const fs = require('fs');
const path = require('path');

const BASE = process.env.CLIENTES_DIR || '/Users/hamsa/SERVER/CLIENTES';
const SUBFOLDER = process.env.CLIENTES_SUBPASTA || 'reembolsos';

let warned = false;

function enabled() {
  try {
    return fs.statSync(BASE).isDirectory();
  } catch {
    if (!warned) {
      console.warn(
        `Salvamento de documentos desligado: pasta base não encontrada (${BASE}). ` +
          'Defina CLIENTES_DIR no .env para ativar.'
      );
      warned = true;
    }
    return false;
  }
}

// normaliza para comparar nomes: minúsculas, sem acento, espaços colapsados
function norm(s) {
  return (s || '')
    .normalize('NFD')
    .replace(/[̀-ͯ]/g, '')
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, ' ')
    .trim();
}

// nome seguro para o sistema de arquivos
function sanitize(s) {
  return (s || '')
    .replace(/[\/\\:*?"<>|]+/g, ' ')
    .replace(/\s+/g, ' ')
    .trim()
    .slice(0, 80);
}

function subdirs(dir) {
  try {
    return fs.readdirSync(dir, { withFileTypes: true }).filter((d) => d.isDirectory());
  } catch {
    return [];
  }
}

// Coleta as pastas de CLIENTE. Estrutura esperada (aninhada):
//   BASE / <Ramo: Saúde, Vida...> / <Operadora> / <Cliente>
// Se a estrutura for plana (clientes direto em BASE), usa isso como fallback.
// Cada candidato: { name, operadora, ramo, path }.
function collectClients() {
  const out = [];
  for (const ramo of subdirs(BASE)) {
    const ramoPath = path.join(BASE, ramo.name);
    const ops = subdirs(ramoPath);
    for (const op of ops) {
      const opPath = path.join(ramoPath, op.name);
      for (const cl of subdirs(opPath)) {
        out.push({ name: cl.name, operadora: op.name, ramo: ramo.name, path: path.join(opPath, cl.name) });
      }
    }
  }
  if (out.length === 0) {
    // fallback: estrutura plana (clientes direto na base)
    for (const d of subdirs(BASE)) {
      out.push({ name: d.name, operadora: '', ramo: '', path: path.join(BASE, d.name) });
    }
  }
  return out;
}

// Encontra a pasta EXISTENTE do cliente por número de apólice ou nome, dentro
// de Saúde/<Operadora>/. NUNCA cria pasta de cliente. Só retorna quando o match
// é ÚNICO e seguro (evita salvar no cliente errado). Se a operadora for
// informada, restringe a busca a ela. Retorna o caminho absoluto ou null.
function resolveFolder({ nome, apolice, operadora }) {
  if (!enabled()) return null;
  let cands = collectClients();
  if (!cands.length) return null;

  // restringe pela operadora, se informada e se casar com alguma existente
  const nop = norm(operadora);
  if (nop) {
    const f = cands.filter((c) => {
      const co = norm(c.operadora);
      return co && (co.includes(nop) || nop.includes(co));
    });
    if (f.length) cands = f;
  }

  // 1) por número de apólice (mais confiável): match único
  const digits = (apolice || '').replace(/\D/g, '');
  if (digits.length >= 4) {
    const hits = cands.filter((c) => c.name.replace(/\D/g, '').includes(digits));
    if (hits.length === 1) return hits[0].path;
  }

  // 2) por nome: exato normalizado (único) tem prioridade
  const nnome = norm(nome);
  if (nnome) {
    const exact = cands.filter((c) => norm(c.name) === nnome);
    if (exact.length === 1) return exact[0].path;

    // senão, exige >=2 tokens do nome, todos presentes, resultado único
    const toks = nnome.split(' ').filter(Boolean);
    if (toks.length >= 2) {
      const c2 = cands.filter((c) => {
        const fn = norm(c.name);
        return toks.every((t) => fn.includes(t));
      });
      if (c2.length === 1) return c2[0].path;
    }
  }

  return null; // não identificado (0) ou ambíguo (vários)
}

function extFor(attachment) {
  if (attachment.kind === 'pdf') return '.pdf';
  const map = { 'image/jpeg': '.jpg', 'image/png': '.png', 'image/webp': '.webp', 'image/gif': '.gif' };
  return map[attachment.mediaType] || '.bin';
}

function stamp() {
  const d = new Date();
  const p = (n) => String(n).padStart(2, '0');
  return `${d.getFullYear()}-${p(d.getMonth() + 1)}-${p(d.getDate())}_${p(d.getHours())}${p(
    d.getMinutes()
  )}${p(d.getSeconds())}`;
}

// Salva o documento. Se o cliente for identificado, salva na pasta dele
// (<cliente>/<subpasta>). Se NÃO for identificado, salva numa área de retenção
// (_a_identificar/<ref>) para arquivamento manual — nunca cria pasta de cliente.
// Retorna { path, identified } ou null (recurso desligado / falha).
// attachment: { kind, mediaType, dataB64, filename }; ref: identificador do chat.
function saveDocument(profile, attachment, ref) {
  if (!enabled()) return null;

  const folder = resolveFolder(profile || {});
  const identified = !!folder;
  const destDir = identified
    ? path.join(folder, SUBFOLDER)
    : path.join(BASE, '_a_identificar', sanitize(ref) || 'sem_referencia');

  try {
    fs.mkdirSync(destDir, { recursive: true });
    const orig = attachment.filename ? sanitize(path.basename(attachment.filename)) : '';
    const hasExt = orig && path.extname(orig);
    const name = `${stamp()}_${orig || attachment.kind}${hasExt ? '' : extFor(attachment)}`;
    const dest = path.join(destDir, name);
    fs.writeFileSync(dest, Buffer.from(attachment.dataB64, 'base64'));
    return { path: dest, identified };
  } catch (err) {
    console.error('Falha ao salvar documento do cliente:', err.message);
    return null;
  }
}

module.exports = { enabled, resolveFolder, saveDocument, BASE };
