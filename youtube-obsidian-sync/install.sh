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
# As seis perguntas abaixo aceitam resposta por variável de ambiente (modo não interativo,
# para rodar sem terminal — de uma rotina, por exemplo):
#   YT_SYNC_VAULT  YT_SYNC_SUBDIR  YT_SYNC_LANGS  YT_SYNC_COOKIES  YT_SYNC_WHISPER  YT_SYNC_FRAMES
# Variável definida (mesmo vazia) = resposta pronta, a pergunta não aparece (vazia = o padrão,
# igual a apertar Enter). YT_SYNC_NONINTERACTIVE=1 responde o padrão a toda pergunta sem variável.
# Sem variável e sem terminal (stdin fechado, EOF), o `read` devolve 1 e o `set -e` mataria o
# instalador em silêncio na primeira pergunta — por isso cada pergunta trata o EOF com erro claro.
# ask VAR ENV_NAME PADRAO "texto da pergunta: "
ask() {
  local __var="$1" __env="$2" __default="$3" __prompt="$4" __val __show
  if [ -n "${!__env+x}" ]; then
    __val="${!__env}"
    __show="${__val:-$__default}"
    echo "   ${__prompt}${__show:-(vazio)}   ← de \$$__env"
  elif [ "${YT_SYNC_NONINTERACTIVE:-}" = "1" ]; then
    __val=""
    echo "   ${__prompt}${__default:-(vazio)}   ← padrão (YT_SYNC_NONINTERACTIVE=1)"
  else
    read -r -p "   $__prompt" __val || {
      echo
      echo "ERRO: entrada encerrada (EOF) sem resposta para: ${__prompt%: }"
      echo "      Sem terminal, responda pela variável \$$__env ou use YT_SYNC_NONINTERACTIVE=1 (ver README)."
      exit 1; }
  fi
  printf -v "$__var" '%s' "${__val:-$__default}"
}

DEFAULT_VAULT="$HOME/SERVER/BASE_CONHECIMENTO"
[ -d "$DEFAULT_VAULT/.obsidian" ] || { [ -d "$HOME/SERVER/.obsidian" ] && DEFAULT_VAULT="$HOME/SERVER"; }
ask VAULT_DIR YT_SYNC_VAULT "$DEFAULT_VAULT" "Vault do Obsidian [$DEFAULT_VAULT]: "
[ -d "$VAULT_DIR" ] || { echo "ERRO: pasta não existe: $VAULT_DIR"; exit 1; }

ask SUBDIR YT_SYNC_SUBDIR "YouTube" "Pasta das notas dentro do vault [YouTube]: "

ask LANGS YT_SYNC_LANGS "pt,en" "Idiomas de legenda, em ordem de preferência [pt,en]: "

echo "   Vídeo privado//com restrição de idade precisa do seu login do navegador."
ask COOKIES YT_SYNC_COOKIES "" "Usar cookies de qual navegador? (safari/chrome/firefox — Enter para nenhum): "

echo "   Sem legenda, dá para transcrever localmente (whisper.cpp, faster-whisper…)."
echo "   O comando recebe: <arquivo.mp3> <pasta-de-trabalho> e deve deixar um .srt/.vtt na pasta."
echo "   Ele é executado direto, sem shell: caminhos absolutos, sem aspas, \$VAR ou ~ (se precisar, aponte para um script seu)."
ask WHISPER YT_SYNC_WHISPER "" "Comando de transcrição (Enter para pular): "

echo "   Frames: fatia o vídeo em imagens para o conteúdo visual entrar na nota"
echo "   (é o que permite um agente 'assistir' ao vídeo). 0 = desligado."
echo "   O corte é por mudança de cena; o intervalo abaixo é o fallback para"
echo "   vídeo de plano único (talking head) e o modo 'interval' do config."
echo "   O intervalo abaixo é o MÍNIMO: em vídeo longo ele cresce até framesMax cobrir tudo."
# Só dígitos: qualquer outra coisa (ex.: "abc", "10s", "1.5") repete a pergunta em vez de
# estourar no int() do Python mais adiante. Sem terminal (valor vindo de YT_SYNC_FRAMES ou
# do modo não interativo) não há como perguntar de novo: para com erro em vez de repetir.
while :; do
  ask FRAMES_EVERY YT_SYNC_FRAMES "0" "Ligar frames? Intervalo de fallback em segundos, 0 = desligado [0]: "
  case "$FRAMES_EVERY" in
    *[!0-9]*)
      echo "   Valor inválido: '$FRAMES_EVERY'. Digite só números inteiros (0 = desligado)."
      if [ -n "${YT_SYNC_FRAMES+x}" ] || [ "${YT_SYNC_NONINTERACTIVE:-}" = "1" ]; then
        echo "ERRO: YT_SYNC_FRAMES precisa ser um número inteiro (segundos; 0 = desligado)."; exit 1
      fi ;;
    *) break ;;
  esac
done
if [ "$FRAMES_EVERY" -gt 0 ] 2>/dev/null && ! command -v ffmpeg >/dev/null; then
  echo "   ffmpeg não encontrado — instalando..."
  command -v brew >/dev/null && brew install ffmpeg || echo "   AVISO: instale o ffmpeg (brew install ffmpeg) ou os frames serão pulados."
fi

say "3/5 Instalando..."
mkdir -p "$CONF_DIR"
cp "$SRC_DIR/yt2vault.py" "$SRC_DIR/yt-sync.sh" "$CONF_DIR/"
chmod +x "$CONF_DIR/yt-sync.sh"
QUEUE_REL="$SUBDIR/_fila.md"
# Os valores entram por argv e saem por json.dumps — o heredoc é 'EOF' (sem expansão do
# shell), então aspas, barras e acentos numa resposta (ex.: whisper-cli -m "/x/model.bin")
# não viram código Python: o json escapa tudo.
python3 - "$CONF_DIR/config.json" "$VAULT_DIR" "$SUBDIR" "$QUEUE_REL" "$LANGS" \
  "$YTDLP_BIN" "$COOKIES" "$WHISPER" "$FRAMES_EVERY" <<'EOF'
import json, sys
(out, vault_dir, subdir, queue_rel, langs_raw,
 ytdlp_bin, cookies, whisper, frames_every) = sys.argv[1:10]
langs = [l.strip() for l in langs_raw.split(",") if l.strip()]
cfg = {
  "vaultDir": vault_dir,
  "subdir": subdir,
  "queueFile": queue_rel,
  "subLangs": langs,
  "ytdlpSubLangs": ",".join(f"{l}.*" for l in langs),
  "ytdlpBin": ytdlp_bin,
  "cookiesFromBrowser": cookies,
  "whisperCmd": whisper,
  "framesEvery": int(frames_every or 0),
  "framesMode": "scene",
  "sceneThreshold": 0.3,
  "sceneMinFrames": 3,
  "framesMax": 60,
  "framesMaxHeight": 720,
  "extraTags": [],
}
with open(out, "w") as f:
    f.write(json.dumps(cfg, ensure_ascii=False, indent=2) + "\n")
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

say "4/5 Agendando execução de hora em hora, minuto 20 (launchd por calendário)..."
mkdir -p "$HOME/Library/LaunchAgents" "$HOME/Library/Logs"
cat > "$PLIST_PATH" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <!-- $PLIST_LABEL — de hora em hora, no minuto 20. Calendário, não StartInterval:
         os jobs por intervalo travaram em 02/09/2026 e o calendário sobreviveu.
         Só a chave Minute: com Hour o agente fica preso ao fuso antigo quando o Mac
         troca de fuso. Sem RunAtLoad: o instalador já roda o primeiro sync (passo 5/5). -->
    <key>Label</key><string>$PLIST_LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/zsh</string>
        <string>-lc</string>
        <string>exec "$CONF_DIR/yt-sync.sh"</string>
    </array>
    <key>StartCalendarInterval</key>
    <dict><key>Minute</key><integer>20</integer></dict>
    <key>RunAtLoad</key><false/>
    <key>StandardOutPath</key><string>$LOG_PATH</string>
    <key>StandardErrorPath</key><string>$LOG_PATH</string>
</dict>
</plist>
EOF
if [ "${YT_SYNC_SKIP_LAUNCHD:-}" = "1" ]; then
  # Modo para quem carrega o agente à mão (ou instala de dentro de um automatismo que
  # não pode chamar o launchctl): o plist fica gravado, o agente NÃO é carregado.
  echo "   Plist gravado em $PLIST_PATH — agente NÃO carregado (YT_SYNC_SKIP_LAUNCHD=1)."
  echo "   Para carregar, o dono da máquina roda este comando:"
  echo "launchctl bootstrap gui/\$(id -u) \"$PLIST_PATH\""
  echo "   Já carregado com este mesmo plist e quer rodar agora: launchctl kickstart -k gui/\$(id -u)/$PLIST_LABEL"
  echo "   O plist mudou (reinstalação)? Descarregue e carregue de novo: launchctl bootout gui/\$(id -u)/$PLIST_LABEL, depois o bootstrap acima."
else
  launchctl bootout "gui/$(id -u)/$PLIST_LABEL" 2>/dev/null || true
  launchctl bootstrap "gui/$(id -u)" "$PLIST_PATH"
  echo "   Agente instalado: roda de hora em hora, no minuto 20."
fi

say "5/5 Primeira execução..."
"$CONF_DIR/yt-sync.sh" || true

say "Pronto!"
echo "  • Cole as URLs em:   $VAULT_DIR/$QUEUE_REL"
echo "  • Notas em:          $VAULT_DIR/$SUBDIR/"
echo "  • Roda sozinho:      de hora em hora (minuto 20)"
if [ "${YT_SYNC_SKIP_LAUNCHD:-}" = "1" ]; then
  echo "  • ATENÇÃO:           o agente launchd ainda NÃO foi carregado — rode o comando impresso no passo 4/5."
fi
echo "  • Log:               $LOG_PATH"
echo "  • Rodar agora:       $CONF_DIR/yt-sync.sh"
echo "  • Um vídeo avulso:   $CONF_DIR/yt-sync.sh <url>"
echo "  • Desinstalar:       launchctl bootout gui/\$(id -u)/$PLIST_LABEL; rm -rf \"$PLIST_PATH\" \"$CONF_DIR\""
