#!/bin/bash
# setup.sh — garante yt-dlp e ffmpeg no ambiente. Idempotente; seguro de rodar sempre.
# Funciona no Mac (brew) e no container cloud do Claude Code (só pip: apt não está disponível
# e o binário do ffmpeg vem pelo pacote imageio-ffmpeg, que o PyPI liberado já serve).
set -euo pipefail

have() { command -v "$1" >/dev/null 2>&1; }

if ! have yt-dlp; then
  echo "instalando yt-dlp..."
  pip install -q --user yt-dlp 2>/dev/null || pip install -q yt-dlp
fi

if ! have ffmpeg; then
  if have brew; then
    echo "instalando ffmpeg (brew)..."
    brew install ffmpeg
  else
    echo "instalando ffmpeg (imageio-ffmpeg via pip)..."
    pip install -q --user imageio-ffmpeg 2>/dev/null || pip install -q imageio-ffmpeg
    FF="$(python3 -c 'import imageio_ffmpeg;print(imageio_ffmpeg.get_ffmpeg_exe())')"
    for dir in /usr/local/bin "$HOME/.local/bin"; do
      if mkdir -p "$dir" 2>/dev/null && [ -w "$dir" ]; then ln -sf "$FF" "$dir/ffmpeg"; break; fi
    done
  fi
fi

# ~/.local/bin nem sempre está no PATH do container
case ":$PATH:" in *":$HOME/.local/bin:"*) ;; *) export PATH="$HOME/.local/bin:$PATH";; esac

echo "yt-dlp: $(command -v yt-dlp || echo AUSENTE) ($(yt-dlp --version 2>/dev/null || echo '?'))"
echo "ffmpeg: $(command -v ffmpeg || echo AUSENTE)"
have yt-dlp && have ffmpeg
