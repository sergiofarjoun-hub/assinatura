// Hamsa Agent — agente autônomo estilo Manus, auto-hospedado.
// Loop agêntico manual sobre a Claude API (Messages + tool use):
// bash + editor de arquivos executam aqui (no container); web_search e
// web_fetch executam do lado da Anthropic. Eventos são transmitidos ao
// navegador via SSE para a UI de chat + painel de atividade.

import express from "express";
import Anthropic from "@anthropic-ai/sdk";
import { exec } from "node:child_process";
import { promisify } from "node:util";
import fs from "node:fs";
import path from "node:path";
import crypto from "node:crypto";
import { fileURLToPath } from "node:url";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const execAsync = promisify(exec);

const PORT = Number(process.env.PORT || 3010);
const MODEL = process.env.MODEL || "claude-opus-4-8";
const MAX_TURNS = Number(process.env.MAX_TURNS || 40);
const BASH_TIMEOUT_MS = Number(process.env.BASH_TIMEOUT_MS || 120_000);
const OUTPUT_LIMIT = 50_000; // caracteres devolvidos ao modelo por resultado de ferramenta
const WORKSPACES_ROOT = path.resolve(process.env.WORKSPACES_ROOT || path.join(__dirname, "workspace"));

const client = new Anthropic();

const SYSTEM_PROMPT = `Você é o Hamsa Agent, um agente de IA autônomo auto-hospedado da corretora Hamsa.
Você recebe tarefas em linguagem natural e as executa de ponta a ponta usando as ferramentas disponíveis.

Como trabalhar:
- Para tarefas com mais de um passo, comece com um plano curto (3-6 itens) e depois execute-o, sem pedir permissão a cada passo.
- Seu diretório de trabalho é /workspace (todo caminho de arquivo é relativo a ele). Use as ferramentas bash e de edição de arquivos para criar, ler e modificar arquivos ali.
- Use web_search para informação atual e web_fetch para ler páginas específicas.
- Entregáveis (relatórios, planilhas, scripts) devem ser salvos como arquivos em /workspace e citados na resposta final.
- Ao terminar, responda com um resumo objetivo: o que foi feito, quais arquivos foram gerados e o que ficou pendente, se algo ficou.
- Responda sempre em português brasileiro, a menos que o usuário use outro idioma.`;

const TOOLS = [
  { type: "bash_20250124", name: "bash" },
  { type: "text_editor_20250728", name: "str_replace_based_edit_tool" },
  { type: "web_search_20260209", name: "web_search", max_uses: 8 },
  { type: "web_fetch_20260209", name: "web_fetch", max_uses: 8 },
];

// ---------------------------------------------------------------------------
// Sessões (em memória; o filesystem do workspace persiste por sessão)

const sessions = new Map(); // id -> { messages: [], busy: boolean }

function getSession(id) {
  if (!sessions.has(id)) sessions.set(id, { messages: [], busy: false });
  return sessions.get(id);
}

function workspaceFor(sessionId) {
  const dir = path.join(WORKSPACES_ROOT, sessionId);
  fs.mkdirSync(dir, { recursive: true });
  return dir;
}

// ---------------------------------------------------------------------------
// Execução das ferramentas cliente (bash + editor de arquivos)

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
  if (input.restart) return "Sessão bash reiniciada.";
  try {
    const { stdout, stderr } = await execAsync(input.command, {
      cwd: ws,
      timeout: BASH_TIMEOUT_MS,
      maxBuffer: 10 * 1024 * 1024,
      env: { ...process.env, HOME: ws },
    });
    return truncate([stdout, stderr].filter(Boolean).join("\n")) || "(sem saída)";
  } catch (err) {
    const out = [err.stdout, err.stderr, err.killed ? `(interrompido: timeout de ${BASH_TIMEOUT_MS / 1000}s)` : err.message]
      .filter(Boolean)
      .join("\n");
    return { error: truncate(out) || "Falha ao executar o comando." };
  }
}

function runTextEditor(ws, input) {
  const abs = safePath(ws, input.path);
  switch (input.command) {
    case "view": {
      const st = fs.statSync(abs);
      if (st.isDirectory()) {
        return fs.readdirSync(abs).join("\n") || "(diretório vazio)";
      }
      let lines = fs.readFileSync(abs, "utf8").split("\n");
      let start = 1;
      if (Array.isArray(input.view_range)) {
        const [a, b] = input.view_range;
        start = a;
        lines = lines.slice(a - 1, b === -1 ? undefined : b);
      }
      return truncate(lines.map((l, i) => `${i + start}\t${l}`).join("\n"));
    }
    case "create": {
      fs.mkdirSync(path.dirname(abs), { recursive: true });
      if (fs.existsSync(abs)) fs.copyFileSync(abs, abs + ".bak");
      fs.writeFileSync(abs, input.file_text ?? "");
      return `Arquivo criado: ${path.relative(ws, abs)}`;
    }
    case "str_replace": {
      const text = fs.readFileSync(abs, "utf8");
      const count = text.split(input.old_str).length - 1;
      if (count === 0) return { error: "old_str não encontrado no arquivo." };
      if (count > 1) return { error: `old_str aparece ${count} vezes; forneça um trecho único.` };
      fs.writeFileSync(abs, text.replace(input.old_str, input.new_str ?? ""));
      return "Substituição feita.";
    }
    case "insert": {
      const lines = fs.readFileSync(abs, "utf8").split("\n");
      lines.splice(input.insert_line, 0, input.insert_text ?? "");
      fs.writeFileSync(abs, lines.join("\n"));
      return `Texto inserido após a linha ${input.insert_line}.`;
    }
    default:
      return { error: `Comando não suportado: ${input.command}` };
  }
}

async function executeTool(ws, block) {
  try {
    if (block.name === "bash") return await runBash(ws, block.input);
    if (block.name === "str_replace_based_edit_tool") return runTextEditor(ws, block.input);
    return { error: `Ferramenta desconhecida: ${block.name}` };
  } catch (err) {
    return { error: String(err.message || err) };
  }
}

// ---------------------------------------------------------------------------
// Loop agêntico com streaming via SSE

async function runAgent(session, ws, send, signal) {
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
      const result = await executeTool(ws, tu);
      const isError = typeof result === "object" && result !== null && "error" in result;
      const content = isError ? result.error : result;
      send({ type: "tool_result", name: tu.name, summary: truncate(String(content)).slice(0, 400), is_error: isError });
      results.push({ type: "tool_result", tool_use_id: tu.id, content: String(content), ...(isError ? { is_error: true } : {}) });
    }
    // Todos os tool_results vão em UMA única mensagem de usuário
    session.messages.push({ role: "user", content: results });
  }
  send({ type: "error", message: `Limite de ${MAX_TURNS} rodadas atingido; a tarefa pode estar incompleta.` });
}

// ---------------------------------------------------------------------------
// HTTP

const app = express();
app.use(express.json({ limit: "2mb" }));
app.use(express.static(path.join(__dirname, "public")));

app.get("/healthz", (_req, res) => res.json({ ok: true, model: MODEL }));

// Lista arquivos gerados no workspace da sessão
app.get("/api/files/:sessionId", (req, res) => {
  const id = req.params.sessionId.replace(/[^a-zA-Z0-9_-]/g, "");
  const ws = path.join(WORKSPACES_ROOT, id);
  if (!fs.existsSync(ws)) return res.json({ files: [] });
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

app.get("/api/files/:sessionId/download", (req, res) => {
  const id = req.params.sessionId.replace(/[^a-zA-Z0-9_-]/g, "");
  const ws = path.join(WORKSPACES_ROOT, id);
  try {
    res.download(safePath(ws, String(req.query.path || "")));
  } catch {
    res.status(400).json({ error: "caminho inválido" });
  }
});

app.post("/api/chat", async (req, res) => {
  const { sessionId, message } = req.body || {};
  if (!message || typeof message !== "string") {
    return res.status(400).json({ error: "campo 'message' é obrigatório" });
  }
  const id = (sessionId || crypto.randomUUID()).replace(/[^a-zA-Z0-9_-]/g, "");
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

  const ws = workspaceFor(id);
  session.messages.push({ role: "user", content: message });
  try {
    await runAgent(session, ws, send, abort.signal);
    send({ type: "done" });
  } catch (err) {
    console.error(err);
    send({ type: "error", message: String(err.message || err) });
  } finally {
    session.busy = false;
    res.end();
  }
});

app.listen(PORT, () => {
  console.log(`Hamsa Agent em http://localhost:${PORT} (modelo: ${MODEL})`);
  if (!process.env.ANTHROPIC_API_KEY) {
    console.warn("AVISO: ANTHROPIC_API_KEY não definida — as tarefas vão falhar até configurá-la.");
  }
});
