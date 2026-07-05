// Localiza a pasta do cliente na rede/HD e salva os documentos recebidos.
//
// Caminho base configurável em CLIENTES_DIR (padrão: /Users/hamsa/server/clientes).
// Se a pasta base não existir, o recurso fica DESLIGADO silenciosamente — o
// agente continua funcionando normalmente (útil no NAS, onde esse caminho não
// existe). Estrutura criada:  <base>/<Nome do Cliente>/reembolsos/<arquivo>
'use strict';

const fs = require('fs');
const path = require('path');

const BASE = process.env.CLIENTES_DIR || '/Users/hamsa/server/clientes';
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

function listFolders() {
  try {
    return fs
      .readdirSync(BASE, { withFileTypes: true })
      .filter((d) => d.isDirectory())
      .map((d) => d.name);
  } catch {
    return [];
  }
}

// Encontra a pasta EXISTENTE do cliente por número de apólice ou nome.
// NUNCA cria pasta de cliente. Só retorna quando o match é ÚNICO e seguro
// (evita salvar no cliente errado). Retorna o caminho absoluto ou null.
function resolveFolder({ nome, apolice }) {
  if (!enabled()) return null;
  const folders = listFolders();

  // 1) por número de apólice (mais confiável): dígitos da apólice contidos no
  //    nome da pasta, e o match tem de ser único.
  const digits = (apolice || '').replace(/\D/g, '');
  if (digits.length >= 4) {
    const hits = folders.filter((f) => f.replace(/\D/g, '').includes(digits));
    if (hits.length === 1) return path.join(BASE, hits[0]);
  }

  // 2) por nome: match normalizado exato (único) tem prioridade.
  const nnome = norm(nome);
  if (nnome) {
    const exact = folders.filter((f) => norm(f) === nnome);
    if (exact.length === 1) return path.join(BASE, exact[0]);

    // senão, exige pelo menos 2 tokens do nome, todos presentes na pasta,
    // e resultado único — reduz muito o risco de casar com o cliente errado.
    const toks = nnome.split(' ').filter(Boolean);
    if (toks.length >= 2) {
      const cand = folders.filter((f) => {
        const fn = norm(f);
        return toks.every((t) => fn.includes(t));
      });
      if (cand.length === 1) return path.join(BASE, cand[0]);
    }
  }

  return null; // não identificado (0 candidatos) ou ambíguo (vários)
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
