#!/bin/bash
# setup.sh — garante yt-dlp e ffmpeg no ambiente. Idempotente; seguro de rodar sempre.
# Mac: brew primeiro (o pip --user do Mac instala fora do PATH e o Python do Homebrew
# recusa pip fora de venv). Container cloud do Claude Code: só pip (apt não está disponível
# e o binário do ffmpeg vem pelo pacote imageio-ffmpeg, que o PyPI liberado já serve).
# O comando `pip` pode não existir (Python.org 3.14 só traz pip3) — o pip é chamado como
# módulo do python3, com pip3/pip de reserva.
set -euo pipefail

have() { command -v "$1" >/dev/null 2>&1; }

# pip como módulo do python3 → pip3 → pip: o primeiro que responder instala.
pip_install() {
  local runner
  for runner in "python3 -m pip" pip3 pip; do
    if $runner --version >/dev/null 2>&1; then
      $runner install -q --user "$@" 2>/dev/null || $runner install -q "$@"
      return $?
    fi
  done
  echo "nenhum pip encontrado (python3 -m pip / pip3 / pip) — instale à mão: $*" >&2
  return 1
}

# o pip --user cai fora do PATH: ~/.local/bin (Linux) e ~/Library/Python/3.x/bin (Mac)
PY_MM="$(python3 -c 'import sys;print(f"{sys.version_info[0]}.{sys.version_info[1]}")' 2>/dev/null || echo 3)"
for dir in "$HOME/.local/bin" "$HOME/Library/Python/$PY_MM/bin"; do
  case ":$PATH:" in *":$dir:"*) ;; *) [ -d "$dir" ] && export PATH="$dir:$PATH" || true;; esac
done

if ! have yt-dlp; then
  if have brew; then
    echo "instalando yt-dlp (brew)..."
    brew install yt-dlp
  else
    echo "instalando yt-dlp (pip)..."
    pip_install yt-dlp
  fi
fi

if ! have ffmpeg; then
  if have brew; then
    echo "instalando ffmpeg (brew)..."
    brew install ffmpeg
  else
    echo "instalando ffmpeg (imageio-ffmpeg via pip)..."
    pip_install imageio-ffmpeg
    FF="$(python3 -c 'import imageio_ffmpeg;print(imageio_ffmpeg.get_ffmpeg_exe())')"
    for dir in /usr/local/bin "$HOME/.local/bin"; do
      if mkdir -p "$dir" 2>/dev/null && [ -w "$dir" ]; then ln -sf "$FF" "$dir/ffmpeg"; break; fi
    done
  fi
fi

echo "yt-dlp: $(command -v yt-dlp || echo AUSENTE) ($(yt-dlp --version 2>/dev/null || echo '?'))"
echo "ffmpeg: $(command -v ffmpeg || echo AUSENTE) ($(ffmpeg -version 2>/dev/null | head -1 | awk '{print $3}' || echo '?'))"
have yt-dlp && have ffmpeg
