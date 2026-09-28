#!/bin/bash
# Para e remove o serviço do agente (launchd).
# Uso:  bash macos/desinstalar-servico.sh
set -e
LABEL="com.hamsa.whatsapp-agent"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

launchctl unload "$PLIST" 2>/dev/null || true
rm -f "$PLIST"
echo "Serviço parado e removido. (A sessão do WhatsApp e o histórico em data/ foram mantidos.)"
