// Ferramenta de navegador real (Chromium headless via playwright-core).
// Uma página por sessão; o browser é compartilhado e iniciado sob demanda.
// Screenshots voltam como bloco de imagem (o modelo "vê" a página) e também
// são salvos no workspace da sessão para download pela UI.

import fs from "node:fs";
import path from "node:path";

const CHROME_CANDIDATES = [
  process.env.CHROME_PATH,
  "/opt/pw-browsers/chromium",
  "/usr/bin/chromium",
  "/usr/bin/chromium-browser",
  "/usr/bin/google-chrome",
].filter(Boolean);

export const BROWSER_TOOL = {
  name: "browser",
  description:
    "Navegador web real (Chromium headless). Use quando web_fetch não basta: páginas que exigem JavaScript, " +
    "cliques, formulários ou inspeção visual. Ações: goto (abre url), text (texto visível da página atual), " +
    "links (lista links da página), click (clica no seletor CSS), fill (preenche seletor CSS com value), " +
    "screenshot (captura a tela — você recebe a imagem). Sempre comece com goto.",
  input_schema: {
    type: "object",
    properties: {
      action: {
        type: "string",
        enum: ["goto", "text", "links", "click", "fill", "screenshot"],
        description: "Ação a executar",
      },
      url: { type: "string", description: "URL para goto" },
      selector: { type: "string", description: "Seletor CSS para click/fill" },
      value: { type: "string", description: "Texto para fill" },
    },
    required: ["action"],
  },
};

let browserPromise = null;
const pages = new Map(); // sessionId -> Page
let shotCounter = 0;

function findChrome() {
  for (const p of CHROME_CANDIDATES) {
    try {
      if (fs.existsSync(p) && fs.statSync(p).isFile()) return p;
    } catch {
      /* candidato inacessível — tenta o próximo */
    }
  }
  return null;
}

async function getBrowser() {
  if (!browserPromise) {
    browserPromise = (async () => {
      const executablePath = findChrome();
      if (!executablePath) {
        throw new Error(
          "Chromium não encontrado neste host (defina CHROME_PATH ou instale o pacote chromium). " +
            "Use web_fetch como alternativa."
        );
      }
      const { chromium } = await import("playwright-core");
      return chromium.launch({
        executablePath,
        headless: true,
        args: ["--no-sandbox", "--disable-dev-shm-usage"],
      });
    })();
    browserPromise.catch(() => {
      browserPromise = null; // permite nova tentativa após falha de launch
    });
  }
  return browserPromise;
}

async function getPage(sessionId) {
  const existing = pages.get(sessionId);
  if (existing && !existing.isClosed()) return existing;
  const browser = await getBrowser();
  const context = await browser.newContext({
    viewport: { width: 1280, height: 800 },
    locale: "pt-BR",
  });
  const page = await context.newPage();
  pages.set(sessionId, page);
  return page;
}

function pageStatus(page) {
  return `[${page.url()}]`;
}

async function visibleText(page, limit = 15_000) {
  const text = await page.innerText("body", { timeout: 10_000 }).catch(() => "");
  const clean = text.replace(/\n{3,}/g, "\n\n").trim();
  return clean.length > limit ? clean.slice(0, limit) + "\n[... texto truncado]" : clean || "(página sem texto visível)";
}

// Retorna { content: string | ContentBlock[], isError?: true }
export async function runBrowser(sessionId, input, workspace) {
  const action = input.action;
  try {
    const page = await getPage(sessionId);
    switch (action) {
      case "goto": {
        if (!input.url) return { content: "Parâmetro url é obrigatório para goto.", isError: true };
        await page.goto(input.url, { waitUntil: "domcontentloaded", timeout: 30_000 });
        const title = await page.title();
        const text = await visibleText(page, 2_000);
        return { content: `Página carregada: "${title}" ${pageStatus(page)}\n\n${text}` };
      }
      case "text":
        return { content: `${pageStatus(page)}\n\n${await visibleText(page)}` };
      case "links": {
        const links = await page.$$eval("a[href]", (as) =>
          as
            .map((a) => ({ text: (a.innerText || "").trim().slice(0, 100), href: a.href }))
            .filter((l) => l.text)
            .slice(0, 80)
        );
        return {
          content:
            `${pageStatus(page)}\n` +
            (links.map((l) => `- ${l.text} -> ${l.href}`).join("\n") || "(nenhum link visível)"),
        };
      }
      case "click": {
        if (!input.selector) return { content: "Parâmetro selector é obrigatório para click.", isError: true };
        await page.click(input.selector, { timeout: 10_000 });
        await page.waitForLoadState("domcontentloaded", { timeout: 10_000 }).catch(() => {});
        return { content: `Clique feito em ${input.selector}. Agora em: "${await page.title()}" ${pageStatus(page)}` };
      }
      case "fill": {
        if (!input.selector) return { content: "Parâmetro selector é obrigatório para fill.", isError: true };
        await page.fill(input.selector, input.value ?? "", { timeout: 10_000 });
        return { content: `Campo ${input.selector} preenchido.` };
      }
      case "screenshot": {
        const buf = await page.screenshot({ type: "jpeg", quality: 60 });
        const dir = path.join(workspace, "screenshots");
        fs.mkdirSync(dir, { recursive: true });
        const file = path.join(dir, `shot-${++shotCounter}.jpg`);
        fs.writeFileSync(file, buf);
        return {
          content: [
            { type: "image", source: { type: "base64", media_type: "image/jpeg", data: buf.toString("base64") } },
            { type: "text", text: `Screenshot de ${pageStatus(page)} (salvo em screenshots/${path.basename(file)})` },
          ],
        };
      }
      default:
        return { content: `Ação desconhecida: ${action}`, isError: true };
    }
  } catch (err) {
    return { content: `Erro no navegador (${action}): ${String(err.message || err)}`, isError: true };
  }
}

export async function closeBrowserSession(sessionId) {
  const page = pages.get(sessionId);
  pages.delete(sessionId);
  if (page && !page.isClosed()) await page.context().close().catch(() => {});
}
