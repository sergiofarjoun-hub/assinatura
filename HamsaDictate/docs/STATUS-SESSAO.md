# Status do projeto HamsaDictate (Mac + Android) — backup de sessão

> Atualizado em 14/jul/2026. Documento de retomada: tudo que existe, onde está e o que falta.
> Sessão de origem: https://claude.ai/code/session_01Fb71WckN5iJGWTYRixJ7Ea

## O que é o projeto

Ditado por voz 100% local (estilo Wispr Flow, sem nuvem e sem assinatura) para o Sergio/Hamsa:
- **Mac:** app de menu bar — segura ⌥Espaço, fala, solta, o texto entra no campo ativo.
- **Android:** bubble flutuante — segura a bolinha, fala, solta, o texto entra no campo.

## Onde está cada coisa

| Item | Local |
|---|---|
| App Mac (código completo) | `HamsaDictate/` na branch `claude/faz-isso-ckwh1i` |
| App Android (código completo) | `HamsaDictateAndroid/` na mesma branch |
| APK pronto para instalar | Release `android-apk`: https://github.com/sergiofarjoun-hub/assinatura/releases/download/android-apk/app-debug.apk (~21 MB) |
| CI que gera o APK a cada push | `.github/workflows/android-apk.yml` |
| Pesquisa Wispr Flow (25 alegações verificadas) | `HamsaDictate/docs/PESQUISA-WISPRFLOW.md` |
| Esboço original + planos de fase | `HamsaDictate/docs/ESBOCO.md`, `PLANO-FASE-2.md`, `PLANO-FASE-3.md` |
| PR do MVP+Fase 2 Mac | #11 (branch `claude/hamsa-dictate-menubar-xg1z2r`) — aberto |
| PR da Fase 3 Mac + Android + pesquisa | #12 (branch `claude/faz-isso-ckwh1i`, empilhado sobre o #11) — aberto, draft |

## Estado do app de Mac

- MVP + Fase 2 implementados (PR #11) e **compilam no Mac do Sergio**.
- Crash de primeiro uso (SIGABRT/AttributeGraph ao abrir onboarding no init) **corrigido** no commit `7cf0d9a` — só na branch `claude/faz-isso-ckwh1i`; o PR #11 NÃO tem o fix.
- Fase 3 implementada (não testada no Mac ainda): `TextRefiner` via Ollama (`gemma3:4b`, endpoint OpenAI-compatible, fallback para texto cru), vocabulário de seguros no prompt do Whisper (`promptTokens`) e na limpeza, contexto do app via AX (`AppContextReader`), modo "ditar e-mail". Limpeza vem **desligada** por padrão.
- Para testar: branch `claude/faz-isso-ckwh1i`, `cd HamsaDictate && xcodegen generate && open HamsaDictate.xcodeproj`, ⌘R. Fase 3 exige `brew install ollama && ollama pull gemma3:4b`.

## Estado do app de Android

- MVP completo: `BubbleService` (overlay push-to-talk), `AudioRecorder` (16 kHz Float32), `Transcriber` (Whisper base int8 via **sherpa-onnx**, AAR baixado por `scripts/fetch-sherpa.sh` — não existe no Maven), `ModelManager` (baixa ~150 MB do GitHub no 1º uso), `HamsaAccessibilityService` (ACTION_PASTE → SET_TEXT → clipboard), `MainActivity` (onboarding 4 passos + idioma).
- **APK compila no CI e está publicado** (release `android-apk`, jniLibs compactadas: 21 MB).
- **Bloqueio atual: Google Play Protect (Brasil)** barra a instalação por o app declarar serviço de Acessibilidade; a opção de desligar a verificação não aparece no aparelho do Sergio.
- **Em andamento:** instalação via `adb` do Mac. Último estado: `adb: device offline` — falta o Sergio autorizar a depuração USB no celular (prompt "Permitir depuração USB" com a tela desbloqueada) e rodar `adb install HamsaDictate.apk`.
- **Plano C se o adb falhar:** refazer como **teclado de voz (IME)** — sem Acessibilidade, não cai no filtro do Play Protect. Muda a UX (troca de teclado em vez de bubble). ~1 dia de trabalho.
- Fase 2 Android planejada: limpeza via Ollama do Mac/NAS pela **Tailscale**, vocabulário Hamsa, waveform no bubble.

## Decisões importantes (não re-decidir)

1. Wispr Flow real é 100% nuvem (Baseten, Llama fine-tunado, p99 < 700 ms) — nosso diferencial é ser local. Ollama NÃO faz STT, só a limpeza de texto.
2. Mac: WhisperKit (Argmax OSS SDK ≥ 1.0, modelo `openai_whisper-large-v3-v20240930` = large-v3-turbo). Android: sherpa-onnx + whisper-base int8 (celular não roda o large).
3. Limpeza com IA é *enhancement*, nunca gargalo: qualquer falha/timeout → insere o texto cru.
4. Hotkey Mac por presets (sem key recorder). Timeout de limpeza 8 s (não os 2 s do plano).
5. Monitoramento de PR por check-ins horários foi **desligado a pedido do Sergio** — não recriar.

## Próximos passos (em ordem)

1. Concluir `adb install` no celular (ou acionar o Plano C do teclado).
2. Sergio testar o ditado PT-BR nos dois apps e reportar qualidade/bugs.
3. Mac: testar a Fase 3 com Ollama ligado; medir latência ponta a ponta.
4. Mergear #11 e depois #12 quando validados.
5. Android Fase 2 (Ollama via Tailscale + vocabulário).
