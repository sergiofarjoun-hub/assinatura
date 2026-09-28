// ANÁLISE PERIÓDICA DE APRENDIZADO — roda FORA do bot (docker run / cron).
//
// Lê (1) as fichas _FICHA.md de todos os clientes (histórico de interações),
// (2) o log de eventos data/aprendizado.jsonl (feedback dos clientes e lacunas
// de conhecimento capturados pelo bot) e (3) o FAQ_APRENDIDO.md atual do cofre,
// e produz:
//
//   a) <cofre>/_RELATORIOS/Relatorio <data>.md — relatório para o dono:
//      perguntas mais frequentes, satisfação, lacunas da base de conhecimento
//      e sugestões concretas de melhoria. A pasta _RELATORIOS é PRIVADA
//      (prompts.js ignora nomes iniciados por "_"): o bot NÃO a carrega, então
//      nomes de clientes podem aparecer ali sem vazar para outros atendimentos.
//      O relatório também é enviado por e-mail (se SMTP configurado).
//
//   b) <cofre>/FAQ_APRENDIDO.md — nota do cofre que o bot CARREGA no prompt:
//      perguntas & respostas consolidadas (100% anônimas e fundamentadas) e a
//      lista de lacunas pendentes de confirmação. O dono revisa/edita no
//      Obsidian; o bot recarrega sozinho (poll de 30s). É assim que o bot
//      "aprende": o ciclo captura → análise → curadoria → recarga.
//
// Após gravar com sucesso, o log de eventos é arquivado (aprendizado-<data>
// .jsonl) para a próxima rodada partir do zero.
//
// NO NAS (exemplo, semelhante à ingestão — /clientes ro, cofre e data rw):
//   docker run --rm --env-file .env \
//     -v "/volume1/SERVER/CLIENTES":/clientes:ro \
//     -v "/volume1/SERVER/BASE_CONHECIMENTO":/base_conhecimento \
//     -v "$PWD/data":/app/data \
//     whatsup-agent-whatsapp-agent node src/analyze-fichas.js
'use strict';

require('dotenv').config();

const fs = require('fs');
const path = require('path');
const Anthropic = require('@anthropic-ai/sdk');

const config = require('./config');
const aprendizado = require('./aprendizado');
const mailer = require('./mailer');

const client = new Anthropic({ timeout: 600000, maxRetries: 2 });

// Teto de caracteres das fichas somadas enviadas à análise (as mais recentes
// primeiro). Acima disso, as fichas mais antigas ficam de fora desta rodada.
const MAX_FICHAS_CHARS = parseInt(process.env.ANALISE_MAX_CHARS || '200000', 10);
const FICHA_FILE = process.env.FICHA_FILE || '_FICHA.md';
const FAQ_FILE = 'FAQ_APRENDIDO.md';

function hoje() {
  return new Date().toISOString().slice(0, 10);
}

// Acha todos os _FICHA.md sob a base de clientes (BASE/<Ramo>/<Operadora>/
// <Cliente>/_FICHA.md, com folga de profundidade para estruturas variantes).
function collectFichas(base) {
  const out = [];
  const walk = (dir, depth) => {
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
        if (depth > 0) walk(full, depth - 1);
      } else if (e.isFile() && e.name === FICHA_FILE) {
        let mtime = 0;
        try {
          mtime = fs.statSync(full).mtimeMs;
        } catch {
          /* ignora */
        }
        out.push({ path: full, rel: path.relative(base, full), mtime });
      }
    }
  };
  walk(base, 5);
  // Mais recentes primeiro: se o teto cortar, saem as fichas paradas há mais tempo.
  out.sort((a, b) => b.mtime - a.mtime);
  return out;
}

function fichasCorpus(fichas) {
  const parts = [];
  let total = 0;
  let incluidas = 0;
  for (const f of fichas) {
    let txt;
    try {
      txt = fs.readFileSync(f.path, 'utf8').trim();
    } catch {
      continue;
    }
    if (!txt) continue;
    const bloco = `### FICHA: ${f.rel}\n${txt}`;
    if (total + bloco.length > MAX_FICHAS_CHARS) {
      console.warn(
        `Teto de ${MAX_FICHAS_CHARS} caracteres atingido — ${fichas.length - incluidas} ` +
          'ficha(s) mais antiga(s) ficaram fora desta rodada.'
      );
      break;
    }
    parts.push(bloco);
    total += bloco.length;
    incluidas++;
  }
  return { corpus: parts.join('\n\n----------\n\n'), incluidas };
}

function eventosTexto(eventos) {
  if (!eventos.length) return '(nenhum evento registrado no período)';
  return eventos
    .map(
      (e) =>
        `- [${e.ts}] ${e.tipo.toUpperCase()}: ${e.texto}` +
        (e.cliente ? ` (cliente: ${e.cliente}` + (e.plano ? `, plano: ${e.plano}` : '') + ')' : '')
    )
    .join('\n')
    .slice(0, 40000);
}

async function gerar(system, userText, maxTokens) {
  const response = await client.messages.create({
    model: config.model,
    max_tokens: maxTokens,
    system,
    messages: [{ role: 'user', content: userText }],
  });
  return response.content
    .filter((b) => b.type === 'text')
    .map((b) => b.text)
    .join('\n')
    .trim();
}

async function gerarRelatorio(corpus, eventos, incluidas) {
  const system =
    'Você é o analista de qualidade do assistente de WhatsApp da Hamsa (corretora de ' +
    'seguro-saúde internacional). Recebe as FICHAS dos clientes (histórico de todas as ' +
    'interações do bot) e os EVENTOS de aprendizado do período (feedback dos clientes e ' +
    'lacunas de conhecimento). Produza um RELATÓRIO DE MELHORIA em Markdown, em ' +
    'português, direto e acionável, para o dono da corretora. Estrutura:\n' +
    '# Relatório do assistente — <data>\n' +
    '## Visão geral (volume de clientes atendidos, temas dominantes)\n' +
    '## Perguntas mais frequentes (com contagem aproximada)\n' +
    '## Satisfação (feedback positivo/negativo, temas problemáticos)\n' +
    '## Lacunas da base de conhecimento (perguntas que o bot não soube responder — ' +
    'para cada uma, sugira ONDE documentar: nota nova no Obsidian, ficha de produto, ' +
    'ou ajuste de instrução)\n' +
    '## Pendências operacionais detectadas nas fichas (claims parados, documentos ' +
    'faltantes, follow-ups prometidos e não registrados como feitos)\n' +
    '## Sugestões de melhoria (3 a 7 ações concretas, priorizadas)\n' +
    'Baseie TUDO no material recebido — não invente números nem casos.';
  const userText =
    `Data de hoje: ${hoje()}. Fichas incluídas nesta análise: ${incluidas}.\n\n` +
    `=== EVENTOS DO PERÍODO (feedback e lacunas) ===\n${eventos}\n\n` +
    `=== FICHAS DOS CLIENTES ===\n${corpus || '(nenhuma ficha encontrada)'}`;
  return gerar(system, userText, 4000);
}

async function gerarFaq(faqAtual, eventos, relatorio) {
  const system =
    'Você mantém o arquivo FAQ_APRENDIDO.md do cofre de conhecimento da Hamsa ' +
    '(corretora de seguro-saúde internacional). Esse arquivo é CARREGADO NO PROMPT do ' +
    'assistente de WhatsApp que atende TODOS os clientes — portanto:\n' +
    '- ANONIMATO TOTAL: NUNCA inclua nome de cliente, número de WhatsApp, número de ' +
    'apólice ou qualquer dado pessoal. Só conhecimento geral e por produto.\n' +
    '- NADA DE ESPECULAÇÃO: só registre uma RESPOSTA quando ela estiver fundamentada ' +
    'no material recebido (resposta que o bot já deu com base na base de conhecimento, ' +
    'ou correção explícita do dono). Cobertura de procedimento SÓ com fonte explícita.\n' +
    '- PRESERVE o conteúdo existente do arquivo: o dono edita esse arquivo à mão no ' +
    'Obsidian e a curadoria dele MANDA. Não remova nem reescreva entradas existentes; ' +
    'apenas acrescente novas e, se necessário, corrija erro evidente.\n' +
    '- Perguntas SEM resposta confirmada vão para a seção "Lacunas a confirmar", cada ' +
    'uma como item "- [ ] <pergunta> — PENDENTE: aguardando confirmação do Concierge". ' +
    'O bot NÃO deve responder essas até o dono preencher; deixe isso dito no topo da seção.\n' +
    'Estrutura do arquivo:\n' +
    '# FAQ aprendido (curadoria: Hamsa)\n' +
    '> Nota do cofre mantida pelo ciclo de aprendizado do bot. Revise e edite à vontade —\n' +
    '> o assistente recarrega sozinho. Novas entradas da análise ficam marcadas com (novo).\n' +
    '## Perguntas e respostas confirmadas\n' +
    '## Lacunas a confirmar\n' +
    'Responda SOMENTE com o Markdown completo do arquivo atualizado, nada fora dele.';
  const userText =
    `Data: ${hoje()}.\n\n=== FAQ_APRENDIDO.md ATUAL ===\n` +
    (faqAtual || '(arquivo ainda não existe — crie a partir da estrutura)') +
    `\n\n=== EVENTOS DO PERÍODO ===\n${eventos}` +
    `\n\n=== RELATÓRIO DA ANÁLISE (contexto) ===\n${relatorio}`;
  return gerar(system, userText, 4000);
}

async function main() {
  if (!process.env.ANTHROPIC_API_KEY) {
    console.error('ERRO: defina ANTHROPIC_API_KEY no ambiente (.env)');
    process.exit(1);
  }
  const kbDir = config.produtosKbDir;
  try {
    fs.accessSync(kbDir, fs.constants.W_OK);
  } catch {
    console.error(
      `ERRO: cofre de conhecimento não gravável em ${kbDir}. Monte a pasta SEM :ro ` +
        '(a análise grava o relatório e o FAQ_APRENDIDO.md lá).'
    );
    process.exit(1);
  }

  const base = process.env.CLIENTES_DIR || '/clientes';
  const fichas = collectFichas(base);
  const eventos = aprendizado.readAll();
  console.log(
    `Análise de aprendizado: ${fichas.length} ficha(s) em ${base}, ` +
      `${eventos.length} evento(s) em ${aprendizado.FILE}.`
  );
  if (!fichas.length && !eventos.length) {
    console.log('Nada a analisar ainda — nenhum insumo encontrado. Saindo.');
    return;
  }

  const { corpus, incluidas } = fichasCorpus(fichas);
  const evTexto = eventosTexto(eventos);

  console.log('Gerando relatório de melhoria...');
  const relatorio = await gerarRelatorio(corpus, evTexto, incluidas);
  const relDir = path.join(kbDir, '_RELATORIOS');
  fs.mkdirSync(relDir, { recursive: true });
  const relFile = path.join(relDir, `Relatorio ${hoje()}.md`);
  fs.writeFileSync(relFile, relatorio + '\n');
  console.log(`Relatório gravado: ${relFile}`);

  console.log('Atualizando FAQ_APRENDIDO.md...');
  let faqAtual = '';
  const faqFile = path.join(kbDir, FAQ_FILE);
  try {
    faqAtual = fs.readFileSync(faqFile, 'utf8');
  } catch {
    /* primeira rodada */
  }
  const faq = await gerarFaq(faqAtual, evTexto, relatorio);
  if (faq) {
    fs.writeFileSync(faqFile, faq + '\n');
    console.log(`FAQ gravado: ${faqFile} (o bot recarrega sozinho em até 30s)`);
  }

  if (mailer.enabled()) {
    const ok = await mailer.sendMail(`[Hamsa Bot] Relatório de melhoria — ${hoje()}`, relatorio);
    console.log(ok ? 'Relatório enviado por e-mail.' : 'Falha ao enviar o relatório por e-mail.');
  }

  if (eventos.length && aprendizado.archive()) {
    console.log('Log de eventos arquivado — a próxima análise parte do zero.');
  }
  console.log('Análise concluída.');
}

main().catch((err) => {
  console.error('Falha na análise de aprendizado:', err);
  process.exit(1);
});
