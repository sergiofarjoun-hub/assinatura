// Ingestão do conhecimento de PRODUTO a partir do Multi Apólices (MA).
//
// O MA guarda a comparação de cobertura como um array JS no index.html, com
// registros { company, plan, category, item, value } — um por item de cobertura,
// por plano, por seguradora. Esta é a fonte estruturada e curada (melhor que
// destilar PDF). O extrator lê esse array e gera uma ficha por seguradora
// (agrupada por plano e categoria) que o bot carrega como conhecimento.
//
// Uso (no NAS):
//   # 1. despeje o index.html vivo do MA para a pasta de dados do agente:
//   sudo docker exec multi-apolices cat /app/index.html > data/ma-index.html
//   # 2. extraia:
//   sudo docker run --rm --env-file .env -v "$PWD/data":/app/data \
//     -e MA_HTML=/app/data/ma-index.html \
//     whatsapp-agent-whatsapp-agent node src/ingest-ma.js
//   # 3. reinicie o bot: sudo docker compose up -d
'use strict';

const fs = require('fs');
const path = require('path');
const config = require('./config');

const HTML = process.env.MA_HTML || process.argv[2] || path.join('data', 'ma-index.html');
const KB_DIR = config.produtosKbDir;

// Captura os registros { company, plan, category, item, value } (ordem fixa no
// MA). Tolerante a aspas escapadas dentro dos valores.
const STR = '"((?:[^"\\\\]|\\\\.)*)"';
const REC = new RegExp(
  `\\{\\s*company:\\s*${STR}\\s*,\\s*plan:\\s*${STR}\\s*,\\s*category:\\s*${STR}\\s*,\\s*item:\\s*${STR}\\s*,\\s*value:\\s*${STR}\\s*\\}`,
  'g'
);

function unescape(s) {
  return (s || '').replace(/\\(["\\/])/g, '$1').replace(/\\n/g, ' ').trim();
}

function extractRecords(html) {
  const out = [];
  let m;
  while ((m = REC.exec(html))) {
    out.push({
      company: unescape(m[1]),
      plan: unescape(m[2]),
      category: unescape(m[3]),
      item: unescape(m[4]),
      value: unescape(m[5]),
    });
  }
  return out;
}

function slugify(s) {
  return (s || '')
    .normalize('NFD')
    .replace(/[̀-ͯ]/g, '')
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, '-')
    .replace(/^-+|-+$/g, '')
    .slice(0, 60);
}

// Monta o markdown de UMA seguradora: agrupa por plano e, dentro, por categoria.
function buildCompanyMd(company, recs) {
  const plans = new Map(); // plan -> Map(category -> [{item,value}])
  for (const r of recs) {
    if (!plans.has(r.plan)) plans.set(r.plan, new Map());
    const cats = plans.get(r.plan);
    if (!cats.has(r.category)) cats.set(r.category, []);
    cats.get(r.category).push({ item: r.item, value: r.value });
  }
  const lines = [`# ${company}`, ''];
  lines.push(
    `> Fonte: Multi Apólices (comparativo de cobertura da Hamsa). ${plans.size} ` +
      `plano(s). Cada plano é distinto — a cobertura de um item pode diferir entre planos.`,
    ''
  );
  for (const [plan, cats] of plans) {
    lines.push(`## ${plan}`);
    for (const [cat, items] of cats) {
      lines.push(`### ${cat}`);
      for (const it of items) lines.push(`- ${it.item}: ${it.value}`);
      lines.push('');
    }
  }
  return lines.join('\n').trim() + '\n';
}

function main() {
  if (!fs.existsSync(HTML)) {
    console.error(`Arquivo do MA não encontrado: ${HTML}`);
    console.error('Gere com: sudo docker exec multi-apolices cat /app/index.html > data/ma-index.html');
    process.exit(1);
  }
  const html = fs.readFileSync(HTML, 'utf8');
  const recs = extractRecords(html);
  if (!recs.length) {
    console.error('Nenhum registro { company, plan, category, item, value } encontrado no HTML.');
    console.error('Confira se o arquivo é o index.html do Multi Apólices (com o array de dados).');
    process.exit(1);
  }

  const byCompany = new Map();
  for (const r of recs) {
    if (!byCompany.has(r.company)) byCompany.set(r.company, []);
    byCompany.get(r.company).push(r);
  }

  fs.mkdirSync(KB_DIR, { recursive: true });
  let n = 0;
  for (const [company, list] of byCompany) {
    const md = buildCompanyMd(company, list);
    // uma pasta por seguradora no cofre; a ficha do MA convive com a de PDF
    // ("Brochuras e Apólices.md") e com as suas notas ("Notas Hamsa.md").
    const compDir = path.join(KB_DIR, company.replace(/[\/\\:]+/g, '-').trim());
    fs.mkdirSync(compDir, { recursive: true });
    const file = path.join(compDir, 'Cobertura (MA).md');
    fs.writeFileSync(file, md);
    const planos = new Set(list.map((r) => r.plan)).size;
    console.log(`✓ ${company}: ${list.length} itens, ${planos} plano(s) → ${file}`);
    n++;
  }
  console.log(
    `\n${recs.length} itens de cobertura, ${n} seguradora(s) em ${KB_DIR}.\n` +
      'Reinicie o bot para carregar (docker compose up -d).'
  );
}

main();
