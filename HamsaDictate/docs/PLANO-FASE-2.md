# Plano — Fase 2 (Polish) do HamsaDictate

> Status: **implementada** em jul/2026 (mesma branch/PR do MVP).
> Itens da Fase 2 do esboço ([ESBOCO.md](ESBOCO.md), seção 5) e como cada um foi resolvido.

## 1. Settings completo ✅

Janela única "Configurações" (`UI/SettingsView.swift`, `Form` estilo grouped) que também faz o papel de onboarding — abre sozinha no primeiro launch enquanto faltarem permissões. Seções:

| Seção | Conteúdo |
|---|---|
| Permissões | Microfone + Acessibilidade, com re-checagem por polling (AX não tem callback) |
| Ditado | Atalho global (presets), modo (push-to-talk / toggle / inteligente), idioma (PT/EN/auto), overlay on/off |
| Áudio | Seletor de dispositivo de entrada (CoreAudio; "Padrão do sistema" + lista por UID) |
| Modelo | 4 variantes com troca em runtime + progresso de download |

Decisões:
- **Hotkey por presets** (⌥Espaço, ⌃Espaço, ⌥⌘Espaço, ⇧⌥Espaço) em vez de um gravador de atalho arbitrário — cobre os casos práticos sem o custo/fragilidade de um key recorder NSEvent. Recorder fica para quando houver demanda real.
- **Device por UID CoreAudio** (estável entre reboots), aplicado no `inputNode` via `kAudioOutputUnitProperty_CurrentDevice` no próximo `start()` — não interrompe gravação em andamento.
- **Troca de modelo em runtime**: recria a `WhisperKitEngine` e re-prepara; o picker fica desabilitado fora de idle/erro para não puxar o tapete de uma transcrição em andamento. Variantes: Large v3 Turbo (padrão), Turbo quantizado 626 MB, Small multilíngue, Distil Large v3 (EN).

## 2. Toggle mode + tap-or-hold ✅

Três modos em `DictationController` (enum `DictationMode`):
- **push-to-talk** (padrão): keyDown grava, keyUp transcreve;
- **toggle**: keyDown alterna; keyUp ignorado;
- **inteligente (tap-or-hold)**: keyDown inicia; se o keyUp vier em < 0,35 s foi um toque → gravação fica travada até o próximo toque; se vier depois, foi uma segurada → encerra como push-to-talk.

O limiar de 0,35 s combina com o descarte de gravações < 0,3 s do MVP (toque acidental não gera transcrição fantasma).

## 3. Overlay flutuante com waveform ✅

`UI/RecordingOverlay.swift`: `NSPanel` borderless **não-ativador** (`.nonactivatingPanel` + `ignoresMouseEvents`) — crítico para o foco (e o cursor de texto) permanecerem no app alvo durante o ⌘V simulado. Nível `.statusBar`, todas as Spaces/fullscreen, posicionado no centro-inferior da tela onde está o mouse. Mostra waveform de 32 barras (RMS por buffer vindo do `AudioRecorder.onLevel`, ganho ×12 para visual) durante a gravação e spinner "Transcrevendo…" depois. Desligável nas Settings.

## 4. Histórico de 20 transcrições ✅

`maxHistoryEntries` 5 → 20, menu com `ScrollView` (max 220 pt) + botão "Limpar". Clique copia para o clipboard.

## 5. Detecção de silêncio / limite de tempo ✅ (desde o MVP)

RMS < 0,0025 descarta; limite de 2 min encerra e transcreve.

## Fora do escopo desta fase (fica para a Fase 3)

- Vocabulário Hamsa no prompt do Whisper (IPMI, VUMI, SUSEP, GeoBlue, apólice, carência, CPT…)
- Pós-processamento com LLM local (pontuação, remoção de "ééé", formatação de e-mail)
- Engine Parakeet v3 via FluidAudio (baixa latência) como segundo engine selecionável
- Modo "ditar e-mail"
- Gravador de hotkey arbitrário; descarregar modelo após N min idle
