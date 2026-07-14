# Plano — Fase 3 (Diferencial Hamsa) do HamsaDictate

> Status: **em progresso** (jul/2026). Itens 1–4 implementados; item 5 (Parakeet) só após medir
> latência. Funde a Fase 3 do [ESBOCO.md](ESBOCO.md) com as descobertas da pesquisa sobre o
> Wispr Flow ([PESQUISA-WISPRFLOW.md](PESQUISA-WISPRFLOW.md)).
> Pré-requisito: MVP + Fase 2 mergeados (PR #11) e validados no Mac.
>
> **O que entrou em código:** `Core/TextRefiner.swift` (cliente Ollama), `Support/AppContextReader.swift`
> (contexto via AX), vocabulário no `Core/TranscriptionEngine.swift` (promptTokens do Whisper) e no
> prompt de limpeza, estado `.refining` + etapa `refine()` no `DictationController.swift`, seções
> "Limpeza com IA" e "Vocabulário do domínio" no `SettingsView.swift`, toggle "Ditar como e-mail"
> no `MenuBarView.swift`, e os campos correspondentes em `Models/AppSettings.swift`. Nenhuma
> dependência nova (usa `URLSession`). Nota: o timeout padrão ficou em **8 s** (configurável), não
> 2 s — em CPU 2 s cairia sempre no fallback; medir e ajustar no Mac.

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

✅ Implementado em `Core/TextRefiner.swift`:

- `POST {endpoint}/v1/chat/completions` (URLSession, sem SDK), `temperature: 0`, `stream: false`.
- Health-check `GET /api/tags` (timeout 1,5 s) antes de cada uso e ao abrir as Settings. Ollama
  fora do ar → indicador laranja nas Settings e transcrição crua segue normal.
- Timeout da limpeza: **8 s** por padrão (configurável). Estourou → usa o texto cru. (O plano
  original previa 2 s; em CPU isso cairia sempre no fallback — subimos e deixamos ajustável.)
- **Modelo padrão: `gemma3:4b`**; alternativas no picker: `llama3.2:3b` e `qwen2.5:3b`. Head-to-head
  em PT-BR é questão em aberto da pesquisa — o picker existe para testarmos com ditados reais.
- Prompt de limpeza por estilo (`RefineStyle` em `AppSettings`), default PT-BR: pontuação,
  capitalização, remoção de muletas, autocorreções faladas, números e listas. Nunca responde ao
  conteúdo nem adiciona informação — só reescreve.
- Settings tem a seção "Limpeza com IA": on/off (default **off**), estilo, modelo, endereço do
  Ollama e contexto. Overlay mostra "Refinando…" após "Transcrevendo…".
- _Pendente:_ editor livre do prompt de sistema (hoje é fixo por estilo) e slider de timeout na UI.

### 2. Vocabulário Hamsa ✅

Duas camadas, mesma lista de termos (default: IPMI, VUMI, SUSEP, GeoBlue, Bupa, Cigna, apólice,
sinistro, carência, CPT, resseguro, corretora, prêmio, franquia, coparticipação, multicálculo, Hamsa):

- **No Whisper:** injetada como `promptTokens` da `DecodingOptions` (tokeniza o texto e descarta
  tokens especiais, `usePrefillPrompt = true`) — melhora a grafia já na transcrição.
- **No prompt de limpeza:** "termos do domínio que devem ser preservados/corrigidos para esta
  grafia" — pega o que o Whisper errar.
- Editável na seção "Vocabulário do domínio" das Settings, persistida em `AppSettings`.

### 3. Contexto do app alvo (padrão FreeFlow) ✅

Implementado em `Support/AppContextReader.swift`:

- Via AX: elemento focado do sistema (`AXUIElementCreateSystemWide` → `kAXFocusedUIElementAttribute`
  → `kAXValueAttribute`), capturando os últimos ~500 caracteres + nome do app frontmost
  (`NSWorkspace.frontmostApplication`).
- Entra no prompt de limpeza como contexto (ligável por toggle nas Settings).
- Falhou a leitura AX (apps que não expõem) → segue sem contexto, silenciosamente.
- _Nota:_ captura o valor do campo focado; refinamentos como janela de seleção (`kAXSelectedTextRange`)
  ficam para depois, se necessário.

### 4. Modo "ditar e-mail" ✅

- Estilo alternativo de limpeza (`RefineStyle.email`), alternável pelo toggle "Ditar como e-mail"
  no menu (aparece quando a limpeza está ligada) ou pelo picker de estilo nas Settings: troca o
  prompt por um de formatação de e-mail profissional PT-BR (saudação, parágrafos, fecho), mantendo
  o conteúdo ditado. _Pendente:_ atalho global dedicado (hoje é toggle, não hotkey próprio).
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
