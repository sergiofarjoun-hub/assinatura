// Ingestão do conhecimento de PRODUTO das seguradoras.
//
// Varre PRODUTOS_DIR/<Seguradora>/<subpastas de foco> (BROCHURAS, APOLICES…),
// extrai o texto dos PDFs e pede ao Claude uma FICHA POR SEGURADORA que
// ENUMERA CADA PRODUTO/PLANO separadamente (hospitalar, completo, etc.), com
// cobertura, franquia, área, carências e diferenciais de cada um. As fichas
// ficam em PRODUTOS_KB_DIR e o bot as carrega como base de conhecimento.
//
// Uso (no NAS, reaproveitando a imagem já buildada do agente):
//   sudo docker run --rm --env-file .env \
//     -v "/volume1/SERVER/SEGUROS SAUDE":/produtos:ro \
//     -v "$PWD/data":/app/data \
//     -e PRODUTOS_DIR=/produtos \
//     whatsapp-agent-whatsapp-agent node src/ingest-produtos.js
//
// Re-execução é barata: só reprocessa a seguradora cujos arquivos mudaram
// (manifest com hash). Depois, reinicie o bot para recarregar o conhecimento.
'use strict';

const fs = require('fs');
const path = require('path');
const crypto = require('crypto');
const Anthropic = require('@anthropic-ai/sdk');
const config = require('./config');

const pdfParse = require('pdf-parse');

// Timeout generoso e retries: as destilações são grandes e podem ser lentas.
const client = new Anthropic({ timeout: 600000, maxRetries: 2 });

const MAX_PDF_BYTES = 25 * 1024 * 1024; // ignora PDFs gigantes (provável scan/imagem)
const MAX_FILES_PER_CARRIER = 40;

function norm(s) {
  return (s || '')
    .normalize('NFD')
    .replace(/[̀-ͯ]/g, '')
    .toLowerCase()
    .trim();
}

function slugify(s) {
  return norm(s)
    .replace(/[^a-z0-9]+/g, '-')
    .replace(/^-+|-+$/g, '')
    .slice(0, 60);
}

function subdirs(dir) {
  try {
    return fs
      .readdirSync(dir, { withFileTypes: true })
      .filter((d) => d.isDirectory() && !d.name.startsWith('.') && d.name !== '@eaDir' && d.name !== '#recycle');
  } catch {
    return [];
  }
}

// Versão da destilação. Suba quando mudar o prompt/params: entra no hash e força
// reprocessar as seguradoras já em cache.
const KB_VERSION = '2';

// Acha, dentro da pasta da seguradora, as subpastas de foco (BROCHURAS,
// APOLICES…). Casa por CONTEÚDO do nome (case/acentos-insensível), então
// "2026 Brochuras", "APOLICES", "Apolices 2026" etc. também batem.
function focusPaths(carrierPath) {
  const wanted = config.produtosSubpastas.map(norm).filter(Boolean);
  const out = [];
  for (const d of subdirs(carrierPath)) {
    const n = norm(d.name);
    if (wanted.some((w) => n.includes(w) || w.includes(n))) out.push(path.join(carrierPath, d.name));
  }
  return out;
}

// Lista PDFs (recursivo, raso) dentro de um conjunto de pastas.
function collectPdfs(roots, depth = 3) {
  const out = [];
  const walk = (dir, rel, d) => {
    let entries;
    try {
      entries = fs.readdirSync(dir, { withFileTypes: true });
    } catch {
      return;
    }
    for (const e of entries) {
      if (e.name.startsWith('.') || e.name === '@eaDir' || e.name === '#recycle') continue;
      const full = path.join(dir, e.name);
      const r = rel ? path.join(rel, e.name) : e.name;
      if (e.isDirectory()) {
        if (d > 0) walk(full, r, d - 1);
      } else if (e.isFile() && e.name.toLowerCase().endsWith('.pdf')) {
        try {
          const st = fs.statSync(full);
          out.push({ path: full, rel: r, size: st.size, mtimeMs: st.mtimeMs });
        } catch {
          /* ignora */
        }
      }
    }
  };
  for (const root of roots) walk(root, path.basename(root), depth);
  return out;
}

function carrierHash(pdfs) {
  const h = crypto.createHash('sha256');
  h.update(`v${KB_VERSION}\n`);
  for (const f of pdfs.slice().sort((a, b) => a.rel.localeCompare(b.rel))) {
    h.update(`${f.rel}|${f.size}|${Math.round(f.mtimeMs)}\n`);
  }
  return h.digest('hex');
}

async function extractText(file) {
  if (file.size > MAX_PDF_BYTES) return '';
  try {
    const buf = fs.readFileSync(file.path);
    const data = await pdfParse(buf);
    return (data.text || '').trim();
  } catch (err) {
    console.warn(`  ! falha ao ler ${file.rel}: ${err.message}`);
    return '';
  }
}

// Junta o texto dos PDFs (rotulado pelo nome do arquivo — o nome costuma
// indicar o produto), respeitando o teto de caracteres.
async function buildCorpus(pdfs) {
  const cap = config.produtosMaxChars;
  let total = 0;
  const parts = [];
  for (const f of pdfs.slice(0, MAX_FILES_PER_CARRIER)) {
    const txt = await extractText(f);
    if (!txt) continue;
    const bloco = `\n\n===== ARQUIVO: ${f.rel} =====\n${txt}`;
    if (total + bloco.length > cap) {
      parts.push(bloco.slice(0, Math.max(0, cap - total)));
      total = cap;
      break;
    }
    parts.push(bloco);
    total += bloco.length;
  }
  return parts.join('');
}

const SYSTEM = `Você organiza o conhecimento de PRODUTOS de seguro-saúde internacional (IPMI)
da corretora Hamsa, a partir de brochuras e condições das seguradoras.

Você recebe o texto de vários documentos de UMA seguradora. Produza uma FICHA em
Markdown que ENUMERA CADA PRODUTO/PLANO distinto que a seguradora oferece —
NÃO misture tudo num resumo só. É comum a mesma seguradora ter:
- um produto só HOSPITALAR (internação),
- um produto COMPLETO (ambulatorial + hospitalar),
- planos de substituição/migração (para "remover" um plano antigo),
- variações por área de cobertura, faixa, franquia ou opção.

Para CADA produto/plano identificado, descreva de forma concisa e factual:
- Nome do produto/plano (como aparece nos documentos);
- Tipo (hospitalar / ambulatorial+hospitalar / completo / substituição/migração…);
- O que cobre e o que NÃO cobre (principais coberturas e exclusões);
- Franquia/dedutível e opções, se houver;
- Área de cobertura (mundial, EUA incluído/excluído, Brasil…);
- Carências relevantes;
- Público-alvo e diferenciais.

Regras:
- Baseie-se APENAS no texto fornecido. Não invente valores nem coberturas.
- Se algo não estiver claro nos documentos, escreva "(não especificado nos materiais)".
- Seja objetivo: bullets curtos. Sem preâmbulo, só a ficha em Markdown.
- Comece com um título "# <Seguradora>" e, para cada produto, um subtítulo "## <Produto>".`;

async function distill(carrier, corpus) {
  // Streaming evita o timeout de requisições longas (recomendação da Anthropic).
  const stream = client.messages.stream({
    model: config.model,
    max_tokens: 6000,
    system: SYSTEM,
    messages: [
      {
        role: 'user',
        content:
          `Seguradora: ${carrier}\n\n` +
          'Documentos (texto extraído dos PDFs de brochuras/condições):\n' +
          corpus +
          '\n\nProduza a ficha da seguradora, com um bloco por produto/plano.',
      },
    ],
  });
  const resp = await stream.finalMessage();
  return resp.content
    .filter((b) => b.type === 'text')
    .map((b) => b.text)
    .join('\n')
    .trim();
}

function loadManifest(kbDir) {
  try {
    return JSON.parse(fs.readFileSync(path.join(kbDir, '.manifest.json'), 'utf8'));
  } catch {
    return {};
  }
}

function saveManifest(kbDir, manifest) {
  fs.writeFileSync(path.join(kbDir, '.manifest.json'), JSON.stringify(manifest, null, 2));
}

async function main() {
  const base = config.produtosDir;
  if (!base) {
    console.error('Defina PRODUTOS_DIR (ex.: /produtos) apontando para "SEGUROS SAUDE".');
    process.exit(1);
  }
  if (!fs.existsSync(base)) {
    console.error(`PRODUTOS_DIR não encontrado: ${base}`);
    process.exit(1);
  }
  const kbDir = config.produtosKbDir;
  fs.mkdirSync(kbDir, { recursive: true });
  const manifest = loadManifest(kbDir);

  const filtro = config.produtosCarriers.map(norm);
  let carriers = subdirs(base).map((d) => d.name);
  if (filtro.length) carriers = carriers.filter((c) => filtro.includes(norm(c)));

  console.log(`Seguradoras a processar: ${carriers.length}`);
  let feitas = 0;
  let puladas = 0;

  for (const carrier of carriers) {
    const carrierPath = path.join(base, carrier);
    const roots = focusPaths(carrierPath);
    if (!roots.length) {
      console.log(`- ${carrier}: sem subpasta de foco (${config.produtosSubpastas.join(', ')}) — pulado`);
      continue;
    }
    const pdfs = collectPdfs(roots);
    if (!pdfs.length) {
      console.log(`- ${carrier}: nenhum PDF nas pastas de foco — pulado`);
      continue;
    }

    const slug = slugify(carrier);
    const hash = carrierHash(pdfs);
    const outFile = path.join(kbDir, `${slug}.md`);
    if (manifest[slug] === hash && fs.existsSync(outFile)) {
      console.log(`- ${carrier}: sem mudanças (${pdfs.length} PDFs) — pulado`);
      puladas++;
      continue;
    }

    console.log(`- ${carrier}: ${pdfs.length} PDFs → destilando…`);
    const corpus = await buildCorpus(pdfs);
    if (corpus.trim().length < 200) {
      console.log(`  (pouco texto extraível — provavelmente PDFs escaneados; pulado)`);
      continue;
    }
    try {
      const ficha = await distill(carrier, corpus);
      if (ficha && ficha.length > 50) {
        fs.writeFileSync(outFile, ficha + '\n');
        manifest[slug] = hash;
        saveManifest(kbDir, manifest);
        feitas++;
        console.log(`  ✓ ${outFile}`);
      } else {
        console.log('  (destilação vazia — pulado)');
      }
    } catch (err) {
      console.error(`  ! erro ao destilar ${carrier}: ${err.message}`);
    }
  }

  console.log(`\nConcluído: ${feitas} ficha(s) gerada(s)/atualizada(s), ${puladas} sem mudança.`);
  console.log(`Fichas em: ${kbDir}`);
  console.log('Reinicie o bot para recarregar o conhecimento (docker compose up -d).');
}

main().catch((err) => {
  console.error('Falha na ingestão:', err);
  process.exit(1);
});
