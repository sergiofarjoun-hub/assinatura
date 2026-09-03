#!/usr/bin/env python3
"""
watch.py — prepara um vídeo para o Claude "assistir": transcrição em texto + frames
por mudança de cena, tudo numa pasta de trabalho com um manifest.md que lista o que ler.

Uso:
  watch.py <url-ou-arquivo> [--out DIR] [--langs pt,en] [--no-frames]
           [--scene 0.3] [--every 10] [--max-frames 60] [--height 720]
           [--cookies-from-browser safari|chrome|firefox]

Saída (em --out, padrão ./.watch/<id>/):
  info.json        metadados do yt-dlp (título, canal, duração, descrição…)
  transcript.md    legenda limpa em parágrafos com marca de tempo (ou aviso de ausência)
  frames/*.jpg     um frame por mudança de cena, nome = índice + segundo
  manifest.md      resumo + lista de arquivos para o Claude ler, na ordem

Nada sai da máquina além dos pedidos ao YouTube (ou ao site do vídeo). Sem API de
transcrição de terceiros: se o vídeo não tem legenda, o transcript avisa e para por aí.
"""

import argparse
import glob
import json
import os
import re
import shutil
import subprocess
import sys

# --------------------------------------------------------------- utilidades

def hhmmss(seconds) -> str:
    try:
        total = int(float(seconds))
    except (TypeError, ValueError):
        return ""
    h, rest = divmod(total, 3600)
    m, s = divmod(rest, 60)
    return f"{h}:{m:02d}:{s:02d}" if h else f"{m}:{s:02d}"


def run(cmd: list[str], log_path: str, check: bool = True) -> int:
    with open(log_path, "a", encoding="utf-8") as log:
        log.write("$ " + " ".join(cmd) + "\n")
        log.flush()
        proc = subprocess.run(cmd, stdout=log, stderr=subprocess.STDOUT)
    if check and proc.returncode != 0:
        raise SystemExit(f"comando falhou ({proc.returncode}): {' '.join(cmd[:2])} … — veja {log_path}")
    return proc.returncode


def video_id_from(url: str) -> str | None:
    for pat in (
        r"(?:youtube\.com|youtube-nocookie\.com)/(?:shorts|embed|live|v)/([\w-]{11})",
        r"youtube\.com/watch\?(?:[^&]*&)*v=([\w-]{11})",
        r"youtu\.be/([\w-]{11})",
    ):
        m = re.search(pat, url)
        if m:
            return m.group(1)
    return None


# ---------------------------------------------------------- legenda → texto
# Mesmo parser do youtube-obsidian-sync/yt2vault.py (mantido em sincronia à mão).

CUE_TIME = re.compile(r"^(\d{1,2}:\d{2}:\d{2})[.,]\d{1,3}\s*-->\s*\d{1,2}:\d{2}:\d{2}[.,]\d{1,3}")
INLINE_TAG = re.compile(r"<[^>]+>")


def parse_subtitles(path: str) -> list[tuple[str, str]]:
    """Lê .vtt/.srt e desfaz as legendas 'rolantes' do YouTube (cada cue repete o anterior)."""
    with open(path, "r", encoding="utf-8", errors="replace") as fh:
        raw = fh.read()
    out: list[tuple[str, str]] = []
    ts = ""
    for line in raw.replace("\r\n", "\n").replace("\r", "\n").split("\n"):
        line = line.strip()
        if not line or line == "WEBVTT" or line.startswith(("NOTE", "STYLE", "Kind:", "Language:")):
            continue
        m = CUE_TIME.match(line)
        if m:
            ts = m.group(1)
            continue
        if re.fullmatch(r"\d+", line):
            continue
        text = re.sub(r"\s+", " ", INLINE_TAG.sub("", line)).strip()
        if not text or text in ("[Music]", "[Música]"):
            continue
        if out:
            prev_ts, prev = out[-1]
            if text == prev or prev.endswith(text):
                continue
            if text.startswith(prev):
                out[-1] = (prev_ts, text)
                continue
        out.append((ts or "0:00:00", text))
    return out


def to_seconds(ts: str) -> int:
    parts = [int(p) for p in ts.split(":")]
    while len(parts) < 3:
        parts.insert(0, 0)
    return parts[0] * 3600 + parts[1] * 60 + parts[2]


def group_transcript(cues: list[tuple[str, str]], every: int = 30) -> str:
    if not cues:
        return ""
    blocks, chunk, start = [], [], cues[0][0]
    for ts, text in cues:
        if chunk and to_seconds(ts) - to_seconds(start) >= every:
            blocks.append(f"**[{hhmmss(to_seconds(start))}]** " + " ".join(chunk))
            chunk, start = [], ts
        chunk.append(text)
    if chunk:
        blocks.append(f"**[{hhmmss(to_seconds(start))}]** " + " ".join(chunk))
    return "\n\n".join(blocks)


def pick_subtitle(workdir: str, prefer: list[str]) -> tuple[str | None, str | None]:
    files = sorted(glob.glob(os.path.join(workdir, "*.vtt")) + glob.glob(os.path.join(workdir, "*.srt")))
    if not files:
        return None, None

    def lang_of(p: str) -> str:
        m = re.search(r"\.([A-Za-z-]+)\.(?:vtt|srt)$", os.path.basename(p))
        return (m.group(1) if m else "").lower()

    def rank(p: str) -> tuple[int, int]:
        lang = lang_of(p)
        pref = next((i for i, l in enumerate(prefer) if lang.startswith(l.lower())), len(prefer))
        return (pref, 1 if "-orig" in lang else 0)

    best = min(files, key=rank)
    return best, lang_of(best)


# ------------------------------------------------------------------ frames

def extract_frames(video: str, frames_dir: str, args, log: str) -> list[int]:
    """Frames por mudança de cena (primeiro frame + cada troca acima do limiar).
    Devolve a lista de segundos de cada frame. Cai para intervalo fixo em vídeo de plano único."""
    scale = f"scale=-2:'min({args.height},ih)'"

    def scene() -> list[int]:
        shutil.rmtree(frames_dir, ignore_errors=True)
        os.makedirs(frames_dir)
        scene_log = os.path.join(os.path.dirname(frames_dir), "ffmpeg-scene.log")
        open(scene_log, "w").close()
        cmd = ["ffmpeg", "-nostdin", "-loglevel", "info", "-i", video,
               "-vf", f"select='eq(n\\,0)+gt(scene\\,{args.scene})',{scale},showinfo",
               "-vsync", "vfr", "-frames:v", str(args.max_frames), "-q:v", "4",
               os.path.join(frames_dir, "raw-%04d.jpg")]
        run(cmd, scene_log, check=False)
        with open(scene_log, encoding="utf-8", errors="replace") as fh:
            return [int(float(x)) for x in re.findall(r"pts_time:([0-9.]+)", fh.read())]

    def interval() -> list[int]:
        shutil.rmtree(frames_dir, ignore_errors=True)
        os.makedirs(frames_dir)
        run(["ffmpeg", "-nostdin", "-loglevel", "error", "-i", video,
             "-vf", f"fps=1/{args.every},{scale}", "-frames:v", str(args.max_frames), "-q:v", "4",
             os.path.join(frames_dir, "raw-%04d.jpg")], log, check=False)
        n = len(glob.glob(os.path.join(frames_dir, "raw-*.jpg")))
        return [i * args.every for i in range(n)]

    times = scene()
    if len(times) < 3:
        print(f"  só {len(times)} cena(s) — caindo para 1 frame a cada {args.every}s", file=sys.stderr)
        times = interval()

    # renomeia com índice + segundo e colapsa a detecção dupla da mesma transição
    raws = sorted(glob.glob(os.path.join(frames_dir, "raw-*.jpg")))
    kept: list[int] = []
    last = None
    for i, raw in enumerate(raws):
        ts = times[i] if i < len(times) else (kept[-1] + args.every if kept else 0)
        if last is not None and ts - last < 1:
            os.remove(raw)
            continue
        last = ts
        os.replace(raw, os.path.join(frames_dir, f"frame-{len(kept):03d}-{ts:05d}s.jpg"))
        kept.append(ts)
    return kept


# ------------------------------------------------------------------- main

def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("source", help="URL do vídeo (YouTube ou qualquer site que o yt-dlp suporte) ou arquivo local")
    ap.add_argument("--out", help="pasta de saída (padrão ./.watch/<id>)")
    ap.add_argument("--langs", default="pt,en", help="idiomas de legenda, em ordem de preferência")
    ap.add_argument("--no-frames", action="store_true", help="só transcrição, não baixa o vídeo")
    ap.add_argument("--scene", type=float, default=0.3, help="limiar de mudança de cena (menor = mais frames)")
    ap.add_argument("--every", type=int, default=10, help="intervalo do fallback, em segundos")
    ap.add_argument("--max-frames", type=int, default=60)
    ap.add_argument("--height", type=int, default=720)
    ap.add_argument("--cookies-from-browser", help="para vídeo privado/com restrição de idade")
    args = ap.parse_args()

    for tool in ("yt-dlp",) + (() if args.no_frames else ("ffmpeg",)):
        if not shutil.which(tool):
            raise SystemExit(f"{tool} não encontrado — rode scripts/setup.sh primeiro")

    langs = [l.strip() for l in args.langs.split(",") if l.strip()]
    is_file = os.path.isfile(args.source)
    vid = os.path.splitext(os.path.basename(args.source))[0] if is_file else (video_id_from(args.source) or "video")
    out = os.path.abspath(args.out or os.path.join(".watch", vid))
    os.makedirs(out, exist_ok=True)
    log = os.path.join(out, "watch.log")
    open(log, "w").close()

    info: dict = {}
    video_path = args.source if is_file else None

    if not is_file:
        print(f"[1/3] metadados + legenda de {vid}…", file=sys.stderr)
        cmd = ["yt-dlp", "--skip-download", "--write-info-json", "--write-subs", "--write-auto-subs",
               "--sub-langs", ",".join(f"{l}.*" for l in langs), "--sub-format", "vtt/srt/best",
               "--no-playlist", "--no-progress", "-o", os.path.join(out, "%(id)s.%(ext)s")]
        if args.cookies_from_browser:
            cmd += ["--cookies-from-browser", args.cookies_from_browser]
        run(cmd + [args.source], log)
        infos = glob.glob(os.path.join(out, "*.info.json"))
        if infos:
            with open(infos[0], encoding="utf-8") as fh:
                info = json.load(fh)
            os.replace(infos[0], os.path.join(out, "info.json"))
            vid = info.get("id") or vid

        if not args.no_frames:
            print("[2/3] baixando vídeo para extrair frames…", file=sys.stderr)
            cmd = ["yt-dlp", "-f", f"bv*[height<={args.height}]+ba/b[height<={args.height}]/b",
                   "--no-playlist", "--no-progress", "-o", os.path.join(out, "video.%(ext)s")]
            if args.cookies_from_browser:
                cmd += ["--cookies-from-browser", args.cookies_from_browser]
            if run(cmd + [args.source], log, check=False) == 0:
                found = glob.glob(os.path.join(out, "video.*"))
                video_path = found[0] if found else None
            else:
                print("  não consegui baixar o vídeo — seguindo só com a transcrição", file=sys.stderr)

    # transcrição
    sub_file, sub_lang = pick_subtitle(out, langs)
    transcript = group_transcript(parse_subtitles(sub_file)) if sub_file else ""
    with open(os.path.join(out, "transcript.md"), "w", encoding="utf-8") as fh:
        if transcript:
            fh.write(f"# Transcrição (legenda: {sub_lang})\n\n{transcript}\n")
        else:
            fh.write("# Transcrição\n\n_Este vídeo não tem legenda (nem automática). "
                     "Sem transcrição de terceiros por padrão — use os frames, ou transcreva "
                     "localmente com Whisper a partir do áudio._\n")

    # frames
    frame_times: list[int] = []
    if not args.no_frames and video_path:
        print("[3/3] frames por mudança de cena…", file=sys.stderr)
        frame_times = extract_frames(video_path, os.path.join(out, "frames"), args, log)
        if not is_file:
            os.remove(video_path)  # o vídeo em si não fica no disco

    # manifest
    title = info.get("title") or os.path.basename(args.source)
    lines = [f"# {title}", ""]
    meta = [("Canal", info.get("channel") or info.get("uploader")),
            ("Duração", hhmmss(info.get("duration")) if info.get("duration") else None),
            ("Publicado", info.get("upload_date")),
            ("URL", info.get("webpage_url") or (None if is_file else args.source)),
            ("Legenda", sub_lang or "nenhuma"),
            ("Frames", str(len(frame_times)) if frame_times else ("desligados" if args.no_frames else "0"))]
    lines += [f"- **{k}**: {v}" for k, v in meta if v]
    if info.get("description"):
        lines += ["", "## Descrição", "", info["description"].strip()]
    lines += ["", "## Arquivos para ler, nesta ordem", "", f"1. `{os.path.join(out, 'transcript.md')}`"]
    for i, ts in enumerate(frame_times, start=2):
        name = f"frame-{i-2:03d}-{ts:05d}s.jpg"
        lines.append(f"{i}. `{os.path.join(out, 'frames', name)}` — [{hhmmss(ts)}]")
    with open(os.path.join(out, "manifest.md"), "w", encoding="utf-8") as fh:
        fh.write("\n".join(lines) + "\n")

    print(os.path.join(out, "manifest.md"))
    return 0


if __name__ == "__main__":
    sys.exit(main())
