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
const MAX_FILES_PER_CARRIER = 150; // brochuras de todos os produtos + condições
const PER_FILE_CHARS = 8000; // teto por arquivo (uma condição longa não domina tudo)
const CHUNK_CHARS = 100000; // acima disso, quebra em partes e consolida

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
const KB_VERSION = '3';

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

// Lista PDFs (recursivo, raso) dentro de um conjunto de pastas. Marca os que
// vêm de uma pasta de BROCHURAS (catálogo de produtos — prioridade na leitura).
function collectPdfs(roots, depth = 3) {
  const out = [];
  const walk = (dir, rel, d, isBro) => {
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
        if (d > 0) walk(full, r, d - 1, isBro);
      } else if (e.isFile() && e.name.toLowerCase().endsWith('.pdf')) {
        try {
          const st = fs.statSync(full);
          out.push({ path: full, rel: r, size: st.size, mtimeMs: st.mtimeMs, brochura: isBro });
        } catch {
          /* ignora */
        }
      }
    }
  };
  for (const root of roots) {
    const isBro = norm(path.basename(root)).includes('brochura');
    walk(root, path.basename(root), depth, isBro);
  }
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

// Junta o texto dos PDFs num corpus. Brochuras primeiro (catálogo de produtos),
// depois condições. Cada arquivo entra com teto (PER_FILE_CHARS) para uma
// condição longa não engolir o orçamento e sufocar os demais produtos.
async function buildCorpus(pdfs) {
  const ordered = pdfs
    .slice()
    .sort((a, b) => (b.brochura ? 1 : 0) - (a.brochura ? 1 : 0) || a.rel.localeCompare(b.rel))
    .slice(0, MAX_FILES_PER_CARRIER);
  const cap = config.produtosMaxChars;
  let total = 0;
  const parts = [];
  for (const f of ordered) {
    const txt = await extractText(f);
    if (!txt) continue;
    const bloco = `\n\n===== ARQUIVO: ${f.rel} =====\n${txt.slice(0, PER_FILE_CHARS)}`;
    if (total + bloco.length > cap) break;
    parts.push(bloco);
    total += bloco.length;
  }
  return parts.join('');
}

const REGRAS_PRODUTO = `Regras cruciais:
- A mesma seguradora costuma ter VÁRIOS produtos distintos (ex.: Universal/VIP,
  Special, Direct, Senior, Absolute, planos só hospitalares, planos de migração).
  ENUMERE CADA UM separadamente — nunca funda tudo num resumo só.
- Cada produto é DIFERENTE: o que é COBERTO em um pode ser EXCLUÍDO em outro.
  Nunca assuma que um benefício de um produto vale para os demais. Descreva a
  cobertura E as exclusões DE CADA produto de forma independente e explícita;
  quando um benefício existir num produto e não noutro, deixe isso claro.
- Baseie-se APENAS no texto fornecido. Não invente valores nem coberturas. Se
  algo não estiver claro, escreva "(não especificado nos materiais)".`;

const SYSTEM_FICHA = `Você organiza o conhecimento de PRODUTOS de seguro-saúde internacional (IPMI)
da corretora Hamsa, a partir de brochuras e condições das seguradoras.

Produza uma FICHA em Markdown que enumera CADA produto/plano da seguradora, com
um subtítulo "## <Produto>" para cada. Para cada produto descreva, de forma
concisa e factual: tipo (hospitalar / completo / etc.), o que cobre, o que NÃO
cobre (exclusões), franquia/dedutível e opções, área de cobertura, carências,
público-alvo e diferenciais.

${REGRAS_PRODUTO}

Comece com "# <Seguradora>". Sem preâmbulo, só a ficha em Markdown. Bullets curtos.`;

const SYSTEM_EXTRACT = `Você extrai PRODUTOS de seguro-saúde de um TRECHO dos materiais de uma
seguradora (o trecho é parcial — não se preocupe com completude).

Liste cada produto/plano distinto que aparecer no trecho, um bloco "## <Produto>"
por produto, com os fatos presentes: tipo, coberturas, exclusões, franquia/opções,
área, carências, diferenciais. Se o trecho não trouxer produto claro, responda só
"(sem produto neste trecho)".

${REGRAS_PRODUTO}

Sem preâmbulo, só os blocos em Markdown.`;

const SYSTEM_MERGE = `Você consolida notas parciais sobre os PRODUTOS de UMA seguradora (extraídas de
vários trechos) numa FICHA final única em Markdown.

Junte as notas do MESMO produto, elimine repetição e produza um bloco
"## <Produto>" por produto distinto, com tipo, coberturas, exclusões,
franquia/opções, área, carências, diferenciais.

${REGRAS_PRODUTO}

Comece com "# <Seguradora>". Sem preâmbulo, só a ficha final em Markdown.`;

async function callClaude(system, userText, maxTokens = 6000) {
  // Streaming evita timeout em requisições longas (recomendação da Anthropic).
  const stream = client.messages.stream({
    model: config.model,
    max_tokens: maxTokens,
    system,
    messages: [{ role: 'user', content: userText }],
  });
  const resp = await stream.finalMessage();
  return resp.content
    .filter((b) => b.type === 'text')
    .map((b) => b.text)
    .join('\n')
    .trim();
}

// Destila a seguradora inteira. Se o corpus couber num pedido, faz numa chamada;
// se for grande, extrai produtos por parte e consolida (para não perder produtos).
async function distillCarrier(carrier, corpus) {
  if (corpus.length <= CHUNK_CHARS) {
    return callClaude(
      SYSTEM_FICHA,
      `Seguradora: ${carrier}\n\nDocumentos:\n${corpus}\n\nProduza a ficha, um bloco por produto.`
    );
  }
  // Quebra em partes e extrai produtos de cada uma
  const chunks = [];
  for (let i = 0; i < corpus.length; i += CHUNK_CHARS) chunks.push(corpus.slice(i, i + CHUNK_CHARS));
  console.log(`    (material grande: ${chunks.length} partes → extrair + consolidar)`);
  const partials = [];
  for (let i = 0; i < chunks.length; i++) {
    const p = await callClaude(
      SYSTEM_EXTRACT,
      `Seguradora: ${carrier} — trecho ${i + 1}/${chunks.length}\n\n${chunks[i]}`
    );
    if (p && !/^\(sem produto/i.test(p)) partials.push(p);
  }
  if (!partials.length) return null;
  return callClaude(
    SYSTEM_MERGE,
    `Seguradora: ${carrier}\n\nNotas parciais dos produtos:\n\n${partials.join('\n\n=====\n\n')}`
  );
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
    // uma pasta por seguradora no cofre; nome de arquivo descritivo
    const outFile = path.join(kbDir, carrier, 'Brochuras e Apólices.md');
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
      const ficha = await distillCarrier(carrier, corpus);
      if (ficha && ficha.length > 50) {
        fs.mkdirSync(path.dirname(outFile), { recursive: true });
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
