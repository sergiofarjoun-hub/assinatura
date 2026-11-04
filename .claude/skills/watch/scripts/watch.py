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

Legenda: baixa UMA só — manual no idioma preferido; senão a automática no idioma
original do vídeo; tradução automática só quando não há original (é pior em termo
técnico). Pedir várias de uma vez (pt, pt-PT, en, en-orig) fazia o YouTube responder
429; por isso também há uma pausa antes de cada legenda (--sleep-subtitles).

Frames: por mudança de cena. Vídeo de plano único cai para intervalo fixo, e aí o
intervalo cresce o que for preciso para os --max-frames se espalharem por toda a duração
(--every é o mínimo) — antes o teto de 60 × 10 s parava nos primeiros 10 minutos. A última
imagem fica a menos de um intervalo do fim; amostragem por intervalo é assim.

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
import time

SLEEP_SUBTITLES = "6"   # segundos de pausa antes de cada legenda (sem isso o YouTube devolve 429)

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


def ffmpeg_vfr_args() -> list[str]:
    """Saída com frames em tempos irregulares: ffmpeg 5.1+ usa -fps_mode; o 4.x só conhece
    -vsync, que o ffmpeg 9 removeu ("Unrecognized option 'vsync'")."""
    try:
        help_text = subprocess.run(["ffmpeg", "-hide_banner", "-h", "full"],
                                   capture_output=True, text=True).stdout
    except OSError:
        help_text = ""
    return ["-fps_mode", "vfr"] if "-fps_mode" in help_text else ["-vsync", "vfr"]


def video_duration(path: str, info: dict) -> int | None:
    """Duração em segundos: do info.json ou, em arquivo local, do cabeçalho que o ffmpeg imprime."""
    if info.get("duration"):
        return int(float(info["duration"]))
    try:
        probe = subprocess.run(["ffmpeg", "-hide_banner", "-i", path],
                               capture_output=True, text=True).stderr
    except OSError:
        return None
    m = re.search(r"Duration: (\d+):(\d{2}):(\d{2})", probe)
    return int(m.group(1)) * 3600 + int(m.group(2)) * 60 + int(m.group(3)) if m else None


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


def subtitle_files(workdir: str) -> list[str]:
    return sorted(glob.glob(os.path.join(workdir, "*.vtt")) + glob.glob(os.path.join(workdir, "*.srt")))


def pick_subtitle(workdir: str, prefer: list[str],
                  candidates: list[str] | None = None) -> tuple[str | None, str | None]:
    """`candidates` limita a escolha às legendas desta rodada — sem isso, uma legenda de
    uma rodada anterior na mesma pasta (outro idioma) poderia ganhar da que acabou de vir.
    O yt-sync não precisa disso: ele usa uma pasta de trabalho nova por vídeo."""
    files = candidates if candidates else subtitle_files(workdir)
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


# ------------------------------------------------------ qual legenda baixar
# Mesma função do youtube-obsidian-sync/yt2vault.py (mantida em sincronia à mão).

def choose_sub_langs(info: dict, prefer: list[str]) -> list[str]:
    """Escolhe UMA legenda para pedir ao yt-dlp (chaves para --sub-langs; vazia = nenhuma).

    Cada arquivo de legenda é um pedido ao YouTube, e pedir vários de uma vez (pt, pt-PT,
    en, en-orig) rende HTTP 429. Ordem: manual no idioma preferido → manual no idioma
    original → automática do idioma ORIGINAL → tradução automática no idioma preferido
    (pior em termo técnico; só na falta de original) → qualquer uma.

    O yt-dlp nomeia as automáticas de três jeitos, conforme o cliente do YouTube que
    respondeu: 'en-orig' + 'en' + traduções 'pt'; só 'en'; ou 'en' + traduções 'pt-en'
    ("Portuguese from English"). Os três são tratados aqui.
    """
    manual = {k: v for k, v in (info.get("subtitles") or {}).items() if k != "live_chat"}
    auto = dict(info.get("automatic_captions") or {})

    def translated(table: dict, key: str) -> bool:
        return any(" from " in (t.get("name") or "") for t in table.get(key) or [])

    def find(table: dict, lang: str, originals_only: bool = False) -> str | None:
        """'pt' casa com 'pt' (exato, primeiro) ou 'pt-BR'; nunca com '-orig'."""
        lang = lang.lower()
        keys = [k for k in table if not k.lower().endswith("-orig")
                and not (originals_only and translated(table, k))]
        for k in keys:
            if k.lower() == lang:
                return k
        for k in keys:
            if k.lower().startswith(lang + "-"):
                return k
        return None

    for lang in prefer:                                   # 1. manual no idioma preferido
        k = find(manual, lang)
        if k:
            return [k]

    orig_keys = [k for k in auto if k.lower().endswith("-orig")]
    declared = (info.get("language") or "").split("-")[0].lower()
    if declared:
        # O YouTube pode listar várias faixas "-orig" (dublagens automáticas); sem isso,
        # pegávamos a primeira da lista (ordem arbitrária da API), que pode não ser o
        # idioma original de fato falado no vídeo. Prioriza a que bate com o idioma
        # declarado pelo próprio YouTube em info['language'].
        orig_keys = sorted(orig_keys, key=lambda k: k.lower()[:-5] != declared)
    orig = orig_keys[0][:-5] if orig_keys else declared
    if orig:
        k = find(manual, orig)                            # 2. manual no idioma original
        if k:
            return [k]
        if orig_keys:                                     # 3. automática do idioma original
            return [orig_keys[0]]
        k = find(auto, orig, originals_only=True)
        if k:
            return [k]
    else:
        originals = [k for k in auto if not k.lower().endswith("-orig") and not translated(auto, k)]
        if originals:                                     # 3'. original sem saber o idioma
            for lang in prefer:
                k = find({k: auto[k] for k in originals}, lang)
                if k:
                    return [k]
            return [originals[0]]

    for lang in prefer:                                   # 4. tradução automática
        k = find(auto, lang)
        if k:
            return [k]
    if manual:                                            # 5. o que houver
        return [next(iter(manual))]
    if auto:
        return [next(iter(auto))]
    return []


# ------------------------------------------------------------------ frames

def extract_frames(video: str, frames_dir: str, args, log: str,
                   duration: int | None) -> tuple[list[int], str, int]:
    """Frames por mudança de cena (primeiro frame + cada troca acima do limiar).
    Devolve (segundo de cada frame, descrição do modo, intervalo efetivo do fallback).

    Vídeo de plano único cai para intervalo fixo, e o intervalo é esticado para os
    --max-frames se espalharem por toda a duração (--every é o mínimo): com 60 frames a
    cada 10 s, um vídeo de 21 min era amostrado só até os 10 min. `ceil(duração/máximo)`
    é o menor intervalo que cabe no orçamento de frames — e portanto o que deixa a menor
    lacuna no fim, embora sempre exista uma, de até um intervalo."""
    scale = f"scale=-2:'min({args.height},ih)'"
    every = args.every
    if duration:
        every = max(every, -(-duration // args.max_frames))   # teto da divisão

    def scene() -> list[int]:
        shutil.rmtree(frames_dir, ignore_errors=True)
        os.makedirs(frames_dir)
        scene_log = os.path.join(os.path.dirname(frames_dir), "ffmpeg-scene.log")
        open(scene_log, "w").close()
        cmd = ["ffmpeg", "-nostdin", "-loglevel", "info", "-i", video,
               "-vf", f"select='eq(n\\,0)+gt(scene\\,{args.scene})',{scale},showinfo",
               *ffmpeg_vfr_args(), "-frames:v", str(args.max_frames), "-q:v", "4",
               os.path.join(frames_dir, "raw-%04d.jpg")]
        run(cmd, scene_log, check=False)
        with open(scene_log, encoding="utf-8", errors="replace") as fh:
            text = fh.read()
        if "Unrecognized option" in text or "Error splitting the argument list" in text:
            print(f"  ffmpeg recusou a linha de comando — veja {scene_log}", file=sys.stderr)
        return [int(float(x)) for x in re.findall(r"pts_time:([0-9.]+)", text)]

    def interval() -> list[int]:
        shutil.rmtree(frames_dir, ignore_errors=True)
        os.makedirs(frames_dir)
        run(["ffmpeg", "-nostdin", "-loglevel", "error", "-i", video,
             "-vf", f"fps=1/{every},{scale}", "-frames:v", str(args.max_frames), "-q:v", "4",
             os.path.join(frames_dir, "raw-%04d.jpg")], log, check=False)
        n = len(glob.glob(os.path.join(frames_dir, "raw-*.jpg")))
        return [i * every for i in range(n)]

    times = scene()
    mode = "por mudança de cena"
    if len(times) < 3:
        print(f"  só {len(times)} cena(s) — caindo para 1 frame a cada {every}s", file=sys.stderr)
        times = interval()
        mode = f"1 a cada {every}s"

    # renomeia com índice + segundo e colapsa a detecção dupla da mesma transição
    raws = sorted(glob.glob(os.path.join(frames_dir, "raw-*.jpg")))
    kept: list[int] = []
    last = None
    for i, raw in enumerate(raws):
        ts = times[i] if i < len(times) else (kept[-1] + every if kept else 0)
        if last is not None and ts - last < 1:
            os.remove(raw)
            continue
        last = ts
        os.replace(raw, os.path.join(frames_dir, f"frame-{len(kept):03d}-{ts:05d}s.jpg"))
        kept.append(ts)
    return kept, mode, every


# ------------------------------------------------------------------- main

def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("source", help="URL do vídeo (YouTube ou qualquer site que o yt-dlp suporte) ou arquivo local")
    ap.add_argument("--out", help="pasta de saída (padrão ./.watch/<id>)")
    ap.add_argument("--langs", default="pt,en",
                    help="idiomas preferidos para legenda MANUAL e para tradução automática, em ordem; "
                         "a legenda automática vem sempre no idioma original do vídeo")
    ap.add_argument("--no-frames", action="store_true", help="só transcrição, não baixa o vídeo")
    ap.add_argument("--scene", type=float, default=0.3, help="limiar de mudança de cena (menor = mais frames)")
    ap.add_argument("--every", type=int, default=10,
                    help="intervalo MÍNIMO do fallback, em segundos (cresce para os --max-frames "
                         "se espalharem por toda a duração)")
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
    fresh: list[str] = []   # legendas baixadas nesta rodada
    video_path = args.source if is_file else None

    if not is_file:
        print(f"[1/3] metadados de {vid}…", file=sys.stderr)
        base = ["yt-dlp", "--no-playlist", "--no-progress"]
        if args.cookies_from_browser:
            base += ["--cookies-from-browser", args.cookies_from_browser]
        out_tpl = ["-o", os.path.join(out, "%(id)s.%(ext)s")]
        run(base + out_tpl + ["--skip-download", "--write-info-json", args.source], log)
        info_path = os.path.join(out, "info.json")
        infos = glob.glob(os.path.join(out, "*.info.json"))
        if infos:
            with open(infos[0], encoding="utf-8") as fh:
                info = json.load(fh)
            os.replace(infos[0], info_path)
            vid = info.get("id") or vid

        # legenda: UMA só, escolhida no info.json; --load-info-json reaproveita os metadados
        # já baixados (não bate de novo na página do vídeo)
        sub_langs = choose_sub_langs(info, langs)
        if sub_langs:
            print(f"[1/3] legenda ({', '.join(sub_langs)})…", file=sys.stderr)
            cmd = base + out_tpl + ["--load-info-json", info_path, "--skip-download",
                          "--write-subs", "--write-auto-subs", "--sub-langs", ",".join(sub_langs),
                          "--sub-format", "vtt/srt/best", "--sleep-subtitles", SLEEP_SUBTITLES]
            started = time.time()
            def have_subs() -> bool:
                return bool([f for f in subtitle_files(out) if os.path.getmtime(f) >= started - 1])
            for attempt in (1, 2):
                run(cmd, log, check=False)
                if have_subs():
                    break
                if attempt == 1:
                    print("  legenda falhou — esperando 15 s e tentando de novo", file=sys.stderr)
                    time.sleep(15)
            if have_subs():
                fresh = [f for f in subtitle_files(out) if os.path.getmtime(f) >= started - 1]
            else:
                print(f"  não consegui baixar a legenda — veja {log}", file=sys.stderr)
        elif info:
            print("  vídeo sem legenda (nem automática)", file=sys.stderr)

        if not args.no_frames:
            print("[2/3] baixando vídeo para extrair frames…", file=sys.stderr)
            cmd = base + ["-f", f"bv*[height<={args.height}]+ba/b[height<={args.height}]/b",
                          "-o", os.path.join(out, "video.%(ext)s")]
            if run(cmd + [args.source], log, check=False) == 0:
                found = glob.glob(os.path.join(out, "video.*"))
                video_path = found[0] if found else None
            else:
                print("  não consegui baixar o vídeo — seguindo só com a transcrição", file=sys.stderr)

    # transcrição
    sub_file, sub_lang = pick_subtitle(out, langs, fresh)
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
    frames_mode, every_used = "", args.every
    duration = video_duration(video_path, info) if video_path else (int(info["duration"]) if info.get("duration") else None)
    if not args.no_frames and video_path:
        print("[3/3] frames por mudança de cena…", file=sys.stderr)
        frame_times, frames_mode, every_used = extract_frames(
            video_path, os.path.join(out, "frames"), args, log, duration)
        if not is_file:
            os.remove(video_path)  # o vídeo em si não fica no disco

    # manifest
    title = info.get("title") or os.path.basename(args.source)
    lines = [f"# {title}", ""]
    meta = [("Canal", info.get("channel") or info.get("uploader")),
            ("Duração", hhmmss(duration) if duration else None),
            ("Publicado", info.get("upload_date")),
            ("URL", info.get("webpage_url") or (None if is_file else args.source)),
            ("Legenda", sub_lang or "nenhuma"),
            ("Frames", f"{len(frame_times)} ({frames_mode})" if frame_times
             else ("desligados" if args.no_frames else "0"))]
    lines += [f"- **{k}**: {v}" for k, v in meta if v]
    # o aviso é para frames que param cedo DE VERDADE (cena batendo no teto). A lacuna do
    # fim de uma amostragem por intervalo é normal e vale no máximo um intervalo.
    if (frame_times and duration and len(frame_times) >= args.max_frames
            and duration - frame_times[-1] > every_used):
        lines += ["", f"> ⚠️ Teto de {args.max_frames} frames atingido em {hhmmss(frame_times[-1])} de "
                      f"{hhmmss(duration)} — o resto do vídeo ficou sem frame. Rode de novo com "
                      "`--max-frames` maior ou `--scene` maior."]
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
