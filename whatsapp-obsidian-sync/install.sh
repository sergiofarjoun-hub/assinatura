#!/bin/bash
# install.sh — instala o wa-sync no Mac: pipeline WhatsApp (backup Android) → Obsidian.
# Uso: bash install.sh
set -euo pipefail

CONF_DIR="$HOME/.wa-obsidian-sync"
PLIST_LABEL="com.hamsa.wa-sync"
PLIST_PATH="$HOME/Library/LaunchAgents/$PLIST_LABEL.plist"
LOG_PATH="$HOME/Library/Logs/wa-sync.log"
SRC_DIR="$(cd "$(dirname "$0")" && pwd)"

say() { printf '\n\033[1m%s\033[0m\n' "$*"; }

[ -f "$SRC_DIR/wa2vault.py" ] && [ -f "$SRC_DIR/wa-sync.sh" ] || {
  echo "ERRO: wa2vault.py e wa-sync.sh precisam estar na mesma pasta que este install.sh"; exit 1; }

say "1/5 Verificando Python 3 e wtsexporter..."
command -v python3 >/dev/null || { echo "ERRO: python3 não encontrado."; exit 1; }
if ! command -v wtsexporter >/dev/null; then
  echo "   Instalando whatsapp-chat-exporter (pip)..."
  python3 -m pip install --user --quiet whatsapp-chat-exporter || pip3 install --user --quiet whatsapp-chat-exporter
fi
WTS_BIN="$(command -v wtsexporter || echo "$HOME/Library/Python/$(python3 -c 'import sys;print(f"{sys.version_info[0]}.{sys.version_info[1]}")')/bin/wtsexporter")"
[ -x "$WTS_BIN" ] || { echo "ERRO: wtsexporter não instalou. Rode: pip3 install --user whatsapp-chat-exporter"; exit 1; }
echo "   OK: $WTS_BIN"

say "2/5 Configuração..."
DEFAULT_VAULT="$HOME/SERVER/BASE_CONHECIMENTO"
[ -d "$DEFAULT_VAULT/.obsidian" ] || { [ -d "$HOME/SERVER/.obsidian" ] && DEFAULT_VAULT="$HOME/SERVER"; }
read -r -p "   Vault do Obsidian [$DEFAULT_VAULT]: " VAULT_DIR
VAULT_DIR="${VAULT_DIR:-$DEFAULT_VAULT}"
[ -d "$VAULT_DIR" ] || { echo "ERRO: pasta não existe: $VAULT_DIR"; exit 1; }

read -r -p "   Pasta onde o Syncthing deposita os backups (contém msgstore*.crypt15): " BACKUP_DIR
[ -d "$BACKUP_DIR" ] || echo "   AVISO: $BACKUP_DIR ainda não existe — o sync vai esperar ela aparecer."

read -r -p "   Chave de 64 dígitos do backup criptografado (cole sem espaços): " KEY_HEX
KEY_CLEAN="$(echo "$KEY_HEX" | tr -d ' ')"
[ "${#KEY_CLEAN}" -eq 64 ] || echo "   AVISO: a chave tem ${#KEY_CLEAN} caracteres (esperado 64) — confira depois em $CONF_DIR/config.json"

read -r -p "   Arquivo .vcf de contatos para nomear as conversas (Enter para pular): " VCF

say "3/5 Instalando..."
mkdir -p "$CONF_DIR"
cp "$SRC_DIR/wa2vault.py" "$SRC_DIR/wa-sync.sh" "$CONF_DIR/"
chmod +x "$CONF_DIR/wa-sync.sh"
python3 - "$CONF_DIR/config.json" <<EOF
import json, sys
cfg = {
  "vaultDir": "$VAULT_DIR",
  "subdir": "Clientes/WhatsApp",
  "backupDir": "$BACKUP_DIR",
  "keyHex": "$KEY_CLEAN",
  "contactsVcf": "$VCF",
  "includeGroups": False,
  "minMessages": 5,
  "myName": "Sergio",
}
json.dump(cfg, open(sys.argv[1], "w"), ensure_ascii=False, indent=2)
EOF
chmod 600 "$CONF_DIR/config.json"   # contém a chave do backup — só o seu usuário lê
echo "   Instalado em $CONF_DIR (config com chmod 600)"

say "4/5 Agendando execução diária (launchd, 07:00)..."
mkdir -p "$HOME/Library/LaunchAgents" "$HOME/Library/Logs"
cat > "$PLIST_PATH" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>$PLIST_LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/zsh</string>
        <string>-lc</string>
        <string>exec "$CONF_DIR/wa-sync.sh"</string>
    </array>
    <key>StartCalendarInterval</key>
    <dict><key>Hour</key><integer>7</integer><key>Minute</key><integer>15</integer></dict>
    <key>RunAtLoad</key><false/>
    <key>StandardOutPath</key><string>$LOG_PATH</string>
    <key>StandardErrorPath</key><string>$LOG_PATH</string>
</dict>
</plist>
EOF
launchctl bootout "gui/$(id -u)/$PLIST_LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST_PATH"
echo "   Agente instalado: roda todo dia às 07:15."

say "5/5 Primeira execução (pode demorar alguns minutos na primeira vez)..."
"$CONF_DIR/wa-sync.sh" || true

say "Pronto!"
echo "  • Notas em:          $VAULT_DIR/Clientes/WhatsApp/"
echo "  • Roda sozinho:      todo dia às 07:15 (após o Syncthing trazer o backup da madrugada)"
echo "  • Log:               $LOG_PATH"
echo "  • Rodar manualmente: $CONF_DIR/wa-sync.sh"
echo "  • Desinstalar:       launchctl bootout gui/\$(id -u)/$PLIST_LABEL && rm -rf $PLIST_PATH $CONF_DIR"
