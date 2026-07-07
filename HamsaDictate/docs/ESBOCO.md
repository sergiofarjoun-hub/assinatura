# Esboço — App de Ditado Local para Mac ("HamsaDictate")

> Documento de referência que originou o projeto.
> Objetivo: app de menu bar que transcreve ditado (PT-BR/EN) 100% local e insere o texto no campo ativo de qualquer app.

---

## 0. Decisão prévia (avaliar antes de codar)

Antes de construir do zero, testar 30 min cada:
- **Overwhisper** (github.com/OverseedAI/overwhisper) — open source, SwiftUI, WhisperKit + Parakeet, hotkey, inserção no cursor. É praticamente o produto final.
- **VoiceInk** — open source, similar.

Se um deles atender, **fork > from scratch**. Construir do zero só se justifica por:
1. Controle total do pipeline (ex.: pós-processamento com vocabulário de seguros: IPMI, VUMI, SUSEP, GeoBlue, apólice, sinistro)
2. Aprendizado de Swift/macOS
3. Features próprias futuras (integração com NAS, templates de e-mail ditados, etc.)

---

## 1. Stack recomendada

| Camada | Escolha | Por quê |
|---|---|---|
| Linguagem/UI | Swift + SwiftUI (`MenuBarExtra`) | Único caminho limpo para menu bar + inserção de texto no macOS |
| Engine ASR | **WhisperKit** (Argmax, Swift Package) | CoreML/Neural Engine, roda frio e rápido em Apple Silicon, 99 idiomas, PT-BR forte |
| Modelo | `openai_whisper-large-v3-turbo` (padrão) e `distil-large-v3` (opção rápida) | Turbo = melhor custo/latência para PT-BR |
| Hotkey global | Pacote `HotKey` (SPM) ou CGEvent tap | Simples, comprovado |
| Áudio | `AVAudioEngine` (input padrão do sistema) | Bluetooth funciona automaticamente |
| Inserção de texto | NSPasteboard + CGEvent (Cmd+V simulado) | Método universal; requer Acessibilidade |
| Build | Xcode 16+, target macOS 14+, arm64 | — |

**Alternativa de engine (fase 2):** Parakeet v3 multilingual via FluidAudio (Swift) — latência ~80ms vs 150-300ms do WhisperKit, suporta PT. Vale como segundo engine selecionável.

---

## 2. Fluxo do usuário

1. App vive no menu bar (sem ícone no Dock — `LSUIElement = true`)
2. Usuário foca qualquer campo de texto (Mail, WhatsApp Web, Notes, Claude…)
3. Pressiona hotkey:
   - **Push-to-talk:** segura `⌥ Space` → fala → solta → transcreve → insere
   - **Toggle:** aperta uma vez para gravar, de novo para parar
4. Feedback visual: ícone do menu bar muda (🎙️ pulsando) + overlay flutuante opcional com waveform
5. Texto aparece no cursor. Se Acessibilidade não estiver concedida → fallback: copia para clipboard + notificação "Cole com ⌘V"

---

## 3. Arquitetura / módulos

```
HamsaDictate/
├── HamsaDictateApp.swift        # @main, MenuBarExtra, ciclo de vida
├── Core/
│   ├── AudioRecorder.swift      # AVAudioEngine, buffer 16kHz mono, VAD simples (silêncio)
│   ├── TranscriptionEngine.swift# Protocolo + WhisperKitEngine (async)
│   ├── TextInserter.swift       # Pasteboard save→set→Cmd+V→restore
│   └── HotkeyManager.swift      # Registro global, push-to-talk + toggle
├── UI/
│   ├── MenuBarView.swift        # Status, últimas transcrições, botão settings
│   ├── SettingsView.swift       # Modelo, idioma, hotkey, device de input, overlay on/off
│   └── RecordingOverlay.swift   # NSPanel flutuante com waveform (fase 2)
├── Models/
│   └── AppSettings.swift        # @AppStorage / UserDefaults
└── Support/
    ├── PermissionsManager.swift # Microfone + Acessibilidade (AXIsProcessTrusted)
    └── ModelDownloader.swift    # Download/gestão dos modelos WhisperKit (~1.5GB turbo)
```

### Pipeline
```
Hotkey down → AudioRecorder.start()
Hotkey up   → AudioRecorder.stop() → [Float] 16kHz
            → WhisperKit.transcribe(audio, language: "pt")
            → pós-processamento (trim, capitalização, vocabulário custom)
            → TextInserter.insert(text)
```

---

## 4. Detalhes críticos de implementação

### 4.1 Inserção de texto (o ponto mais delicado)
```swift
// 1. Salvar clipboard atual
// 2. Escrever transcrição no NSPasteboard
// 3. Simular Cmd+V via CGEvent (keyDown/keyUp keycode 9 com flag .maskCommand)
// 4. Após ~150ms, restaurar clipboard original
```
- Requer **Acessibilidade** (System Settings → Privacy → Accessibility). Checar com `AXIsProcessTrustedWithOptions` e guiar o usuário.
- Fallback sem permissão: deixar no clipboard + `UNUserNotification`.
- Alternativa mais elegante (fase 2): inserção via Accessibility API direto no elemento focado (`AXUIElement`), sem tocar no clipboard — mais frágil entre apps, testar depois.

### 4.2 Bluetooth
- Não fazer nada especial: `AVAudioEngine` usa o input padrão do sistema. Se AirPods estiverem conectados, ele grava por eles.
- **Nota de qualidade:** mic Bluetooth em chamada usa perfil HFP (16kHz, mono, compressão agressiva). Transcrição fica um pouco pior que o mic interno do Mac. Incluir seletor de dispositivo nas Settings para o usuário forçar o mic interno se quiser.
- Detectar mudança de device (`AVAudioEngineConfigurationChange`) e reiniciar o engine.

### 4.3 Áudio
- Formato alvo: 16kHz, mono, Float32 (formato nativo do Whisper).
- Converter do formato do device com `AVAudioConverter`.
- Limite de gravação configurável (ex.: 2 min) para evitar hotkey preso.
- Detecção de silêncio: se RMS médio < threshold, descartar (evita transcrição fantasma).

### 4.4 WhisperKit
```swift
// SPM: https://github.com/argmaxinc/WhisperKit
let pipe = try await WhisperKit(model: "openai_whisper-large-v3-turbo")
let result = try await pipe.transcribe(
    audioArray: samples,
    decodeOptions: DecodingOptions(language: "pt", temperature: 0)
)
```
- Primeiro launch: download do modelo (~1.5GB) com progress bar nas Settings.
- Manter o modelo carregado em memória (warm) para latência baixa; opção de descarregar após N min idle.
- Idioma: dropdown PT / EN / Auto-detect.

### 4.5 Permissões (Info.plist)
- `NSMicrophoneUsageDescription`
- `LSUIElement = YES` (sem Dock)
- App **não sandboxed** (necessário para CGEvent/Acessibilidade). Uso pessoal → não precisa notarização; assinar ad-hoc ou com Developer ID se tiver.

---

## 5. Fases de implementação

**Fase 1 — MVP (implementada):**
1. Projeto Xcode: menu bar app esqueleto com MenuBarExtra
2. Gravação por hotkey fixo (⌥Space push-to-talk)
3. WhisperKit transcrevendo (modelo turbo, idioma pt)
4. Inserção via clipboard + Cmd+V
5. Fluxo de permissões (mic + acessibilidade) com instruções na tela

**Fase 2 — Polish:**
- Settings completo (modelo, idioma, hotkey configurável, device de áudio)
- Toggle mode + tap-or-hold
- Overlay flutuante com waveform
- Histórico das últimas 20 transcrições no menu
- Detecção de silêncio / limite de tempo

**Fase 3 — Diferencial Hamsa:**
- Vocabulário custom (prompt do Whisper com termos: IPMI, VUMI, SUSEP, GeoBlue, apólice, carência, CPT…)
- Pós-processamento opcional com LLM local (pontuação, remoção de "ééé", formatação de e-mail)
- Engine Parakeet v3 como opção de baixa latência
- Modo "ditar e-mail": transcreve + formata como e-mail profissional

---

## 6. Riscos e decisões em aberto

| Risco | Mitigação |
|---|---|
| API do WhisperKit pode ter mudado | Confirmado em jul/2026: WhisperKit agora faz parte do Argmax OSS SDK v1.0 (`argmax-oss-swift`); API `transcribe(audioArray:decodeOptions:) -> [TranscriptionResult]` |
| Cmd+V simulado falha em apps que bloqueiam paste sintético | Fallback clipboard; testar Accessibility API direta na fase 2 |
| Mic Bluetooth (HFP 16kHz) degrada acurácia | Seletor de device nas Settings (fase 2); recomendar mic interno para textos longos |
| Modelo turbo ~1.5GB + ~2GB RAM em uso | OK; oferecer distil/quantizado como opção leve |
| macOS 26 tem SpeechAnalyzer nativo (mais rápido p/ arquivos) | Avaliar como engine adicional futura, não bloqueia o MVP |
