# Pesquisa — Como o Wispr Flow funciona (e o que isso muda no HamsaDictate)

> Deep research executada em jul/2026: 5 ângulos de busca em paralelo, 22 fontes lidas,
> 75 alegações extraídas, 25 verificadas adversarialmente (3 votos cada) — **25 confirmadas, 0 refutadas**.
> Este documento consolida as descobertas e as cruza com o que já foi construído no HamsaDictate
> ([ESBOCO.md](ESBOCO.md), [PLANO-FASE-2.md](PLANO-FASE-2.md)).

---

## 1. Como o Wispr Flow realmente funciona

### 1.1 É um produto de nuvem, não local (confiança alta, 3-0)

Todo o pipeline do Wispr Flow — reconhecimento de fala **e** limpeza do texto — roda na
infraestrutura da Baseten (AWS), não no dispositivo. O app exige internet e não tem modo offline.

- Fonte primária (Baseten é o provedor de inferência real do Wispr):
  ["Wispr Flow's entire pipeline, from speech recognition models to Llama-based transcript
  enhancement, runs end-to-end in under 700 milliseconds on Baseten"](https://www.baseten.co/resources/customers/wispr-flow/)
- Corroborado pelos [docs oficiais do Wispr](https://docs.wisprflow.ai): transcrição sempre na nuvem.

**Implicação para o HamsaDictate:** um clone 100% local diverge da arquitetura real do produto —
e isso é uma *vantagem* (privacidade, sem assinatura, sem internet), não uma limitação. O
HamsaDictate já supera o Wispr Flow nesse eixo desde o MVP.

### 1.2 Pipeline de dois estágios: STT → LLM de limpeza (confiança alta, 3-0)

O "segredo" do Wispr Flow é simples: transcrição, seguida de um **Llama fine-tunado** que
estrutura, pontua, remove muletas e formata o texto como o usuário teria digitado —
contextualizado por app e por preferências do usuário.

Metas de latência do produto (números do vendor, não benchmark independente):

| Etapa | Alvo |
|---|---|
| Pipeline completo (p99) | < 700 ms |
| Etapa Llama (100+ tokens) | < 250 ms (TensorRT-LLM + Baseten Chains) |
| Orçamento fino | ~200 ms ASR + ~200 ms LLM + ~200 ms rede |

**Implicações:**
1. A escolha do Llama (família open-weight) pelo próprio Wispr **valida** que um modelo aberto
   servido pelo Ollama dá conta da etapa de limpeza — é literalmente o que eles usam, fine-tunado.
2. O orçamento de ~200 ms por etapa é a régua de "sensação de ditado". Local, sem a etapa de rede,
   temos ~400 ms de folga a mais.
3. A arquitetura do ESBOCO.md (WhisperKit → pós-processamento) já era o desenho certo; a Fase 3
   só precisa ligar o segundo estágio.

### 1.3 Ollama NÃO faz speech-to-text

Ponto verificado que a pergunta original misturava: o Ollama serve apenas LLMs de texto — não
expõe endpoint de transcrição de áudio. O STT tem que vir de whisper.cpp / faster-whisper /
WhisperKit / sherpa-onnx. **O HamsaDictate já resolve isso com WhisperKit (Neural Engine),
que é a opção mais forte no Mac.** Ollama entra só na perna de limpeza do texto.

---

## 2. O ecossistema de clones open source (o que dá para aprender/copiar)

Sete projetos ativos em 2026 já implementam o loop completo (hotkey global → gravar → STT local →
limpeza opcional via LLM → injeção no app ativo). Confirmados 3-0, exceto onde indicado:

| Projeto | Stack | O que interessa ao HamsaDictate |
|---|---|---|
| [Handy](https://github.com/cjpais/Handy) (25,7k ⭐, MIT, Rust/Tauri) | Whisper GPU ou **Parakeet V3 via sherpa-onnx** (CPU, ~5x tempo real), Silero VAD | Referência de VAD e do engine Parakeet que o ESBOCO já listava para a Fase 3 |
| [OpenWhispr](https://github.com/OpenWhispr/openwhispr) (4,3k ⭐, MIT) | whisper.cpp + llama.cpp embutido; aceita **Ollama como endpoint OpenAI-compatible** | Padrão de integração: apontar para `http://localhost:11434/v1` em vez de embutir runtime |
| [FreeFlow](https://github.com/zachlatta/freeflow) (2,1k ⭐, **macOS/Swift**) | Hotkey → STT → limpeza LLM (Ollama/LM Studio/OpenAI-compatible) → paste | **O mais próximo do HamsaDictate.** Destaque: `AppContextService.swift` lê o texto ao redor do cursor via Accessibility API e injeta no prompt de limpeza (nomes e termos saem grafados certo) + prompt de limpeza editável nas Settings |
| [WhisperWriter](https://github.com/savbell/whisper-writer) (~1,1k ⭐, Python) | faster-whisper, 4 modos de gravação | Referência de modos de gravação (já cobertos na Fase 2) |
| [local-whisper](https://github.com/luisalima/local-whisper) (macOS) | whisper.cpp + **Ollama `gemma3:4b`**, prompt customizável em `~/.local-whisper/refine_prompt` | Prova do stack exato: pontuação, remoção de muletas e listas formatadas 100% on-device |
| [whisper-local](https://github.com/drajb/whisper-local) (Win/mac) | faster-whisper + Ollama opt-in | Padrão de *fallback*: limpeza é opcional, transcrição crua nunca é bloqueada pelo LLM |
| [LinuxWhispr](https://github.com/ferrarimb/linux-whispr) (2-1, 6 ⭐) | faster-whisper + wtype/xdotool/ydotool | Só referência de padrão Linux; não é dependência madura |

**Leitura estratégica:** a decisão do ESBOCO ("fork > from scratch, salvo controle do pipeline +
vocabulário de seguros + features Hamsa") continua certa — e como o MVP + Fase 2 já estão
implementados, o valor desses repositórios agora é **minerar padrões** (especialmente o
`AppContextService` do FreeFlow e o prompt do local-whisper), não fazer fork.

---

## 3. Ressalvas da pesquisa

1. Os números de latência do Wispr vêm de case study do vendor (Baseten) — metas de marketing,
   não benchmark independente.
2. **Gap de qualidade:** o Wispr fine-tuna o Llama com contexto do usuário e roda em TensorRT-LLM.
   Um modelo de prateleira no Ollama com bom prompt *aproxima*, mas não iguala, a qualidade de
   limpeza nem os < 250 ms — em Apple Silicon com modelo 1B–4B chega perto; em CPU pura, não.
3. local-whisper (26 ⭐), whisper-local (5 ⭐) e LinuxWhispr (6 ⭐) são pequenos/vibe-coded — boas
   referências de padrão, fracos como base de fork. Os maduros são Handy, OpenWhispr e FreeFlow.
4. Snapshot de jul/2026 — esse espaço anda rápido (Parakeet v3 é de ago/2025).

## 4. Questões em aberto (a validar na prática)

1. Qual modelo pequeno no Ollama melhor replica a formatação do Wispr em PT-BR — Llama 3.2 3B vs
   Gemma 3 4B vs Qwen? Não há head-to-head publicado; testar com ditados reais da Hamsa.
2. Streaming parcial durante a fala vs transcrição em lote ao soltar a tecla — as fontes só
   documentam o padrão lote (que é o que o HamsaDictate já faz).
3. Quanto contexto do app alvo (via AX) cabe no prompt sem estourar a latência de limpeza.
