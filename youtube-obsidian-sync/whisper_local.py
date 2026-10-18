#!/usr/bin/env python3
"""whisper_local — transcritor local para o yt-sync (contrato de whisperCmd):

  whisper_local.py <audio.mp3> <pasta-de-trabalho>

Transcreve com faster-whisper (modelo small, int8, CPU — o mesmo que o bot do WhatsApp usa) e
deixa <pasta>/<nome-do-audio>.<idioma>.srt, que o yt2vault lê como qualquer legenda. Nada sai
do Mac. Idioma detectado pelo modelo (pt/en/es…); força com WHISPER_LANG=pt. Modelo em
WHISPER_MODEL (padrão small; medium é mais preciso e ~3× mais lento). Primeira execução baixa o
modelo (~480 MB) para ~/.cache/huggingface.
"""
import os
import sys


def srt_time(s: float) -> str:
    ms = int(round(s * 1000))
    h, ms = divmod(ms, 3_600_000)
    m, ms = divmod(ms, 60_000)
    sec, ms = divmod(ms, 1000)
    return f"{h:02d}:{m:02d}:{sec:02d},{ms:03d}"


def main() -> int:
    if len(sys.argv) != 3:
        print(__doc__, file=sys.stderr)
        return 2
    audio, workdir = sys.argv[1], sys.argv[2]
    if not os.path.isfile(audio):
        print(f"áudio não encontrado: {audio}", file=sys.stderr)
        return 1
    try:
        from faster_whisper import WhisperModel
    except ImportError:
        print("faster-whisper não instalado neste python: pip3 install faster-whisper", file=sys.stderr)
        return 1
    modelo = os.environ.get("WHISPER_MODEL", "small")
    lang = os.environ.get("WHISPER_LANG") or None
    model = WhisperModel(modelo, device="cpu", compute_type="int8", cpu_threads=4)
    segments, info = model.transcribe(audio, language=lang, vad_filter=True, beam_size=5)
    lines = []
    n = 0
    for seg in segments:
        text = seg.text.strip()
        if not text:
            continue
        n += 1
        lines += [str(n), f"{srt_time(seg.start)} --> {srt_time(seg.end)}", text, ""]
    idioma = (info.language or "xx").lower()
    base = os.path.splitext(os.path.basename(audio))[0]
    out = os.path.join(workdir, f"{base}.{idioma}.srt")
    tmp = out + ".tmp"
    with open(tmp, "w", encoding="utf-8") as fh:
        fh.write("\n".join(lines))
    os.replace(tmp, out)
    print(f"transcrito: {out} ({n} trechos, idioma {idioma}, prob. {info.language_probability:.2f}, modelo {modelo})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
