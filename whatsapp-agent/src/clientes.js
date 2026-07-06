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
// Subpasta padrão quando o assunto não é identificado.
const SUBFOLDER = process.env.CLIENTES_SUBPASTA || 'CLIENT DOCS';

// Roteamento do documento pela pasta que já existe no cadastro do cliente,
// conforme o tipo de solicitação. Ajuste aqui se seu padrão de pastas mudar.
const SUBPASTA_POR_ASSUNTO = {
  reembolso: '_CLAIMS',
  gop: '_GOP',
  exames: '_CLAIMS',
};

// Escolhe a subpasta destino a partir do assunto. Se existir uma pasta com o
// nome esperado dentro do cliente (mesmo com maiúsc./minúsc. diferentes), usa
// a existente; senão devolve o nome canônico (será criado).
function subfolderFor(clientDir, assunto) {
  const desired = SUBPASTA_POR_ASSUNTO[assunto] || SUBFOLDER;
  try {
    const existing = fs
      .readdirSync(clientDir, { withFileTypes: true })
      .filter((d) => d.isDirectory())
      .map((d) => d.name);
    const hit = existing.find((n) => n.toLowerCase() === desired.toLowerCase());
    if (hit) return hit;
  } catch {
    /* ignora */
  }
  return desired;
}

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
// de <Ramo>/<Operadora>/. NUNCA cria pasta de cliente. Só retorna quando o match
// é ÚNICO e seguro (evita salvar no cliente errado). Se a operadora for
// informada, restringe a busca a ela. Retorna { path, nome, operadora } ou null.
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

  const pick = (c) => ({ path: c.path, nome: c.name, operadora: c.operadora });

  // 1) por número de apólice (mais confiável): match único
  const digits = (apolice || '').replace(/\D/g, '');
  if (digits.length >= 4) {
    const hits = cands.filter((c) => c.name.replace(/\D/g, '').includes(digits));
    if (hits.length === 1) return pick(hits[0]);
  }

  // 2) por nome: exato normalizado (único) tem prioridade
  const nnome = norm(nome);
  if (nnome) {
    const exact = cands.filter((c) => norm(c.name) === nnome);
    if (exact.length === 1) return pick(exact[0]);

    // senão, exige >=2 tokens do nome, todos presentes, resultado único
    const toks = nnome.split(' ').filter(Boolean);
    if (toks.length >= 2) {
      const c2 = cands.filter((c) => {
        const fn = norm(c.name);
        return toks.every((t) => fn.includes(t));
      });
      if (c2.length === 1) return pick(c2[0]);
    }
  }

  return null; // não identificado (0) ou ambíguo (vários)
}

// Pasta de retenção para documentos ainda não identificados/confirmados.
function retentionDir(ref) {
  return path.join(BASE, '_a_identificar', sanitize(ref) || 'sem_referencia');
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

function fileName(attachment) {
  const orig = attachment.filename ? sanitize(path.basename(attachment.filename)) : '';
  const hasExt = orig && path.extname(orig);
  return `${stamp()}_${orig || attachment.kind}${hasExt ? '' : extFor(attachment)}`;
}

// Salva o documento. Só arquiva na pasta do cliente quando ele foi IDENTIFICADO
// (match único) E CONFIRMADO (profile.confirmed). Caso contrário, guarda em
// retenção (_a_identificar/<ref>) — nunca cria pasta de cliente.
// Retorna { path, identified } ou null (recurso desligado / falha).
function saveDocument(profile, attachment, ref) {
  if (!enabled()) return null;

  const p = profile || {};
  const match = p.confirmed ? resolveFolder(p) : null;
  const identified = !!match;
  const destDir = identified
    ? path.join(match.path, subfolderFor(match.path, p.assunto))
    : retentionDir(ref);

  try {
    fs.mkdirSync(destDir, { recursive: true });
    const dest = path.join(destDir, fileName(attachment));
    fs.writeFileSync(dest, Buffer.from(attachment.dataB64, 'base64'));
    return { path: dest, identified };
  } catch (err) {
    console.error('Falha ao salvar documento do cliente:', err.message);
    return null;
  }
}

// Move os documentos retidos (_a_identificar/<ref>) para a pasta do cliente,
// depois que ele é confirmado. Retorna a quantidade movida.
function moveRetained(ref, profile) {
  if (!enabled()) return 0;
  const match = resolveFolder(profile || {});
  if (!match) return 0;

  const rdir = retentionDir(ref);
  let files;
  try {
    files = fs.readdirSync(rdir).filter((f) => !f.startsWith('.'));
  } catch {
    return 0;
  }
  if (!files.length) return 0;

  const dest = path.join(match.path, subfolderFor(match.path, (profile || {}).assunto));
  fs.mkdirSync(dest, { recursive: true });
  let n = 0;
  for (const f of files) {
    const from = path.join(rdir, f);
    const to = path.join(dest, f);
    try {
      fs.renameSync(from, to);
      n++;
    } catch {
      try {
        fs.copyFileSync(from, to);
        fs.unlinkSync(from);
        n++;
      } catch (err) {
        console.error('Falha ao mover documento retido:', err.message);
      }
    }
  }
  try {
    if (fs.readdirSync(rdir).filter((f) => !f.startsWith('.')).length === 0) fs.rmdirSync(rdir);
  } catch {
    /* ignora */
  }
  return n;
}

// ---------- Ficha / memória de longo prazo do cliente ----------
// Arquivo _FICHA.md guardado NA PASTA do cliente (visível junto dos documentos).
// Contém: resumo da relação, log de TODA interação, e o controle de claims
// (valores, franquia por pessoa e familiar, status pendente/processado).
const FICHA_FILE = process.env.FICHA_FILE || '_FICHA.md';

// Caminho do _FICHA.md se — e somente se — o cadastro do cliente for localizado.
function fichaPath(profile) {
  if (!enabled()) return null;
  const match = resolveFolder(profile || {});
  if (!match) return null;
  return path.join(match.path, FICHA_FILE);
}

// Lê a ficha atual do cliente (string vazia se não existir/não localizado).
function readFicha(profile) {
  const fp = fichaPath(profile);
  if (!fp) return '';
  try {
    return fs.readFileSync(fp, 'utf8');
  } catch {
    return '';
  }
}

// Grava/atualiza a ficha na pasta do cliente. Retorna true se gravou.
function writeFicha(profile, content) {
  const fp = fichaPath(profile);
  if (!fp || !content) return false;
  try {
    fs.mkdirSync(path.dirname(fp), { recursive: true });
    fs.writeFileSync(fp, content);
    return true;
  } catch (err) {
    console.error('Falha ao gravar ficha do cliente:', err.message);
    return false;
  }
}

module.exports = {
  enabled,
  resolveFolder,
  saveDocument,
  moveRetained,
  readFicha,
  writeFicha,
  BASE,
};
