#!/bin/bash
# yt-sync — orquestra: fila de URLs → yt-dlp (metadados + legenda / imagens) → yt2vault → vault.
# Roda via launchd de hora em hora; também aceita URLs direto na linha de comando:
#   yt-sync.sh https://youtube.com/shorts/XXXXXXXXXXX
#   yt-sync.sh https://www.instagram.com/p/XXXXXXXXXXX/     (post de imagens ou reel — desde 18/10/2026)
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
# idiomas preferidos, em ordem (subLangs); config antiga só com ytdlpSubLangs ('pt.*,en.*') também serve
SUB_PREFER="$(/usr/bin/env python3 -c "import json;c=json.load(open('$CONFIG'));print(','.join(c.get('subLangs') or [s.replace('.*','') for s in c.get('ytdlpSubLangs','pt.*,en.*').split(',') if s]))")"
SLEEP_SUBTITLES=6   # pausa (s) antes de cada legenda: sem ela o YouTube devolve HTTP 429
YTDLP="$(py ".get('ytdlpBin','yt-dlp')")"
COOKIES_BROWSER="$(py ".get('cookiesFromBrowser','')")"
WHISPER_CMD="$(py ".get('whisperCmd','')")"
WHISPER_MODEL_CFG="$(py ".get('whisperModel','')")"   # small (padrão do whisper_local.py) | medium (mais preciso, ~3× mais lento)
FRAMES_EVERY="$(py ".get('framesEvery',0)")"
FRAMES_MAX="$(py ".get('framesMax',60)")"
FRAMES_HEIGHT="$(py ".get('framesMaxHeight',720)")"
FRAMES_MODE="$(py ".get('framesMode','scene')")"
SCENE_THRESHOLD="$(py ".get('sceneThreshold',0.3)")"
SCENE_MIN="$(py ".get('sceneMinFrames',3)")"
SLIDES_MAX="$(py ".get('slidesMaxSize',1440)")"   # maior lado (px) de cada slide de post do Instagram

# vault indisponível (mount do NAS fora) → sai quieto, tenta na próxima execução
[ -d "$VAULT_DIR" ] || { echo "$LOG_PREFIX Vault indisponível ($VAULT_DIR) — mount fora?"; exit 0; }
command -v "$YTDLP" >/dev/null || { echo "$LOG_PREFIX yt-dlp não encontrado ($YTDLP). Rode: brew install yt-dlp"; exit 1; }

# saída com frames em tempos irregulares: ffmpeg 5.1+ usa -fps_mode; o 4.x só conhece
# -vsync, que o ffmpeg 9 removeu ("Unrecognized option 'vsync'")
FPS_MODE=(-fps_mode vfr)
if command -v ffmpeg >/dev/null; then
  # sem pipe: com `pipefail`, um grep -q que fecha cedo mata o ffmpeg (SIGPIPE) e inverte o teste
  FFHELP="$(ffmpeg -hide_banner -h full 2>/dev/null || true)"
  case "$FFHELP" in *-fps_mode*) ;; *) FPS_MODE=(-vsync vfr);; esac
  unset FFHELP
fi

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

# ---------------------------------------------------------------------------------------------
# Funções usadas pelos dois caminhos (YouTube e reel do Instagram). Leem os globais do loop:
# WORK, URL, VID, INFO, VIDEO, EVERY e os da config.
# ---------------------------------------------------------------------------------------------

# intervalo do fallback dos frames: framesEvery é o MÍNIMO; em vídeo longo cresce para os
# framesMax frames se espalharem por toda a duração (antes 60 × 10 s parava aos 10 min).
# A última imagem fica a menos de um intervalo do fim — amostragem por intervalo é assim.
calcular_every() {
  local dur=0
  if [ -n "${INFO:-}" ]; then
    dur="$(python3 -c "import json,sys;print(int(json.load(open(sys.argv[1])).get('duration') or 0))" "$INFO" 2>/dev/null || echo 0)"
  fi
  EVERY="$FRAMES_EVERY"
  if [ "$dur" -gt 0 ] 2>/dev/null && [ "$FRAMES_EVERY" -gt 0 ] 2>/dev/null; then
    local need=$(( (dur + FRAMES_MAX - 1) / FRAMES_MAX ))
    if [ "$need" -gt "$EVERY" ]; then EVERY="$need"; fi
  fi
}

# Sem legenda e com whisperCmd configurado: baixa o áudio e transcreve localmente.
# Contrato: "$WHISPER_CMD <arquivo-de-audio> <workdir>" deve deixar um .srt/.vtt no workdir.
transcrever_local() {
  if ! ls "$WORK"/*.vtt "$WORK"/*.srt >/dev/null 2>&1 && [ -n "$WHISPER_CMD" ]; then
    echo "$LOG_PREFIX Sem legenda — baixando áudio para transcrever localmente..."
    if "$YTDLP" -x --audio-format mp3 --no-playlist --no-progress \
         -o "$WORK/%(id)s.%(ext)s" "$URL" >>"$WORK/yt-dlp.log" 2>&1; then
      AUDIO="$(ls "$WORK"/*.mp3 2>/dev/null | head -1 || true)"
      [ -n "$AUDIO" ] && { WHISPER_MODEL="${WHISPER_MODEL_CFG:-${WHISPER_MODEL:-small}}" $WHISPER_CMD "$AUDIO" "$WORK" >>"$WORK/whisper.log" 2>&1 \
        || echo "$LOG_PREFIX AVISO: whisperCmd falhou — veja $WORK/whisper.log"; }
    fi
  fi
}

# Frames: baixa o vídeo, fatia com ffmpeg e joga fora o vídeo.
# É o que permite a um agente *ver* o conteúdo — ele lê as imagens uma a uma.
baixar_video_e_cortar() {
  if [ "$FRAMES_EVERY" -gt 0 ] 2>/dev/null; then
    if ! command -v ffmpeg >/dev/null; then
      echo "$LOG_PREFIX AVISO: framesEvery ligado mas ffmpeg não está instalado (brew install ffmpeg) — pulando frames."
    else
      if [ "$FRAMES_MODE" = "scene" ]; then
        echo "$LOG_PREFIX Extraindo frames por mudança de cena (limiar $SCENE_THRESHOLD)..."
      else
        echo "$LOG_PREFIX Extraindo 1 frame a cada ${EVERY}s..."
      fi
      VOPTS=(-f "bv*[height<=$FRAMES_HEIGHT]+ba/b[height<=$FRAMES_HEIGHT]/b"
             --no-playlist --no-progress -o "$WORK/video.%(ext)s")
      [ -n "$COOKIES_BROWSER" ] && VOPTS+=(--cookies-from-browser "$COOKIES_BROWSER")
      if "$YTDLP" "${VOPTS[@]}" "$URL" >>"$WORK/yt-dlp.log" 2>&1; then
        VIDEO="$(ls "$WORK"/video.* 2>/dev/null | head -1 || true)"
        if [ -n "$VIDEO" ]; then
          frames_do_video
        fi
      else
        echo "$LOG_PREFIX AVISO: não consegui baixar o vídeo para extrair frames — veja $WORK/yt-dlp.log"
      fi
    fi
  fi
}

# Corta os frames de $VIDEO (já no disco) e apaga o vídeo.
frames_do_video() {
  local SCALE="scale=-2:'min($FRAMES_HEIGHT,ih)'"

  # Corte por intervalo fixo: 1 frame a cada EVERY segundos. Deixa em times.txt
  # o segundo de cada frame (i × EVERY), que é o que o yt2vault lê.
  extract_interval() {
    local rc=0 n
    rm -rf "$WORK/frames"; mkdir -p "$WORK/frames"
    ffmpeg -nostdin -loglevel error -i "$VIDEO" \
      -vf "fps=1/$EVERY,$SCALE" \
      -frames:v "$FRAMES_MAX" -q:v 4 "$WORK/frames/frame-%04d.jpg" \
      >>"$WORK/ffmpeg.log" 2>&1 || rc=$?
    n="$(find "$WORK/frames" -name '*.jpg' 2>/dev/null | wc -l | tr -d ' ')"
    if [ "${n:-0}" -gt 0 ]; then seq 0 "$EVERY" $(( EVERY * (n - 1) )) > "$WORK/frames/times.txt"; fi
    return $rc
  }

  # Corte por mudança de cena: pega o primeiro frame e cada troca de
  # cena acima do limiar. Em screencast isso evita três frames do mesmo
  # slide parado e não perde o instante em que a tela muda.
  # O showinfo imprime pts_time de cada frame emitido, na ordem — daí
  # sai o times.txt que dá a marca de tempo real de cada imagem.
  extract_scene() {
    local rc=0
    rm -rf "$WORK/frames"; mkdir -p "$WORK/frames"
    ffmpeg -nostdin -loglevel info -i "$VIDEO" \
      -vf "select='eq(n\,0)+gt(scene\,$SCENE_THRESHOLD)',$SCALE,showinfo" \
      "${FPS_MODE[@]}" -frames:v "$FRAMES_MAX" -q:v 4 "$WORK/frames/frame-%04d.jpg" \
      >"$WORK/ffmpeg-scene.log" 2>&1 || rc=$?
    grep -o 'pts_time:[0-9.]*' "$WORK/ffmpeg-scene.log" \
      | cut -d: -f2 > "$WORK/frames/times.txt" || true
    return $rc   # ffmpeg recusou a linha (flag errada)? o chamador avisa
  }

  if [ "$FRAMES_MODE" = "scene" ]; then
    extract_scene || echo "$LOG_PREFIX AVISO: ffmpeg falhou — veja $WORK/ffmpeg-scene.log"
    # find, não ls: com set -e + pipefail, `ls *.jpg` sem resultado derrubava o script em silêncio
    N_SCENE="$(find "$WORK/frames" -name '*.jpg' 2>/dev/null | wc -l | tr -d ' ')"
    # Vídeo de plano único (talking head) rende quase nenhuma cena —
    # nesse caso o intervalo fixo cobre melhor.
    if [ "${N_SCENE:-0}" -lt "$SCENE_MIN" ]; then
      echo "$LOG_PREFIX Só $N_SCENE cena(s) detectada(s) — caindo para 1 frame a cada ${EVERY}s."
      extract_interval || echo "$LOG_PREFIX AVISO: ffmpeg falhou — veja $WORK/ffmpeg.log"
    fi
  else
    extract_interval || echo "$LOG_PREFIX AVISO: ffmpeg falhou — veja $WORK/ffmpeg.log"
  fi
  # duração lida do próprio arquivo (o yt-dlp nem sempre a devolve no Instagram); o yt2vault usa
  # quando o info.json vem sem "duration"
  if command -v ffprobe >/dev/null; then
    ffprobe -v error -show_entries format=duration -of csv=p=0 "$VIDEO" > "$WORK/duration.txt" 2>/dev/null || true
  fi
  rm -f "$VIDEO"   # o vídeo em si nunca fica no disco
  # só .jpg: o times.txt mora na mesma pasta e não é frame
  echo "$LOG_PREFIX $(find "$WORK/frames" -name '*.jpg' 2>/dev/null | wc -l | tr -d ' ') frames extraídos."
}

# ---------------------------------------------------------------------------------------------
# Post ou reel do Instagram (18/10/2026). O Instagram não tem legenda; o texto do post vai para a
# Descrição. Post de imagens (um ou carrossel): o yt-dlp não baixa imagem como "vídeo", mas com
# --ignore-no-formats-error + --write-thumbnail entrega a imagem inteira de cada item (HEIC, às
# vezes JPG/WEBP) — cada uma vira um "frame" rotulado "slide N/T", sem depender de framesEvery
# (os slides SÃO o conteúdo). Reel: baixa o vídeo e corta frames como no YouTube. Carrossel com
# um item de vídeo: fica só a capa desse item (limite conhecido).
# Layout no workdir: <id>.info.json do post (só carrossel) + itens/NN-<id>.{info.json,heic}.
# ---------------------------------------------------------------------------------------------
importar_instagram() {
  mkdir -p "$WORK/itens"
  local opts=(--skip-download --write-info-json --ignore-no-formats-error --write-thumbnail --no-progress
              -o "$WORK/itens/%(playlist_index|0)02d-%(id)s.%(ext)s" -o "pl_infojson:$WORK/%(id)s")
  [ -n "$COOKIES_BROWSER" ] && opts+=(--cookies-from-browser "$COOKIES_BROWSER")
  if ! "$YTDLP" "${opts[@]}" "$URL" >"$WORK/yt-dlp.log" 2>&1; then
    echo "$LOG_PREFIX ERRO no yt-dlp para $VID (Instagram) — veja $WORK/yt-dlp.log"
    return 1
  fi
  local kind
  kind="$(python3 -c "import sys;sys.path.insert(0,'$CONF_DIR');from yt2vault import instagram_kind;print(instagram_kind(sys.argv[1]))" "$WORK" 2>>"$WORK/yt-dlp.log" || echo "")"
  case "$kind" in
    imagens)
      rm -rf "$WORK/frames"; mkdir -p "$WORK/frames"; : > "$WORK/frames/labels.txt"
      local n=0 total f out
      total="$(find "$WORK/itens" -type f \( -iname '*.heic' -o -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.webp' -o -iname '*.png' \) 2>/dev/null | wc -l | tr -d ' ')"
      while IFS= read -r f; do
        [ -n "$f" ] || continue
        n=$((n + 1))
        [ "$n" -le "$FRAMES_MAX" ] || break
        out="$WORK/frames/frame-$(printf '%04d' "$n").jpg"
        # sips é do macOS (lê HEIC sem instalar nada); ffmpeg fica de reserva
        if command -v sips >/dev/null; then
          sips -s format jpeg -Z "$SLIDES_MAX" "$f" --out "$out" >>"$WORK/sips.log" 2>&1 || true
        fi
        if [ ! -s "$out" ] && command -v ffmpeg >/dev/null; then
          ffmpeg -nostdin -loglevel error -i "$f" -q:v 3 "$out" >>"$WORK/ffmpeg.log" 2>&1 || true
        fi
        if [ -s "$out" ]; then
          echo "slide $n/$total" >> "$WORK/frames/labels.txt"
        else
          rm -f "$out"
          echo "$LOG_PREFIX AVISO: não consegui converter o slide $n ($f)"
        fi
      done < <(find "$WORK/itens" -type f \( -iname '*.heic' -o -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.webp' -o -iname '*.png' \) 2>/dev/null | sort)
      echo "$LOG_PREFIX Post de imagens: $(find "$WORK/frames" -name '*.jpg' 2>/dev/null | wc -l | tr -d ' ') de $total slide(s)."
      ;;
    video)
      INFO="$(ls "$WORK"/itens/*.info.json 2>/dev/null | head -1 || true)"
      echo "$LOG_PREFIX Reel/vídeo do Instagram (sem legenda)."
      calcular_every
      transcrever_local
      baixar_video_e_cortar
      ;;
    *)
      echo "$LOG_PREFIX ERRO: não reconheci o post $VID (nem imagens nem vídeo) — veja $WORK/yt-dlp.log"
      return 1
      ;;
  esac
  return 0
}

# URLs a processar: as passadas como argumento, ou as linhas ainda não marcadas da fila
URLS=()
if [ "$#" -gt 0 ]; then
  URLS=("$@")
elif [ -f "$QUEUE" ]; then
  while IFS= read -r url; do
    [ -n "$url" ] && URLS+=("$url")
  done < <(grep -v '^\s*- \[x\]' "$QUEUE" 2>/dev/null \
           | grep -oE 'https?://[^ )>"]*(youtube\.com|youtu\.be|instagram\.com)[^ )>"]*' || true)
fi

if [ "${#URLS[@]}" -eq 0 ]; then
  echo "$LOG_PREFIX Nada na fila ($QUEUE)."
  exit 0
fi

PROCESSED="$(python3 "$CONF_DIR/yt2vault.py" --processed "$CONFIG" || true)"

for URL in "${URLS[@]}"; do
  VID="$(python3 -c "import sys;sys.path.insert(0,'$CONF_DIR');from yt2vault import video_id;print(video_id(sys.argv[1]) or '')" "$URL")"
  FONTE="$(python3 -c "import sys;sys.path.insert(0,'$CONF_DIR');from yt2vault import source_of;print(source_of(sys.argv[1]) or '')" "$URL")"
  if [ -z "$VID" ] || [ -z "$FONTE" ]; then
    echo "$LOG_PREFIX URL não reconhecida (vale vídeo do YouTube ou post/reel do Instagram): $URL"
    continue
  fi
  if grep -qxF "$VID" <<<"$PROCESSED"; then
    echo "$LOG_PREFIX $VID já importado — pulando."
    continue
  fi

  WORK="$WORK_ROOT/$VID"
  rm -rf "$WORK" && mkdir -p "$WORK"
  INFO=""; VIDEO=""; EVERY="$FRAMES_EVERY"

  if [ "$FONTE" = "instagram" ]; then
    echo "$LOG_PREFIX Baixando o post do Instagram $VID..."
    importar_instagram || continue
  else
    echo "$LOG_PREFIX Baixando metadados e legenda de $VID..."

    # 1) metadados, ainda sem legenda: o info.json diz quais legendas existem
    YTOPTS=(--skip-download --write-info-json --no-playlist --no-progress -o "$WORK/%(id)s.%(ext)s")
    [ -n "$COOKIES_BROWSER" ] && YTOPTS+=(--cookies-from-browser "$COOKIES_BROWSER")

    if ! "$YTDLP" "${YTOPTS[@]}" "$URL" >"$WORK/yt-dlp.log" 2>&1; then
      echo "$LOG_PREFIX ERRO no yt-dlp para $VID — veja $WORK/yt-dlp.log"
      continue
    fi
    INFO="$(ls "$WORK"/*.info.json 2>/dev/null | head -1 || true)"

    # 2) UMA legenda só — manual no idioma preferido, senão a automática do idioma ORIGINAL,
    #    tradução automática só na falta de original (choose_sub_langs, no yt2vault.py).
    #    Pedir várias de uma vez (pt, pt-PT, en, en-orig) rendia HTTP 429. --load-info-json
    #    reaproveita os metadados: não bate de novo na página do vídeo.
    SUB_KEYS=""
    if [ -n "$INFO" ]; then
      SUB_KEYS="$(python3 -c "import sys,json;sys.path.insert(0,'$CONF_DIR');from yt2vault import choose_sub_langs;print(','.join(choose_sub_langs(json.load(open(sys.argv[1])),sys.argv[2].split(','))))" "$INFO" "$SUB_PREFER" 2>>"$WORK/yt-dlp.log" || true)"
    fi
    if [ -n "$SUB_KEYS" ]; then
      echo "$LOG_PREFIX Legenda escolhida: $SUB_KEYS"
      SUBOPTS=(--load-info-json "$INFO" --skip-download --write-subs --write-auto-subs
               --sub-langs "$SUB_KEYS" --sub-format "vtt/srt/best" --sleep-subtitles "$SLEEP_SUBTITLES"
               --no-progress -o "$WORK/%(id)s.%(ext)s")
      [ -n "$COOKIES_BROWSER" ] && SUBOPTS+=(--cookies-from-browser "$COOKIES_BROWSER")
      "$YTDLP" "${SUBOPTS[@]}" >>"$WORK/yt-dlp.log" 2>&1 \
        || echo "$LOG_PREFIX AVISO: legenda $SUB_KEYS falhou — veja $WORK/yt-dlp.log"
    else
      echo "$LOG_PREFIX Vídeo sem legenda (nem automática)."
    fi

    calcular_every
    transcrever_local
    baixar_video_e_cortar
  fi

  python3 "$CONF_DIR/yt2vault.py" --ingest "$CONFIG" "$WORK" "$URL" \
    && rm -rf "$WORK" \
    || echo "$LOG_PREFIX ERRO ao gerar a nota de $VID (material mantido em $WORK)"
done

echo "$LOG_PREFIX Sync YouTube/Instagram concluído."
