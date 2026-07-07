# HamsaDictate 🎙️

App de menu bar para macOS que transcreve ditado (PT-BR/EN) **100% local** — WhisperKit rodando no Neural Engine — e insere o texto no campo ativo de qualquer app (Mail, WhatsApp Web, Notes, Claude…).

**Uso:** foque um campo de texto → **segure ⌥Espaço** → fale → **solte** → o texto aparece no cursor. Nas Configurações dá para trocar o atalho, o modo (toggle / tap-or-hold), o idioma, o dispositivo de entrada e o modelo.

## Requisitos

- Mac Apple Silicon (arm64), macOS 14+
- Xcode 16+
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) para gerar o projeto: `brew install xcodegen`
- ~1,5 GB de disco para o modelo (baixado no primeiro uso, do Hugging Face)

## Build

```bash
cd HamsaDictate
xcodegen generate          # gera HamsaDictate.xcodeproj a partir de project.yml
open HamsaDictate.xcodeproj
```

No Xcode: **⌘R**. O app aparece só no menu bar (sem ícone no Dock — `LSUIElement`).

## Primeiro uso

1. Na primeira execução, a janela de configuração abre automaticamente.
2. Conceda **Microfone** (prompt do sistema).
3. Conceda **Acessibilidade** (System Settings → Privacy & Security → Accessibility → habilite HamsaDictate). Necessária para o ⌘V simulado; sem ela o app funciona em modo fallback: o texto fica no clipboard e uma notificação pede para colar com ⌘V.
   - ⚠️ A cada rebuild no Xcode a assinatura ad-hoc muda e o macOS pode exigir re-conceder a Acessibilidade (remova e re-adicione o app na lista).
4. Aguarde o download do modelo (~1,5 GB, barra de progresso na janela e no menu). Nas execuções seguintes o modelo carrega do disco em segundos.

## Estados do ícone no menu bar

| Ícone | Estado |
|---|---|
| ⬇️ `arrow.down.circle` | baixando modelo |
| ⏳ `hourglass` | carregando modelo |
| 🎙️ `mic` | pronto |
| 🎙️ `mic.fill` (vermelho no menu) | gravando |
| 〰️ `waveform` | transcrevendo |
| ⚠️ `exclamationmark.triangle` | erro (some em ~4 s) |

## Arquitetura

```
HamsaDictate/
├── HamsaDictateApp.swift        # @main, MenuBarExtra
├── DictationController.swift    # pipeline hotkey→áudio→ASR→inserção; modos; overlay; reload de modelo
├── Core/
│   ├── AudioRecorder.swift      # AVAudioEngine → 16 kHz mono Float32; RMS; device por UID; níveis p/ waveform
│   ├── TranscriptionEngine.swift# protocolo + WhisperKitEngine (download+prepare+transcribe)
│   ├── TextInserter.swift       # salva clipboard → seta texto → ⌘V CGEvent → restaura
│   └── HotkeyManager.swift      # hotkey global re-registrável (presets ⌥/⌃/⌥⌘/⇧⌥ + Espaço)
├── UI/
│   ├── MenuBarView.swift        # status, histórico (últimas 20, scroll), configurações, sair
│   ├── SettingsView.swift       # permissões, ditado, áudio e modelo (também é o onboarding)
│   └── RecordingOverlay.swift   # NSPanel não-ativador com waveform / "transcrevendo…"
├── Models/
│   └── AppSettings.swift        # idioma, modelo, hotkey, modo, device, overlay (UserDefaults)
└── Support/
    ├── PermissionsManager.swift # mic (AVCaptureDevice) + AXIsProcessTrusted + notificações
    └── AudioDeviceManager.swift # enumeração CoreAudio dos inputs (nome + UID estável)
```

O download/gestão do modelo (o "ModelDownloader" do esboço) vive dentro de `WhisperKitEngine.prepare()` — o hub do WhisperKit já cuida de cache e retomada. A troca de modelo em runtime recria a engine e re-prepara (picker desabilitado durante gravação/transcrição).

## Decisões de implementação

- **Engine:** WhisperKit via **Argmax OSS SDK ≥ 1.0** (`github.com/argmaxinc/argmax-oss-swift`, produto `WhisperKit` — o repo antigo `WhisperKit` foi absorvido pelo SDK em maio/2026; `import WhisperKit` continua igual).
- **Modelo padrão:** `openai_whisper-large-v3-v20240930` — este **é** o large-v3-turbo (a Argmax o nomeia pela data de lançamento). Alternativas leves para testar depois: `openai_whisper-large-v3-v20240930_626MB` (quantizado) e `distil-whisper_distil-large-v3` (só EN).
- **Sem sandbox / hardened runtime:** exigido por CGEvent + Acessibilidade; assinatura ad-hoc, uso pessoal.
- **Bluetooth/dispositivos:** por padrão o `AVAudioEngine` usa o input do sistema — AirPods funcionam sem código extra. Mic BT em perfil HFP (16 kHz comprimido) transcreve um pouco pior; as Settings têm seletor de dispositivo (UID CoreAudio, aplicado na próxima gravação) para forçar o mic interno. Se o device mudar no meio da gravação, o app descarta o áudio e avisa (formato do tap fica inválido).
- **Proteções:** limite de 2 min por gravação (hotkey preso), descarte de gravações < 0,3 s (toque acidental) e de silêncio por RMS (transcrição fantasma).
- **Clipboard:** restaurado ~300 ms após o ⌘V; se estava vazio, a transcrição permanece nele.

## Roadmap (do esboço)

- **Fase 2 — concluída:** settings completo (hotkey por presets, device de áudio, troca de modelo em runtime), modos toggle e tap-or-hold, overlay com waveform, histórico de 20. Detalhes e decisões: [`docs/PLANO-FASE-2.md`](docs/PLANO-FASE-2.md).
- **Fase 3 — em progresso:** limpeza opcional do texto por LLM local via **Ollama** (endpoint OpenAI-compatible, com fallback para o texto cru), vocabulário Hamsa nas duas camadas (prompt do Whisper + prompt de limpeza), contexto do app em foco via Accessibility e modo "ditar e-mail". Pesquisa que embasou a fase: [`docs/PESQUISA-WISPRFLOW.md`](docs/PESQUISA-WISPRFLOW.md); plano e status: [`docs/PLANO-FASE-3.md`](docs/PLANO-FASE-3.md). Falta avaliar o engine Parakeet v3 (FluidAudio) por latência.

Esboço completo: [`docs/ESBOCO.md`](docs/ESBOCO.md).

### Fase 3: pré-requisito do Ollama

A limpeza com IA é **opcional e vem desligada**. Para usá-la:

```bash
brew install ollama
ollama pull gemma3:4b     # ou llama3.2:3b / qwen2.5:3b
```

Com o Ollama rodando, ligue "Limpeza com IA" nas Configurações. Se ele estiver fora do ar, o app insere a transcrição crua normalmente.
