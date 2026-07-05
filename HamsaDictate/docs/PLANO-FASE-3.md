# Plano — Fase 3 (Diferencial Hamsa) do HamsaDictate

> Status: **planejada** (jul/2026). Funde a Fase 3 do [ESBOCO.md](ESBOCO.md) com as descobertas
> da pesquisa sobre o Wispr Flow ([PESQUISA-WISPRFLOW.md](PESQUISA-WISPRFLOW.md)).
> Pré-requisito: MVP + Fase 2 mergeados (PR #11) e validados no Mac.

## O que a pesquisa mudou no plano

A Fase 3 do esboço já previa "pós-processamento opcional com LLM local". A pesquisa confirmou que
**isso é exatamente o produto do Wispr Flow** — um Llama fine-tunado limpando a transcrição — e
trouxe três decisões prontas:

1. **Ollama como servidor, não runtime embutido.** OpenWhispr e FreeFlow convergiram no mesmo
   padrão: falar com um endpoint OpenAI-compatible (`http://localhost:11434/v1/chat/completions`).
   Zero dependência nova no app Swift; o usuário instala o Ollama uma vez (`brew install ollama`).
2. **Limpeza é *enhancement*, nunca gargalo.** Padrão do whisper-local: se o Ollama não estiver
   rodando, ou demorar além do timeout, insere a transcrição crua do WhisperKit. O ditado nunca
   quebra por causa do LLM.
3. **Contexto do app alvo via Accessibility** (padrão `AppContextService.swift` do FreeFlow):
   ler o texto ao redor do cursor e o nome do app frontmost e injetar no prompt de limpeza —
   aproxima a "context-awareness" do Wispr sem fine-tuning. A permissão de Acessibilidade o
   HamsaDictate **já tem** (usa para o ⌘V simulado).

Régua de latência (derivada das metas do Wispr, sem a perna de rede): **< 700 ms** do soltar a
tecla ao texto no cursor para ditados curtos; etapa LLM alvo **< 400 ms** para ~100 tokens.

## Itens

### 1. Pós-processamento com LLM local via Ollama

Novo `Core/TextRefiner.swift`:

- `POST http://localhost:11434/v1/chat/completions` (URLSession, sem SDK), `temperature: 0`,
  `stream: false`.
- Health-check no launch e antes de cada uso (`GET /api/tags`, timeout curto). Ollama fora do ar
  → pill "Limpeza: off" no menu e transcrição crua segue normal.
- Timeout da limpeza: 2 s (configurável). Estourou → usa o texto cru.
- **Modelo padrão: `gemma3:4b`** (o que o local-whisper usa em produção para o mesmo caso);
  alternativas no picker: `llama3.2:3b` e `qwen2.5:3b`. Head-to-head em PT-BR é questão em aberto
  da pesquisa — o picker existe para testarmos com ditados reais.
- Prompt de limpeza **editável nas Settings** (padrão FreeFlow), com default focado em PT-BR:
  pontuação, capitalização, remoção de muletas ("éé", "né", "tipo"), aplicação de autocorreções
  faladas ("aliás", "quer dizer"), números e listas formatados. Nunca responder ao conteúdo,
  nunca adicionar informação — só reescrever.
- Settings ganha seção "Limpeza com IA": on/off (default **off** até validarmos), modelo, prompt,
  timeout. Overlay mostra "Refinando…" após "Transcrevendo…".

### 2. Vocabulário Hamsa

Duas camadas, mesma lista de termos (IPMI, VUMI, SUSEP, GeoBlue, apólice, sinistro, carência,
CPT, multicálculo, resseguro…):

- **No Whisper:** lista injetada como `promptText` da `DecodingOptions` do WhisperKit — melhora a
  grafia já na transcrição.
- **No prompt de limpeza:** "termos do domínio que devem ser preservados/corrigidos para esta
  grafia" — pega o que o Whisper errar.
- Lista editável nas Settings (um termo por linha), persistida em `AppSettings`.

### 3. Contexto do app alvo (padrão FreeFlow)

Novo `Support/AppContextReader.swift`:

- Via AX: `AXUIElementCopyAttributeValue` do elemento focado → `kAXValueAttribute` /
  `kAXSelectedTextRangeAttribute` para capturar ~500 caracteres ao redor do cursor + nome do app
  frontmost (`NSWorkspace.frontmostApplication`).
- Entra no prompt de limpeza como contexto ("o usuário está ditando em Mail, texto próximo: …")
  para grafia de nomes e ajuste de tom.
- Falhou a leitura AX (apps que não expõem) → segue sem contexto, silenciosamente.
- Limitar o contexto injetado para não estourar a régua de latência (questão em aberto: medir).

### 4. Modo "ditar e-mail"

- Quarto preset de comportamento, ativável por atalho alternativo ou toggle no menu: troca o
  prompt de limpeza por um de formatação de e-mail profissional PT-BR (saudação, parágrafos,
  fecho), mantendo o conteúdo ditado.
- Combina com o contexto do item 3 quando o app alvo é Mail/Outlook/Gmail no navegador.

### 5. Engine Parakeet v3 (baixa latência) — opcional, avaliar por último

- Segundo engine selecionável via FluidAudio/sherpa-onnx, como no esboço. A pesquisa confirmou o
  Parakeet V3 como o caminho CPU-friendly (Handy: ~5x tempo real em i5; multilíngue com PT).
- No Apple Silicon com WhisperKit turbo já dentro da régua, só vale se a latência da Fase 3
  (STT + LLM) passar dos 700 ms em ditados típicos. Medir antes de construir.

## Fora do escopo desta fase

- Fine-tuning de modelo (o diferencial real do Wispr) — prompt + vocabulário + contexto chegam
  perto o suficiente; reavaliar depois de uso real.
- Streaming de transcrição parcial durante a fala (o padrão lote atual é o documentado em todos
  os clones verificados).
- Gravador de hotkey arbitrário e descarregar modelo após idle (pendências da Fase 2, entram
  aqui só se sobrar tempo).

## Ordem sugerida de implementação

1. `TextRefiner` + seção Settings (item 1) — destrava tudo.
2. Vocabulário (item 2) — barato, ganho imediato no dia a dia de seguros.
3. Contexto AX (item 3) e modo e-mail (item 4).
4. Medir latência ponta a ponta; só então decidir sobre Parakeet (item 5).

A ressalva de sempre: nada disto compila neste ambiente (Linux, sem Xcode) — validar no Mac com
`xcodegen generate` + ⌘R, com o Ollama rodando (`ollama pull gemma3:4b`).
