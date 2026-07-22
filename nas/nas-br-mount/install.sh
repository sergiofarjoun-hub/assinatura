#!/bin/bash
# install.sh — instala o auto-mount do NAS BR no Mac (rodar UMA vez, sem sudo).
# Uso: bash install.sh
set -euo pipefail
cd "$(dirname "$0")"

SCRIPTS_DIR="$HOME/Library/Scripts"
AGENTS_DIR="$HOME/Library/LaunchAgents"
PLIST="com.hamsa.nasbr.mount.plist"

mkdir -p "$SCRIPTS_DIR" "$AGENTS_DIR"

cp mount-nas-br.sh "$SCRIPTS_DIR/mount-nas-br.sh"
chmod +x "$SCRIPTS_DIR/mount-nas-br.sh"

# Ajusta o caminho do usuário atual no plist (caso não seja /Users/hamsa)
sed "s|/Users/hamsa|$HOME|g" "$PLIST" > "$AGENTS_DIR/$PLIST"

# (Re)carrega o LaunchAgent
launchctl bootout "gui/$(id -u)/com.hamsa.nasbr.mount" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$AGENTS_DIR/$PLIST"

echo "✅ Instalado. O agente roda agora e a cada 60s."
echo "   Log: ~/Library/Logs/nas-br-mount.log"
echo ""
echo "⚠️  Pré-requisito (uma vez): montar cada share manualmente pelo Finder"
echo "   (Cmd+K → smb://hamsa-br/Server e /Pessoal) marcando"
echo "   'Guardar senha nas Chaves' — o script usa essa credencial."
