#!/bin/bash
# Instala o agente como serviço do macOS (launchd), para rodar 24h em segundo
# plano, iniciar no login e reiniciar sozinho se cair.
#
# Uso:  bash macos/instalar-servico.sh   (a partir da pasta whatsapp-agent)
set -e

DIR="$(cd "$(dirname "$0")/.." && pwd)"      # .../whatsapp-agent
NODE="$(command -v node || true)"
LABEL="com.hamsa.whatsapp-agent"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

echo "== Instalando serviço do Assistente Hamsa =="
[ -n "$NODE" ] || { echo "ERRO: 'node' não encontrado no PATH. Instale o Node (https://nodejs.org)."; exit 1; }
[ -f "$DIR/.env" ] || { echo "ERRO: falta $DIR/.env — copie de .env.example e preencha a ANTHROPIC_API_KEY."; exit 1; }
[ -d "$DIR/node_modules" ] || { echo "ERRO: dependências não instaladas. Rode 'npm install' antes."; exit 1; }

mkdir -p "$HOME/Library/LaunchAgents" "$DIR/data"

cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>$NODE</string>
    <string>src/index.js</string>
  </array>
  <key>WorkingDirectory</key><string>$DIR</string>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ThrottleInterval</key><integer>10</integer>
  <key>StandardOutPath</key><string>$DIR/data/agent.log</string>
  <key>StandardErrorPath</key><string>$DIR/data/agent.log</string>
  <key>ProcessType</key><string>Background</string>
</dict>
</plist>
EOF

launchctl unload "$PLIST" 2>/dev/null || true
launchctl load "$PLIST"

echo "OK. Serviço instalado e iniciado."
echo "  Ver logs:      tail -f \"$DIR/data/agent.log\""
echo "  Parar:         launchctl unload \"$PLIST\""
echo "  Iniciar:       launchctl load \"$PLIST\""
echo "  Desinstalar:   bash macos/desinstalar-servico.sh"
