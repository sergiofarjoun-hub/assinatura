#!/bin/bash
# install.sh — instala o yt-sync no Mac: fila de vídeos do YouTube → notas no Obsidian.
# Uso: bash install.sh
set -euo pipefail

CONF_DIR="$HOME/.yt-obsidian-sync"
PLIST_LABEL="com.hamsa.yt-sync"
PLIST_PATH="$HOME/Library/LaunchAgents/$PLIST_LABEL.plist"
LOG_PATH="$HOME/Library/Logs/yt-sync.log"
SRC_DIR="$(cd "$(dirname "$0")" && pwd)"

say() { printf '\n\033[1m%s\033[0m\n' "$*"; }

[ -f "$SRC_DIR/yt2vault.py" ] && [ -f "$SRC_DIR/yt-sync.sh" ] || {
  echo "ERRO: yt2vault.py e yt-sync.sh precisam estar na mesma pasta que este install.sh"; exit 1; }

say "1/5 Verificando Python 3 e yt-dlp..."
command -v python3 >/dev/null || { echo "ERRO: python3 não encontrado."; exit 1; }
if ! command -v yt-dlp >/dev/null; then
  echo "   Instalando yt-dlp..."
  if command -v brew >/dev/null; then brew install yt-dlp
  else python3 -m pip install --user --quiet yt-dlp; fi
fi
YTDLP_BIN="$(command -v yt-dlp || echo "$HOME/Library/Python/$(python3 -c 'import sys;print(f"{sys.version_info[0]}.{sys.version_info[1]}")')/bin/yt-dlp")"
[ -x "$YTDLP_BIN" ] || { echo "ERRO: yt-dlp não instalou. Rode: brew install yt-dlp"; exit 1; }
echo "   OK: $YTDLP_BIN ($("$YTDLP_BIN" --version 2>/dev/null || echo '?'))"

say "2/5 Configuração..."
DEFAULT_VAULT="$HOME/SERVER/BASE_CONHECIMENTO"
[ -d "$DEFAULT_VAULT/.obsidian" ] || { [ -d "$HOME/SERVER/.obsidian" ] && DEFAULT_VAULT="$HOME/SERVER"; }
read -r -p "   Vault do Obsidian [$DEFAULT_VAULT]: " VAULT_DIR
VAULT_DIR="${VAULT_DIR:-$DEFAULT_VAULT}"
[ -d "$VAULT_DIR" ] || { echo "ERRO: pasta não existe: $VAULT_DIR"; exit 1; }

read -r -p "   Pasta das notas dentro do vault [YouTube]: " SUBDIR
SUBDIR="${SUBDIR:-YouTube}"

read -r -p "   Idiomas de legenda, em ordem de preferência [pt,en]: " LANGS
LANGS="${LANGS:-pt,en}"

echo "   Vídeo privado//com restrição de idade precisa do seu login do navegador."
read -r -p "   Usar cookies de qual navegador? (safari/chrome/firefox — Enter para nenhum): " COOKIES

echo "   Sem legenda, dá para transcrever localmente (whisper.cpp, faster-whisper…)."
echo "   O comando recebe: <arquivo.mp3> <pasta-de-trabalho> e deve deixar um .srt/.vtt na pasta."
read -r -p "   Comando de transcrição (Enter para pular): " WHISPER

echo "   Frames: fatia o vídeo em imagens para o conteúdo visual entrar na nota"
echo "   (é o que permite um agente 'assistir' ao vídeo). 0 = desligado."
echo "   O corte é por mudança de cena; o intervalo abaixo é o fallback para"
echo "   vídeo de plano único (talking head) e o modo 'interval' do config."
read -r -p "   Ligar frames? Intervalo de fallback em segundos, 0 = desligado [0]: " FRAMES_EVERY
FRAMES_EVERY="${FRAMES_EVERY:-0}"
if [ "$FRAMES_EVERY" -gt 0 ] 2>/dev/null && ! command -v ffmpeg >/dev/null; then
  echo "   ffmpeg não encontrado — instalando..."
  command -v brew >/dev/null && brew install ffmpeg || echo "   AVISO: instale o ffmpeg (brew install ffmpeg) ou os frames serão pulados."
fi

say "3/5 Instalando..."
mkdir -p "$CONF_DIR"
cp "$SRC_DIR/yt2vault.py" "$SRC_DIR/yt-sync.sh" "$CONF_DIR/"
chmod +x "$CONF_DIR/yt-sync.sh"
QUEUE_REL="$SUBDIR/_fila.md"
python3 - "$CONF_DIR/config.json" <<EOF
import json, sys
langs = [l.strip() for l in "$LANGS".split(",") if l.strip()]
cfg = {
  "vaultDir": "$VAULT_DIR",
  "subdir": "$SUBDIR",
  "queueFile": "$QUEUE_REL",
  "subLangs": langs,
  "ytdlpSubLangs": ",".join(f"{l}.*" for l in langs),
  "ytdlpBin": "$YTDLP_BIN",
  "cookiesFromBrowser": "$COOKIES",
  "whisperCmd": "$WHISPER",
  "framesEvery": int("$FRAMES_EVERY" or 0),
  "framesMode": "scene",
  "sceneThreshold": 0.3,
  "sceneMinFrames": 3,
  "framesMax": 60,
  "framesMaxHeight": 720,
  "extraTags": [],
}
json.dump(cfg, open(sys.argv[1], "w"), ensure_ascii=False, indent=2)
EOF
echo "   Instalado em $CONF_DIR"

# fila: a nota onde você cola as URLs
mkdir -p "$VAULT_DIR/$SUBDIR"
if [ ! -f "$VAULT_DIR/$QUEUE_REL" ]; then
  cat > "$VAULT_DIR/$QUEUE_REL" <<'QEOF'
---
tags:
  - youtube
---

# Fila — vídeos a importar

Cole uma URL do YouTube por linha. De hora em hora o sync baixa a transcrição,
cria a nota e troca a linha por um link para ela.

QEOF
  echo "   Fila criada: $VAULT_DIR/$QUEUE_REL"
fi

say "4/5 Agendando execução de hora em hora (launchd)..."
mkdir -p "$HOME/Library/LaunchAgents" "$HOME/Library/Logs"
cat > "$PLIST_PATH" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>$PLIST_LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/zsh</string>
        <string>-lc</string>
        <string>exec "$CONF_DIR/yt-sync.sh"</string>
    </array>
    <key>StartInterval</key><integer>3600</integer>
    <key>RunAtLoad</key><true/>
    <key>StandardOutPath</key><string>$LOG_PATH</string>
    <key>StandardErrorPath</key><string>$LOG_PATH</string>
</dict>
</plist>
EOF
launchctl bootout "gui/$(id -u)/$PLIST_LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST_PATH"
echo "   Agente instalado: roda de hora em hora e ao logar."

say "5/5 Primeira execução..."
"$CONF_DIR/yt-sync.sh" || true

say "Pronto!"
echo "  • Cole as URLs em:   $VAULT_DIR/$QUEUE_REL"
echo "  • Notas em:          $VAULT_DIR/$SUBDIR/"
echo "  • Roda sozinho:      de hora em hora"
echo "  • Log:               $LOG_PATH"
echo "  • Rodar agora:       $CONF_DIR/yt-sync.sh"
echo "  • Um vídeo avulso:   $CONF_DIR/yt-sync.sh <url>"
echo "  • Desinstalar:       launchctl bootout gui/\$(id -u)/$PLIST_LABEL && rm -rf $PLIST_PATH $CONF_DIR"
