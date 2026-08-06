#!/usr/bin/env python3
"""
wa2vault — converte o JSON do WhatsApp-Chat-Exporter em notas Markdown no vault
do Obsidian: uma nota por conversa, incremental (só reescreve o que mudou).

Uso: python3 wa2vault.py <result.json> <config.json>
Config: { "vaultDir": "...", "subdir": "Clientes/WhatsApp",
          "includeGroups": false, "minMessages": 5 }
Estado: <vault>/<subdir>/.wa-sync-state.json
"""

import json
import os
import re
import sys
import unicodedata
from datetime import datetime


def sanitize_filename(name: str) -> str:
    name = unicodedata.normalize("NFC", name or "")
    name = re.sub(r'[\\/:*?"<>|#^\[\]{}]', " ", name)
    name = re.sub(r"\s+", " ", name).strip()
    return name[:80] or "Contato"


def yaml_str(s) -> str:
    s = str(s if s is not None else "")
    s = s.replace("\\", "\\\\").replace('"', '\\"').replace("\n", " ").replace("\r", "")
    return f'"{s}"'


def phone_from_jid(jid: str) -> str:
    m = re.match(r"^(\d+)@", jid or "")
    return f"+{m.group(1)}" if m else jid or "?"


def is_group(jid: str) -> bool:
    return (jid or "").endswith("@g.us")


def render_message(msg: dict, chat_is_group: bool, my_name: str) -> str | None:
    if msg.get("meta"):
        return None  # mensagens de sistema (chamadas, mudanças de grupo…)
    ts = msg.get("timestamp") or 0
    when = datetime.fromtimestamp(ts).strftime("%H:%M") if ts else (msg.get("time") or "--:--")
    if msg.get("from_me"):
        who = my_name
    else:
        who = msg.get("sender") if chat_is_group and msg.get("sender") else "Contato"
    body = msg.get("data")
    if msg.get("media"):
        mime = msg.get("mime") or "mídia"
        caption = msg.get("caption")
        body = f"_[{mime}]_" + (f" {caption}" if caption else "")
    if not body:
        return None
    body = str(body).replace("\r\n", "\n").replace("\r", "\n")
    # continuação de linha indentada para não quebrar a lista do Markdown
    body = body.replace("\n", "\n    ")
    return f"- {when} **{who}**: {body}"


def build_note(jid: str, chat: dict, my_name: str) -> tuple[str, dict] | None:
    messages = chat.get("messages") or {}
    ordered = sorted(messages.values(), key=lambda m: m.get("timestamp") or 0)
    group = is_group(jid)
    name = chat.get("name") or phone_from_jid(jid)

    lines_by_day: dict[str, list[str]] = {}
    count = 0
    last_ts = 0
    for msg in ordered:
        line = render_message(msg, group, my_name)
        if line is None:
            continue
        ts = msg.get("timestamp") or 0
        day = datetime.fromtimestamp(ts).strftime("%Y-%m-%d") if ts else "sem-data"
        lines_by_day.setdefault(day, []).append(line)
        count += 1
        last_ts = max(last_ts, ts)

    if count == 0:
        return None

    last_str = datetime.fromtimestamp(last_ts).strftime("%Y-%m-%d %H:%M") if last_ts else "-"
    fm = [
        "---",
        f"whatsapp_jid: {yaml_str(jid)}",
        f"contato: {yaml_str(name)}",
        f"telefone: {yaml_str(phone_from_jid(jid))}",
        f"tipo: {yaml_str('grupo' if group else 'individual')}",
        f"mensagens: {count}",
        f"ultima_mensagem: {yaml_str(last_str)}",
        f"importado_em: {yaml_str(datetime.now().isoformat(timespec='seconds'))}",
        "tags:",
        "  - whatsapp",
        "---",
        "",
        f"# WhatsApp — {name}",
        "",
    ]
    body = []
    for day in sorted(lines_by_day):
        body.append(f"## {day}")
        body.extend(lines_by_day[day])
        body.append("")
    note = "\n".join(fm + body)
    meta = {"count": count, "last_ts": last_ts, "name": name}
    return note, meta


def main() -> int:
    if len(sys.argv) != 3:
        print("Uso: wa2vault.py <result.json> <config.json>", file=sys.stderr)
        return 2
    result_path, config_path = sys.argv[1], sys.argv[2]

    with open(config_path, encoding="utf-8") as f:
        config = json.load(f)
    vault_dir = config["vaultDir"]
    subdir = config.get("subdir", "Clientes/WhatsApp")
    include_groups = config.get("includeGroups", False)
    min_messages = config.get("minMessages", 5)
    my_name = config.get("myName", "Sergio")

    if not os.path.isdir(vault_dir):
        print(f"Vault indisponível ({vault_dir}) — mount do NAS fora? Tentando na próxima.")
        return 0

    with open(result_path, encoding="utf-8") as f:
        chats = json.load(f)

    target = os.path.join(vault_dir, subdir)
    os.makedirs(target, exist_ok=True)
    state_path = os.path.join(target, ".wa-sync-state.json")
    try:
        with open(state_path, encoding="utf-8") as f:
            state = json.load(f)
    except (OSError, json.JSONDecodeError):
        state = {}

    written = skipped = unchanged = 0
    used_filenames = {v.get("file") for v in state.values() if isinstance(v, dict)}
    for jid, chat in chats.items():
        if is_group(jid) and not include_groups:
            skipped += 1
            continue
        built = build_note(jid, chat, my_name)
        if built is None:
            skipped += 1
            continue
        note, meta = built
        if meta["count"] < min_messages:
            skipped += 1
            continue

        prev = state.get(jid)
        if prev and prev.get("count") == meta["count"] and prev.get("last_ts") == meta["last_ts"]:
            unchanged += 1
            continue

        if prev and prev.get("file"):
            filename = prev["file"]  # mantém o nome já usado — links do Obsidian não quebram
        else:
            base = sanitize_filename(meta["name"])
            filename = f"{base}.md"
            n = 2
            while filename in used_filenames or os.path.exists(os.path.join(target, filename)):
                filename = f"{base} ({n}).md"
                n += 1
        used_filenames.add(filename)

        tmp = os.path.join(target, f".tmp-{abs(hash(jid))}")
        with open(tmp, "w", encoding="utf-8") as f:
            f.write(note)
        os.replace(tmp, os.path.join(target, filename))
        state[jid] = {"file": filename, **meta}
        written += 1
        print(f"Atualizada: {filename} ({meta['count']} msgs)")

        tmp_state = state_path + ".tmp"
        with open(tmp_state, "w", encoding="utf-8") as f:
            json.dump(state, f, ensure_ascii=False, indent=1)
        os.replace(tmp_state, state_path)

    print(f"Concluído: {written} notas atualizadas, {unchanged} sem mudança, {skipped} ignoradas (grupos/curtas/vazias).")
    return 0


if __name__ == "__main__":
    sys.exit(main())
