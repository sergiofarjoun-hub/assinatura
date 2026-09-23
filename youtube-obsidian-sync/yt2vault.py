#!/usr/bin/env python3
"""
yt2vault — transforma o que o yt-dlp baixou de um vídeo (metadados + legenda)
numa nota Markdown no vault do Obsidian.

Modos:
  yt2vault.py --processed <config.json>
      lista no stdout os IDs de vídeo já importados (um por linha).

  yt2vault.py --ingest <config.json> <workdir> <url>
      lê <workdir>/*.info.json + <workdir>/*.vtt|*.srt, escreve a nota,
      atualiza o estado e marca a linha do vídeo na fila.

Config: { "vaultDir": "...", "subdir": "YouTube", "queueFile": "YouTube/_fila.md" }
Estado: <vault>/<subdir>/.yt-sync-state.json
"""

import glob
import json
import shutil
import os
import re
import sys
import unicodedata
from datetime import datetime, timezone


# ---------------------------------------------------------------- utilidades

def sanitize_filename(name: str) -> str:
    name = unicodedata.normalize("NFC", name or "")
    name = re.sub(r'[\\/:*?"<>|#^\[\]{}]', " ", name)
    name = re.sub(r"\s+", " ", name).strip()
    return name[:80] or "Video"


def yaml_str(s) -> str:
    s = str(s if s is not None else "")
    s = s.replace("\\", "\\\\").replace('"', '\\"').replace("\n", " ").replace("\r", "")
    return f'"{s}"'


def video_id(url: str) -> str | None:
    """Extrai o ID de 11 caracteres de qualquer forma de URL do YouTube."""
    patterns = (
        r"(?:youtube\.com|youtube-nocookie\.com)/(?:shorts|embed|live|v)/([\w-]{11})",
        r"(?:youtube\.com)/watch\?(?:[^&]*&)*v=([\w-]{11})",
        r"youtu\.be/([\w-]{11})",
    )
    for pat in patterns:
        m = re.search(pat, url or "")
        if m:
            return m.group(1)
    m = re.fullmatch(r"[\w-]{11}", (url or "").strip())
    return m.group(0) if m else None


def hhmmss(seconds) -> str:
    try:
        total = int(float(seconds))
    except (TypeError, ValueError):
        return ""
    h, rest = divmod(total, 3600)
    m, s = divmod(rest, 60)
    return f"{h}:{m:02d}:{s:02d}" if h else f"{m}:{s:02d}"


def atomic_write(path: str, content: str) -> None:
    """Escreve via tmp + rename — nunca deixa nota pela metade no vault."""
    tmp = f"{path}.tmp.{os.getpid()}"
    with open(tmp, "w", encoding="utf-8") as fh:
        fh.write(content)
    os.replace(tmp, path)


# ------------------------------------------------------------ legenda → texto

CUE_TIME = re.compile(
    r"^(\d{1,2}:\d{2}:\d{2})[.,]\d{1,3}\s*-->\s*\d{1,2}:\d{2}:\d{2}[.,]\d{1,3}"
)
INLINE_TAG = re.compile(r"<[^>]+>")


def parse_subtitles(path: str) -> list[tuple[str, str]]:
    """
    Lê .vtt ou .srt e devolve [(timestamp, texto)] já limpo.

    As legendas automáticas do YouTube são "rolantes": cada cue repete o final
    do cue anterior. Aqui isso é desfeito — linha repetida é descartada e cue
    que só estende o anterior substitui o anterior.
    """
    with open(path, "r", encoding="utf-8", errors="replace") as fh:
        raw = fh.read()

    out: list[tuple[str, str]] = []
    current_ts = ""
    for line in raw.replace("\r\n", "\n").replace("\r", "\n").split("\n"):
        line = line.strip()
        if not line or line == "WEBVTT" or line.startswith(("NOTE", "STYLE", "Kind:", "Language:")):
            continue
        m = CUE_TIME.match(line)
        if m:
            current_ts = m.group(1)
            continue
        if re.fullmatch(r"\d+", line):   # numeração de cue do .srt
            continue
        text = INLINE_TAG.sub("", line)
        text = re.sub(r"\s+", " ", text).strip()
        if not text or text == "[Music]" or text == "[Música]":
            continue
        if out:
            prev_ts, prev = out[-1]
            if text == prev:
                continue
            if text.startswith(prev):          # cue rolante: estende o anterior
                out[-1] = (prev_ts, text)
                continue
            if prev.endswith(text):            # já contido no anterior
                continue
        out.append((current_ts or "0:00:00", text))
    return out


def pick_subtitle(workdir: str, prefer: list[str]) -> tuple[str | None, str | None]:
    """Escolhe a legenda: idiomas preferidos primeiro, manual antes de automática."""
    files = sorted(glob.glob(os.path.join(workdir, "*.vtt")) + glob.glob(os.path.join(workdir, "*.srt")))
    if not files:
        return None, None

    def lang_of(path: str) -> str:
        m = re.search(r"\.([A-Za-z-]+)\.(?:vtt|srt)$", os.path.basename(path))
        return (m.group(1) if m else "").lower()

    def rank(path: str) -> tuple[int, int]:
        lang = lang_of(path)
        pref = next((i for i, p in enumerate(prefer) if lang.startswith(p.lower())), len(prefer))
        auto = 1 if "-orig" in lang or "auto" in os.path.basename(path).lower() else 0
        return (pref, auto)

    best = min(files, key=rank)
    return best, lang_of(best)


# ---------------------------------------------------------- qual legenda baixar
# Mesma função da skill .claude/skills/watch/scripts/watch.py (mantida em sincronia à mão).
# O yt-sync.sh chama isto para pedir UMA legenda só ao yt-dlp.

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


def group_transcript(cues: list[tuple[str, str]], every_seconds: int = 30) -> str:
    """Agrupa os cues em parágrafos com marca de tempo a cada ~30s."""
    if not cues:
        return ""

    def to_seconds(ts: str) -> int:
        parts = [int(p) for p in ts.split(":")]
        while len(parts) < 3:
            parts.insert(0, 0)
        return parts[0] * 3600 + parts[1] * 60 + parts[2]

    def pretty(ts: str) -> str:
        return hhmmss(to_seconds(ts))

    blocks: list[str] = []
    chunk: list[str] = []
    chunk_start = cues[0][0]
    for ts, text in cues:
        if chunk and to_seconds(ts) - to_seconds(chunk_start) >= every_seconds:
            blocks.append(f"**[{pretty(chunk_start)}]** " + " ".join(chunk))
            chunk, chunk_start = [], ts
        chunk.append(text)
    if chunk:
        blocks.append(f"**[{pretty(chunk_start)}]** " + " ".join(chunk))
    return "\n\n".join(blocks)


# --------------------------------------------------------------------- frames

def install_frames(cfg: dict, workdir: str, vid: str) -> str:
    """
    Move os frames extraídos pelo ffmpeg para <vault>/<subdir>/_frames/<id>/ e
    devolve a seção "Frames" da nota: cada imagem embutida com sua marca de tempo.

    É isso que permite a um agente *ver* o vídeo — ele lê as imagens uma a uma.
    """
    frames = sorted(glob.glob(os.path.join(workdir, "frames", "*.jpg")))
    if not frames:
        return ""

    every = int(cfg.get("framesEvery") or 0) or 1
    dest = os.path.join(cfg["vaultDir"], cfg.get("subdir", "YouTube"), "_frames", vid)
    os.makedirs(dest, exist_ok=True)

    # O yt-sync.sh deixa em times.txt o segundo real de cada frame: no modo cena
    # vem do showinfo do ffmpeg; no intervalo fixo é i × intervalo — e o intervalo
    # pode ser maior que framesEvery (cresce para cobrir vídeo longo). Sem o
    # arquivo (rodada antiga), cai em framesEvery.
    times: list[int] = []
    times_file = os.path.join(workdir, "frames", "times.txt")
    if os.path.isfile(times_file):
        with open(times_file, "r", encoding="utf-8") as fh:
            for line in fh:
                try:
                    times.append(int(float(line.strip())))
                except ValueError:
                    continue

    # Uma mesma transição costuma disparar dois frames seguidos; guardar os dois
    # só polui a nota. Mantém o primeiro de cada janela de `min_gap` segundos.
    min_gap = int(cfg.get("frameMinGap", 1))

    lines: list[str] = []
    kept = 0
    last_ts: int | None = None
    for i, src in enumerate(frames):
        ts = times[i] if i < len(times) else i * every
        if last_ts is not None and ts - last_ts < min_gap:
            continue
        last_ts = ts
        # O índice no nome garante unicidade mesmo com dois frames no mesmo segundo.
        name = f"{vid}-{kept:03d}-{ts:05d}.jpg"
        shutil.copy2(src, os.path.join(dest, name))
        lines.append(f"**[{hhmmss(ts)}]**")
        lines.append(f"![[_frames/{vid}/{name}]]")
        lines.append("")
        kept += 1
    return "\n".join(lines).rstrip()


# ------------------------------------------------------------------- estado

def state_path(cfg: dict) -> str:
    return os.path.join(cfg["vaultDir"], cfg.get("subdir", "YouTube"), ".yt-sync-state.json")


def load_state(cfg: dict) -> dict:
    try:
        with open(state_path(cfg), "r", encoding="utf-8") as fh:
            return json.load(fh)
    except (FileNotFoundError, json.JSONDecodeError):
        return {"videos": {}}


def save_state(cfg: dict, state: dict) -> None:
    path = state_path(cfg)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    atomic_write(path, json.dumps(state, ensure_ascii=False, indent=2))


# --------------------------------------------------------------------- fila

def mark_queue_done(cfg: dict, url: str, note_name: str) -> None:
    """Marca a linha da fila como feita, apontando para a nota gerada."""
    rel = cfg.get("queueFile")
    if not rel:
        return
    path = os.path.join(cfg["vaultDir"], rel)
    if not os.path.isfile(path):
        return
    vid = video_id(url)
    with open(path, "r", encoding="utf-8") as fh:
        lines = fh.read().split("\n")

    changed = False
    for i, line in enumerate(lines):
        if vid and vid in line and "[[" not in line:
            lines[i] = f"- [x] [[{note_name}]]"
            changed = True
    if changed:
        atomic_write(path, "\n".join(lines))


# ------------------------------------------------------------------ ingestão

def build_note(info: dict, transcript: str, sub_lang: str | None, cfg: dict,
               frames_section: str = "") -> tuple[str, str]:
    vid = info.get("id") or "?"
    title = info.get("title") or vid
    channel = info.get("channel") or info.get("uploader") or ""
    url = info.get("webpage_url") or f"https://www.youtube.com/watch?v={vid}"
    upload = info.get("upload_date") or ""
    if re.fullmatch(r"\d{8}", upload):
        upload = f"{upload[:4]}-{upload[4:6]}-{upload[6:]}"
    duration = hhmmss(info.get("duration"))
    description = (info.get("description") or "").strip()

    note_name = f"{upload or datetime.now().strftime('%Y-%m-%d')} - {sanitize_filename(title)} ({vid})"

    n_frames = frames_section.count("![[")
    tags = ["youtube"] + [t for t in cfg.get("extraTags", []) if t]
    front = [
        "---",
        f"youtube_id: {yaml_str(vid)}",
        f"title: {yaml_str(title)}",
        f"canal: {yaml_str(channel)}",
        f"url: {yaml_str(url)}",
        f"publicado: {yaml_str(upload)}",
        f"duracao: {yaml_str(duration)}",
        f"legenda: {yaml_str(sub_lang or 'nenhuma')}",
        f"frames: {n_frames}",
        f"importado: {yaml_str(datetime.now(timezone.utc).astimezone().strftime('%Y-%m-%d %H:%M'))}",
        "tags:",
    ]
    front += [f"  - {t}" for t in tags]
    front.append("---")

    body = [f"# {title}", "", f"[Assistir no YouTube]({url})" + (f" · {channel}" if channel else "")]
    if description:
        body += ["", "## Descrição", "", description]
    body += ["", "## Transcrição", ""]
    body.append(transcript if transcript else
                "_Sem legenda disponível. Para transcrever, configure `whisperCmd` no config._")
    if frames_section:
        body += ["", "## Frames", "", frames_section]
    return note_name, "\n".join(front) + "\n\n" + "\n".join(body) + "\n"


def ingest(cfg: dict, workdir: str, url: str) -> int:
    infos = glob.glob(os.path.join(workdir, "*.info.json"))
    if not infos:
        print(f"ERRO: yt-dlp não gerou .info.json em {workdir}", file=sys.stderr)
        return 1
    with open(infos[0], "r", encoding="utf-8") as fh:
        info = json.load(fh)

    prefer = cfg.get("subLangs", ["pt", "en"])
    sub_file, sub_lang = pick_subtitle(workdir, prefer)
    transcript = group_transcript(parse_subtitles(sub_file)) if sub_file else ""

    vid = info.get("id") or video_id(url) or "video"
    frames_section = install_frames(cfg, workdir, vid)
    note_name, content = build_note(info, transcript, sub_lang, cfg, frames_section)
    folder = os.path.join(cfg["vaultDir"], cfg.get("subdir", "YouTube"))
    os.makedirs(folder, exist_ok=True)
    atomic_write(os.path.join(folder, f"{note_name}.md"), content)

    state = load_state(cfg)
    state.setdefault("videos", {})[vid] = {
        "note": note_name,
        "url": url,
        "importado": datetime.now().strftime("%Y-%m-%d %H:%M"),
        "legenda": sub_lang or "nenhuma",
        "frames": frames_section.count("![["),
    }
    save_state(cfg, state)
    mark_queue_done(cfg, url, note_name)

    print(f"nota: {note_name}.md (legenda: {sub_lang or 'nenhuma'}, "
          f"frames: {frames_section.count('![[')})")
    return 0


def main() -> int:
    if len(sys.argv) < 3:
        print(__doc__, file=sys.stderr)
        return 2
    mode, config_path = sys.argv[1], sys.argv[2]
    with open(config_path, "r", encoding="utf-8") as fh:
        cfg = json.load(fh)

    if mode == "--processed":
        for vid in load_state(cfg).get("videos", {}):
            print(vid)
        return 0
    if mode == "--ingest":
        if len(sys.argv) < 5:
            print("uso: yt2vault.py --ingest <config> <workdir> <url>", file=sys.stderr)
            return 2
        return ingest(cfg, sys.argv[3], sys.argv[4])

    print(f"modo desconhecido: {mode}", file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main())
