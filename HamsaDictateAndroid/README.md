# HamsaDictate para Android 🎙️

Versão Android do [HamsaDictate](../HamsaDictate/README.md): ditado por voz **100% local**, no modelo do Wispr Flow para Android — um **bubble flutuante** sobre qualquer app.

**Uso:** ligue o bubble → toque num campo de texto de qualquer app (WhatsApp, Gmail…) → **segure o bubble** → fale → **solte** → o texto entra no campo. Arrastar o bubble o reposiciona.

## Como funciona

| Peça | Implementação |
|---|---|
| Gatilho | Bubble overlay (`TYPE_APPLICATION_OVERLAY`, `FLAG_NOT_FOCUSABLE` — o foco fica no app de baixo) |
| Áudio | `AudioRecord` 16 kHz mono Float32, limite 2 min, descarte de silêncio/toques < 0,3 s |
| Transcrição | **sherpa-onnx** (ONNX Runtime) com **Whisper base int8** multilíngue, on-device; download (~150 MB) no primeiro uso |
| Inserção | Serviço de Acessibilidade: `ACTION_PASTE` no cursor (clipboard restaurado ~1 s depois) → `ACTION_SET_TEXT` → fallback clipboard + toast |
| Privacidade | Nenhum áudio ou texto sai do aparelho; o serviço de acessibilidade não escuta eventos de tela (age só ao soltar o bubble) |

## Requisitos

- Android 8+ (API 26), aparelho arm64 (qualquer celular moderno)
- ~600 MB livres (modelo + app)

## Instalação (APK)

1. Instale o APK (`app-debug.apk`) — o Android pedirá para permitir "instalar apps desconhecidos".
2. Abra o app e complete os 4 passos da tela: **Microfone**, **Sobrepor a outros apps**, **Acessibilidade** e **Baixar modelo**.
3. Toque **Ligar o bubble** e teste no WhatsApp.

## Build

```bash
cd HamsaDictateAndroid
bash scripts/fetch-sherpa.sh   # baixa o AAR do sherpa-onnx (uma vez)
gradle assembleDebug
# APK em app/build/outputs/apk/debug/app-debug.apk
```

Requer JDK 17 e Android SDK (compileSdk 34). O CI (`.github/workflows/android-apk.yml`) faz esse build a cada push e publica o APK na release `android-apk`.

## Roadmap

- **MVP (este código):** bubble push-to-talk + Whisper base local + inserção por acessibilidade + idioma PT/EN/auto.
- **Fase 2:** limpeza com IA via **Ollama do Mac/NAS pela rede Tailscale** (transcrição continua no aparelho; só o texto viaja pela rede privada), vocabulário Hamsa, waveform no bubble, modelo small como opção de qualidade.

Decisões e pesquisa que embasaram o projeto: [`../HamsaDictate/docs/PESQUISA-WISPRFLOW.md`](../HamsaDictate/docs/PESQUISA-WISPRFLOW.md).
