// Hamsa Agent — agente autônomo estilo Manus, auto-hospedado.
// Loop agêntico manual sobre a Claude API (Messages + tool use):
// bash, editor de arquivos e navegador Chromium executam aqui (no container);
// web_search e web_fetch executam do lado da Anthropic. Eventos são
// transmitidos ao navegador via SSE para a UI de chat + painel de atividade.
//
// Segurança: login por senha (AGENT_PASSWORD), aprovação humana para comandos
// bash sensíveis (APPROVAL_MODE) e confinamento de caminhos ao workspace.

import express from "express";
import Anthropic from "@anthropic-ai/sdk";
import { exec } from "node:child_process";
import { promisify } from "node:util";
import fs from "node:fs";
import path from "node:path";
import crypto from "node:crypto";
import { fileURLToPath } from "node:url";
import { BROWSER_TOOL, runBrowser } from "./browser.js";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const execAsync = promisify(exec);

const PORT = Number(process.env.PORT || 3010);
const MODEL = process.env.MODEL || "claude-opus-4-8";
const MAX_TURNS = Number(process.env.MAX_TURNS || 40);
const BASH_TIMEOUT_MS = Number(process.env.BASH_TIMEOUT_MS || 120_000);
const OUTPUT_LIMIT = 50_000; // caracteres devolvidos ao modelo por resultado de ferramenta
const WORKSPACES_ROOT = path.resolve(process.env.WORKSPACES_ROOT || path.join(__dirname, "workspace"));
const SESSIONS_ROOT = path.resolve(process.env.SESSIONS_ROOT || path.join(__dirname, "sessions"));
const AGENT_PASSWORD = process.env.AGENT_PASSWORD || "";
// "off" = executa tudo | "sensitive" (padrão) = pede aprovação p/ comandos sensíveis | "all" = pede p/ todo bash
const APPROVAL_MODE = process.env.APPROVAL_MODE || "sensitive";
const APPROVAL_TIMEOUT_MS = Number(process.env.APPROVAL_TIMEOUT_MS || 5 * 60_000);

const client = new Anthropic();

const SYSTEM_PROMPT = `Você é o Hamsa Agent, um agente de IA autônomo auto-hospedado da corretora Hamsa.
Você recebe tarefas em linguagem natural e as executa de ponta a ponta usando as ferramentas disponíveis.

Como trabalhar:
- Para tarefas com mais de um passo, comece com um plano curto (3-6 itens) e depois execute-o, sem pedir permissão a cada passo.
- Seu diretório de trabalho é /workspace (todo caminho de arquivo é relativo a ele). Use as ferramentas bash e de edição de arquivos para criar, ler e modificar arquivos ali.
- Use web_search para informação atual e web_fetch para ler páginas simples. Use a ferramenta browser (Chromium real) quando a página exigir JavaScript, cliques, formulários ou inspeção visual (screenshot).
- Comandos bash sensíveis podem exigir aprovação humana; se um comando for negado, explique e proponha alternativa em vez de insistir.
- Entregáveis (relatórios, planilhas, scripts) devem ser salvos como arquivos em /workspace e citados na resposta final.
- Ao terminar, responda com um resumo objetivo: o que foi feito, quais arquivos foram gerados e o que ficou pendente, se algo ficou.
- Responda sempre em português brasileiro, a menos que o usuário use outro idioma.`;

const TOOLS = [
  { type: "bash_20250124", name: "bash" },
  { type: "text_editor_20250728", name: "str_replace_based_edit_tool" },
  { type: "web_search_20260209", name: "web_search", max_uses: 8 },
  { type: "web_fetch_20260209", name: "web_fetch", max_uses: 8 },
  BROWSER_TOOL,
];

// ---------------------------------------------------------------------------
// Sessões: histórico em memória + persistido em SESSIONS_ROOT/<id>.json
// (sobrevive a restart do container; fica FORA do workspace para o agente
// não conseguir editar o próprio histórico via bash)

const sessions = new Map(); // id -> { messages: [], busy: boolean }

function sanitizeId(id) {
  return String(id || "").replace(/[^a-zA-Z0-9_-]/g, "");
}

function sessionFile(id) {
  return path.join(SESSIONS_ROOT, `${id}.json`);
}

function getSession(id) {
  if (!sessions.has(id)) {
    let messages = [];
    try {
      messages = JSON.parse(fs.readFileSync(sessionFile(id), "utf8"));
      if (!Array.isArray(messages)) messages = [];
    } catch {
      /* sessão nova ou arquivo corrompido — começa vazia */
    }
    sessions.set(id, { messages, busy: false });
  }
  return sessions.get(id);
}

function persistSession(id, session) {
  try {
    fs.mkdirSync(SESSIONS_ROOT, { recursive: true });
    fs.writeFileSync(sessionFile(id), JSON.stringify(session.messages));
  } catch (err) {
    console.error(`Falha ao persistir sessão ${id}:`, err.message);
  }
}

function workspaceFor(sessionId) {
  const dir = path.join(WORKSPACES_ROOT, sessionId);
  fs.mkdirSync(dir, { recursive: true });
  return dir;
}

// ---------------------------------------------------------------------------
// Autenticação por senha única -> tokens de sessão em memória.
// Sem AGENT_PASSWORD definido, o app roda aberto (uso restrito à tailnet).

const authTokens = new Set();

function timingSafeEq(a, b) {
  const ha = crypto.createHash("sha256").update(String(a)).digest();
  const hb = crypto.createHash("sha256").update(String(b)).digest();
  return crypto.timingSafeEqual(ha, hb);
}

function requireAuth(req, res, next) {
  if (!AGENT_PASSWORD) return next();
  const token =
    (req.headers.authorization || "").replace(/^Bearer\s+/i, "") || String(req.query.token || "");
  if (token && authTokens.has(token)) return next();
  res.status(401).json({ error: "não autenticado" });
}

// ---------------------------------------------------------------------------
// Aprovação humana para comandos bash sensíveis

const SENSITIVE_PATTERNS = [
  /\brm\b/, // qualquer rm: barato pedir, caro errar
  /\bsudo\b/,
  /\bgit\s+push\b/,
  /\bshutdown\b|\breboot\b|\bpoweroff\b/,
  /\bmkfs\b|\bdd\s+if=/,
  /\bkill(all)?\b/,
  /\bdocker\b|\bsystemctl\b|\bservice\s/,
  /\bcrontab\b/,
  /\bssh\b|\bscp\b|\brsync\b.*:/,
  /\bcurl\b[^|>]*(\s-d\b|\s--data\b|\s-F\b|\s--form\b|\s-X\s*(POST|PUT|DELETE|PATCH))/i,
  /\bwget\b[^|>]*--post/i,
  /\bnpm\s+publish\b|\bpip\s+upload\b/,
  /\bchmod\s+777\b/,
];

function needsApproval(command) {
  if (APPROVAL_MODE === "off") return false;
  if (APPROVAL_MODE === "all") return true;
  return SENSITIVE_PATTERNS.some((re) => re.test(command));
}

const pendingApprovals = new Map(); // approvalId -> resolve(boolean)

function requestApproval(send, command, signal) {
  return new Promise((resolve) => {
    const id = crypto.randomUUID();
    const finish = (approved) => {
      clearTimeout(timer);
      signal.removeEventListener("abort", onAbort);
      pendingApprovals.delete(id);
      send({ type: "approval_resolved", id, approved });
      resolve(approved);
    };
    const timer = setTimeout(() => finish(false), APPROVAL_TIMEOUT_MS);
    const onAbort = () => finish(false);
    signal.addEventListener("abort", onAbort);
    pendingApprovals.set(id, finish);
    send({ type: "approval_request", id, command });
  });
}

// ---------------------------------------------------------------------------
// Execução das ferramentas cliente (bash + editor de arquivos + browser)

// O modelo enxerga /workspace como raiz; confinamos todo caminho ao diretório
// da sessão, rejeitando qualquer tentativa de escapar dele.
function safePath(ws, p) {
  let rel = String(p || "").replace(/^\/?workspace\/?/, "").replace(/^\/+/, "");
  const abs = path.resolve(ws, rel === "" ? "." : rel);
  if (abs !== ws && !abs.startsWith(ws + path.sep)) {
    throw new Error(`Caminho fora do workspace: ${p}`);
  }
  return abs;
}

function truncate(text) {
  if (text.length <= OUTPUT_LIMIT) return text;
  return text.slice(0, OUTPUT_LIMIT) + `\n[... saída truncada em ${OUTPUT_LIMIT} caracteres]`;
}

async function runBash(ws, input) {
  if (input.restart) return { content: "Sessão bash reiniciada." };
  try {
    const { stdout, stderr } = await execAsync(input.command, {
      cwd: ws,
      timeout: BASH_TIMEOUT_MS,
      maxBuffer: 10 * 1024 * 1024,
      env: { ...process.env, HOME: ws },
    });
    return { content: truncate([stdout, stderr].filter(Boolean).join("\n")) || "(sem saída)" };
  } catch (err) {
    const out = [err.stdout, err.stderr, err.killed ? `(interrompido: timeout de ${BASH_TIMEOUT_MS / 1000}s)` : err.message]
      .filter(Boolean)
      .join("\n");
    return { content: truncate(out) || "Falha ao executar o comando.", isError: true };
  }
}

function runTextEditor(ws, input) {
  const abs = safePath(ws, input.path);
  switch (input.command) {
    case "view": {
      const st = fs.statSync(abs);
      if (st.isDirectory()) {
        return { content: fs.readdirSync(abs).join("\n") || "(diretório vazio)" };
      }
      let lines = fs.readFileSync(abs, "utf8").split("\n");
      let start = 1;
      if (Array.isArray(input.view_range)) {
        const [a, b] = input.view_range;
        start = a;
        lines = lines.slice(a - 1, b === -1 ? undefined : b);
      }
      return { content: truncate(lines.map((l, i) => `${i + start}\t${l}`).join("\n")) };
    }
    case "create": {
      fs.mkdirSync(path.dirname(abs), { recursive: true });
      if (fs.existsSync(abs)) fs.copyFileSync(abs, abs + ".bak");
      fs.writeFileSync(abs, input.file_text ?? "");
      return { content: `Arquivo criado: ${path.relative(ws, abs)}` };
    }
    case "str_replace": {
      const text = fs.readFileSync(abs, "utf8");
      const count = text.split(input.old_str).length - 1;
      if (count === 0) return { content: "old_str não encontrado no arquivo.", isError: true };
      if (count > 1) return { content: `old_str aparece ${count} vezes; forneça um trecho único.`, isError: true };
      fs.writeFileSync(abs, text.replace(input.old_str, input.new_str ?? ""));
      return { content: "Substituição feita." };
    }
    case "insert": {
      const lines = fs.readFileSync(abs, "utf8").split("\n");
      lines.splice(input.insert_line, 0, input.insert_text ?? "");
      fs.writeFileSync(abs, lines.join("\n"));
      return { content: `Texto inserido após a linha ${input.insert_line}.` };
    }
    default:
      return { content: `Comando não suportado: ${input.command}`, isError: true };
  }
}

// Retorna { content: string | ContentBlock[], isError?: true }
async function executeTool(ctx, block) {
  const { ws, sessionId, send, signal } = ctx;
  try {
    if (block.name === "bash") {
      const command = String(block.input.command || "");
      if (!block.input.restart && needsApproval(command)) {
        const approved = await requestApproval(send, command, signal);
        if (!approved) {
          return {
            content:
              "O usuário NEGOU a execução deste comando (ou a aprovação expirou). " +
              "Não tente executá-lo de novo; explique o impasse e proponha uma alternativa.",
            isError: true,
          };
        }
      }
      return await runBash(ws, block.input);
    }
    if (block.name === "str_replace_based_edit_tool") return runTextEditor(ws, block.input);
    if (block.name === "browser") return await runBrowser(sessionId, block.input, ws);
    return { content: `Ferramenta desconhecida: ${block.name}`, isError: true };
  } catch (err) {
    return { content: String(err.message || err), isError: true };
  }
}

function summarizeResult(result) {
  if (Array.isArray(result.content)) {
    const textBlock = result.content.find((b) => b.type === "text");
    return textBlock ? textBlock.text.slice(0, 400) : "(conteúdo binário)";
  }
  return String(result.content).slice(0, 400);
}

// ---------------------------------------------------------------------------
// Loop agêntico com streaming via SSE

async function runAgent(sessionId, session, ctx) {
  const { send, signal } = ctx;
  for (let turn = 0; turn < MAX_TURNS; turn++) {
    if (signal.aborted) return;

    const stream = client.messages.stream({
      model: MODEL,
      max_tokens: 64_000,
      system: [{ type: "text", text: SYSTEM_PROMPT, cache_control: { type: "ephemeral" } }],
      thinking: { type: "adaptive", display: "summarized" },
      tools: TOOLS,
      messages: session.messages,
    });

    stream.on("text", (delta) => send({ type: "text", text: delta }));
    stream.on("thinking", (delta) => send({ type: "thinking", text: delta }));

    const msg = await stream.finalMessage();
    session.messages.push({ role: "assistant", content: msg.content });
    persistSession(sessionId, session);

    // Atividade das ferramentas server-side (busca/leitura web) para o painel
    for (const block of msg.content) {
      if (block.type === "server_tool_use") {
        send({ type: "tool_use", name: block.name, input: block.input });
      } else if (block.type === "web_search_tool_result") {
        const n = Array.isArray(block.content) ? block.content.length : 0;
        send({ type: "tool_result", name: "web_search", summary: n ? `${n} resultados` : "erro na busca" });
      } else if (block.type === "web_fetch_tool_result") {
        send({ type: "tool_result", name: "web_fetch", summary: "página lida" });
      }
    }

    if (msg.stop_reason === "pause_turn") continue; // loop server-side pausado; reenviar continua

    if (msg.stop_reason === "refusal") {
      send({ type: "error", message: "O modelo recusou esta solicitação por motivos de segurança." });
      return;
    }

    if (msg.stop_reason !== "tool_use") return; // end_turn / max_tokens: terminou

    const toolUses = msg.content.filter((b) => b.type === "tool_use");
    const results = [];
    for (const tu of toolUses) {
      send({ type: "tool_use", name: tu.name, input: tu.input });
      const result = await executeTool(ctx, tu);
      send({ type: "tool_result", name: tu.name, summary: summarizeResult(result), is_error: !!result.isError });
      results.push({
        type: "tool_result",
        tool_use_id: tu.id,
        content: result.content,
        ...(result.isError ? { is_error: true } : {}),
      });
    }
    // Todos os tool_results vão em UMA única mensagem de usuário
    session.messages.push({ role: "user", content: results });
    persistSession(sessionId, session);
  }
  send({ type: "error", message: `Limite de ${MAX_TURNS} rodadas atingido; a tarefa pode estar incompleta.` });
}

// ---------------------------------------------------------------------------
// HTTP

const app = express();
app.use(express.json({ limit: "2mb" }));
app.use(express.static(path.join(__dirname, "public")));

app.get("/healthz", (_req, res) => res.json({ ok: true, model: MODEL }));

app.get("/api/auth-required", (_req, res) => res.json({ required: !!AGENT_PASSWORD }));

app.post("/api/login", (req, res) => {
  if (!AGENT_PASSWORD) return res.json({ token: null });
  const { password } = req.body || {};
  if (!password || !timingSafeEq(password, AGENT_PASSWORD)) {
    return res.status(401).json({ error: "senha incorreta" });
  }
  const token = crypto.randomBytes(24).toString("hex");
  authTokens.add(token);
  res.json({ token });
});

app.post("/api/approve", requireAuth, (req, res) => {
  const { approvalId, approved } = req.body || {};
  const finish = pendingApprovals.get(approvalId);
  if (!finish) return res.status(404).json({ error: "aprovação não encontrada ou expirada" });
  finish(!!approved);
  res.json({ ok: true });
});

// Histórico simplificado (só os textos) para repopular a UI após reload
app.get("/api/history/:sessionId", requireAuth, (req, res) => {
  const id = sanitizeId(req.params.sessionId);
  if (!id) return res.json({ turns: [] });
  const session = getSession(id);
  const turns = [];
  for (const m of session.messages) {
    if (m.role === "user" && typeof m.content === "string") {
      turns.push({ role: "user", text: m.content });
    } else if (m.role === "assistant" && Array.isArray(m.content)) {
      const text = m.content.filter((b) => b.type === "text").map((b) => b.text).join("");
      if (text) turns.push({ role: "assistant", text });
    }
  }
  res.json({ turns });
});

// Lista arquivos gerados no workspace da sessão
app.get("/api/files/:sessionId", requireAuth, (req, res) => {
  const id = sanitizeId(req.params.sessionId);
  const ws = path.join(WORKSPACES_ROOT, id);
  if (!id || !fs.existsSync(ws)) return res.json({ files: [] });
  const files = [];
  (function walk(dir) {
    for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
      const full = path.join(dir, entry.name);
      if (entry.isDirectory()) walk(full);
      else files.push(path.relative(ws, full));
    }
  })(ws);
  res.json({ files });
});

app.get("/api/files/:sessionId/download", requireAuth, (req, res) => {
  const id = sanitizeId(req.params.sessionId);
  const ws = path.join(WORKSPACES_ROOT, id);
  try {
    res.download(safePath(ws, String(req.query.path || "")));
  } catch {
    res.status(400).json({ error: "caminho inválido" });
  }
});

app.post("/api/chat", requireAuth, async (req, res) => {
  const { sessionId, message } = req.body || {};
  if (!message || typeof message !== "string") {
    return res.status(400).json({ error: "campo 'message' é obrigatório" });
  }
  const id = sanitizeId(sessionId) || crypto.randomUUID().replace(/[^a-zA-Z0-9_-]/g, "");
  const session = getSession(id);
  if (session.busy) return res.status(409).json({ error: "sessão ocupada — aguarde a tarefa atual terminar" });
  session.busy = true;

  res.writeHead(200, {
    "Content-Type": "text/event-stream; charset=utf-8",
    "Cache-Control": "no-cache",
    Connection: "keep-alive",
    "X-Accel-Buffering": "no",
  });
  const send = (event) => res.write(`data: ${JSON.stringify(event)}\n\n`);
  send({ type: "session", sessionId: id });

  const abort = new AbortController();
  req.on("close", () => abort.abort());

  const ctx = { ws: workspaceFor(id), sessionId: id, send, signal: abort.signal };
  session.messages.push({ role: "user", content: message });
  persistSession(id, session);
  try {
    await runAgent(id, session, ctx);
    send({ type: "done" });
  } catch (err) {
    console.error(err);
    send({ type: "error", message: String(err.message || err) });
  } finally {
    session.busy = false;
    persistSession(id, session);
    res.end();
  }
});

app.listen(PORT, () => {
  console.log(`Hamsa Agent em http://localhost:${PORT} (modelo: ${MODEL})`);
  if (!process.env.ANTHROPIC_API_KEY) {
    console.warn("AVISO: ANTHROPIC_API_KEY não definida — as tarefas vão falhar até configurá-la.");
  }
  if (!AGENT_PASSWORD) {
    console.warn("AVISO: AGENT_PASSWORD não definida — o app está SEM login. Use apenas dentro da tailnet.");
  }
});
