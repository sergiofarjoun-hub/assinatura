#!/bin/bash
# yt-sync — orquestra: fila de URLs → yt-dlp (metadados + legenda) → yt2vault → vault.
# Roda via launchd de hora em hora; também aceita URLs direto na linha de comando:
#   yt-sync.sh https://youtube.com/shorts/XXXXXXXXXXX
set -euo pipefail

CONF_DIR="$HOME/.yt-obsidian-sync"
CONFIG="$CONF_DIR/config.json"
LOCK="$CONF_DIR/sync.lock"
WORK_ROOT="$CONF_DIR/work"
LOG_PREFIX="[$(date '+%Y-%m-%dT%H:%M:%S')]"

[ -f "$CONFIG" ] || { echo "$LOG_PREFIX Config não encontrada em $CONFIG. Rode o install.sh."; exit 2; }

py() { /usr/bin/env python3 -c "import json,sys;print(json.load(open('$CONFIG'))$1)"; }
VAULT_DIR="$(py "['vaultDir']")"
SUBDIR="$(py ".get('subdir','YouTube')")"
QUEUE_REL="$(py ".get('queueFile','YouTube/_fila.md')")"
SUB_LANGS="$(py ".get('ytdlpSubLangs','pt.*,en.*')")"
YTDLP="$(py ".get('ytdlpBin','yt-dlp')")"
COOKIES_BROWSER="$(py ".get('cookiesFromBrowser','')")"
WHISPER_CMD="$(py ".get('whisperCmd','')")"

# vault indisponível (mount do NAS fora) → sai quieto, tenta na próxima execução
[ -d "$VAULT_DIR" ] || { echo "$LOG_PREFIX Vault indisponível ($VAULT_DIR) — mount fora?"; exit 0; }
command -v "$YTDLP" >/dev/null || { echo "$LOG_PREFIX yt-dlp não encontrado ($YTDLP). Rode: brew install yt-dlp"; exit 1; }

# lock: impede execuções sobrepostas (stale após 30min)
if [ -d "$LOCK" ]; then
  if [ -n "$(find "$LOCK" -maxdepth 0 -mmin +30 2>/dev/null)" ]; then
    echo "$LOG_PREFIX Lock antigo (>30min) — removendo."; rm -rf "$LOCK"
  else
    echo "$LOG_PREFIX Já há um sync em andamento — saindo."; exit 0
  fi
fi
mkdir "$LOCK"
trap 'rm -rf "$LOCK"' EXIT

QUEUE="$VAULT_DIR/$QUEUE_REL"

# URLs a processar: as passadas como argumento, ou as linhas ainda não marcadas da fila
URLS=()
if [ "$#" -gt 0 ]; then
  URLS=("$@")
elif [ -f "$QUEUE" ]; then
  while IFS= read -r url; do
    [ -n "$url" ] && URLS+=("$url")
  done < <(grep -v '^\s*- \[x\]' "$QUEUE" 2>/dev/null \
           | grep -oE 'https?://[^ )>"]*(youtube\.com|youtu\.be)[^ )>"]*' || true)
fi

if [ "${#URLS[@]}" -eq 0 ]; then
  echo "$LOG_PREFIX Nada na fila ($QUEUE)."
  exit 0
fi

PROCESSED="$(python3 "$CONF_DIR/yt2vault.py" --processed "$CONFIG" || true)"

for URL in "${URLS[@]}"; do
  VID="$(python3 -c "import sys;sys.path.insert(0,'$CONF_DIR');from yt2vault import video_id;print(video_id(sys.argv[1]) or '')" "$URL")"
  if [ -z "$VID" ]; then
    echo "$LOG_PREFIX URL não reconhecida como vídeo do YouTube: $URL"
    continue
  fi
  if grep -qxF "$VID" <<<"$PROCESSED"; then
    echo "$LOG_PREFIX $VID já importado — pulando."
    continue
  fi

  echo "$LOG_PREFIX Baixando metadados e legenda de $VID..."
  WORK="$WORK_ROOT/$VID"
  rm -rf "$WORK" && mkdir -p "$WORK"

  YTOPTS=(--skip-download --write-info-json --write-subs --write-auto-subs
          --sub-langs "$SUB_LANGS" --sub-format "vtt/srt/best"
          --no-playlist --no-progress -o "$WORK/%(id)s.%(ext)s")
  [ -n "$COOKIES_BROWSER" ] && YTOPTS+=(--cookies-from-browser "$COOKIES_BROWSER")

  if ! "$YTDLP" "${YTOPTS[@]}" "$URL" >"$WORK/yt-dlp.log" 2>&1; then
    echo "$LOG_PREFIX ERRO no yt-dlp para $VID — veja $WORK/yt-dlp.log"
    continue
  fi

  # Sem legenda e com whisperCmd configurado: baixa o áudio e transcreve localmente.
  # Contrato: "$WHISPER_CMD <arquivo-de-audio> <workdir>" deve deixar um .srt/.vtt no workdir.
  if ! ls "$WORK"/*.vtt "$WORK"/*.srt >/dev/null 2>&1 && [ -n "$WHISPER_CMD" ]; then
    echo "$LOG_PREFIX Sem legenda — baixando áudio para transcrever localmente..."
    if "$YTDLP" -x --audio-format mp3 --no-playlist --no-progress \
         -o "$WORK/%(id)s.%(ext)s" "$URL" >>"$WORK/yt-dlp.log" 2>&1; then
      AUDIO="$(ls "$WORK"/*.mp3 2>/dev/null | head -1 || true)"
      [ -n "$AUDIO" ] && { $WHISPER_CMD "$AUDIO" "$WORK" >>"$WORK/whisper.log" 2>&1 \
        || echo "$LOG_PREFIX AVISO: whisperCmd falhou — veja $WORK/whisper.log"; }
    fi
  fi

  python3 "$CONF_DIR/yt2vault.py" --ingest "$CONFIG" "$WORK" "$URL" \
    && rm -rf "$WORK" \
    || echo "$LOG_PREFIX ERRO ao gerar a nota de $VID (material mantido em $WORK)"
done

echo "$LOG_PREFIX Sync YouTube concluído."
