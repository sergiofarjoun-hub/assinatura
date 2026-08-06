#!/bin/bash
# install.sh — instala o plaud-sync no Mac: script + agente launchd de hora em hora.
# Uso: bash install.sh [caminho-do-vault]
set -euo pipefail

INSTALL_DIR="$HOME/.plaud-obsidian-sync"
PLIST_LABEL="com.hamsa.plaud-sync"
PLIST_PATH="$HOME/Library/LaunchAgents/$PLIST_LABEL.plist"
LOG_PATH="$HOME/Library/Logs/plaud-sync.log"
SCRIPT_SRC="$(cd "$(dirname "$0")" && pwd)/plaud-sync.mjs"

say() { printf '\n\033[1m%s\033[0m\n' "$*"; }

[ -f "$SCRIPT_SRC" ] || { echo "ERRO: plaud-sync.mjs precisa estar na mesma pasta que este install.sh"; exit 1; }

# 1. Node ≥ 18 (fetch nativo)
say "1/6 Verificando Node.js..."
NODE_BIN="$(command -v node || true)"
if [ -z "$NODE_BIN" ]; then
  # launchd não herda o PATH do shell; procura nos lugares comuns
  for c in /opt/homebrew/bin/node /usr/local/bin/node "$HOME/.nvm/versions/node/"*/bin/node; do
    [ -x "$c" ] && NODE_BIN="$c" && break
  done
fi
[ -n "$NODE_BIN" ] || { echo "ERRO: Node.js não encontrado. Instale via https://nodejs.org e rode de novo."; exit 1; }
NODE_MAJOR="$("$NODE_BIN" -e 'console.log(process.versions.node.split(".")[0])')"
[ "$NODE_MAJOR" -ge 18 ] || { echo "ERRO: Node $NODE_MAJOR é antigo demais (precisa de 18+)."; exit 1; }
echo "   Node encontrado: $NODE_BIN (v$("$NODE_BIN" -v | tr -d v))"

# 2. Vault
say "2/6 Localizando o vault do Obsidian..."
VAULT_DIR="${1:-}"
if [ -z "$VAULT_DIR" ]; then
  for c in "$HOME/SERVER/BASE_CONHECIMENTO" "$HOME/SERVER"; do
    if [ -d "$c/.obsidian" ]; then VAULT_DIR="$c"; break; fi
  done
fi
if [ -z "$VAULT_DIR" ]; then
  read -r -p "   Caminho do vault (ex: $HOME/SERVER/BASE_CONHECIMENTO): " VAULT_DIR
fi
[ -d "$VAULT_DIR" ] || { echo "ERRO: pasta não existe: $VAULT_DIR (o mount do NAS está ativo?)"; exit 1; }
[ -d "$VAULT_DIR/.obsidian" ] || echo "   AVISO: $VAULT_DIR não tem pasta .obsidian — confirme que é o vault certo."
echo "   Vault: $VAULT_DIR (notas irão para: $VAULT_DIR/Plaud/)"

# 3. Login no Plaud CLI (gera ~/.plaud/tokens.json, renovado automaticamente depois)
say "3/6 Verificando login no Plaud..."
if [ ! -f "$HOME/.plaud/tokens.json" ]; then
  echo "   Sem login ainda — abrindo o navegador para autorizar (clique em Authorize)..."
  npx -y @plaud-ai/cli@latest login
fi
[ -f "$HOME/.plaud/tokens.json" ] || { echo "ERRO: login não concluído. Rode 'npx -y @plaud-ai/cli login' e repita o install."; exit 1; }
echo "   Login OK."

# 4. Instala o script e a config
say "4/6 Instalando o script..."
mkdir -p "$INSTALL_DIR"
cp "$SCRIPT_SRC" "$INSTALL_DIR/plaud-sync.mjs"
if [ ! -f "$INSTALL_DIR/config.json" ]; then
  cat > "$INSTALL_DIR/config.json" <<EOF
{
  "vaultDir": "$VAULT_DIR",
  "subdir": "Plaud",
  "firstRunDays": 30
}
EOF
else
  echo "   config.json já existe — mantido como está."
fi
echo "   Instalado em $INSTALL_DIR"

# 5. Agente launchd (roda de hora em hora + ao fazer login no Mac)
say "5/6 Agendando execução de hora em hora (launchd)..."
mkdir -p "$HOME/Library/LaunchAgents" "$HOME/Library/Logs"
cat > "$PLIST_PATH" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>$PLIST_LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>$NODE_BIN</string>
        <string>$INSTALL_DIR/plaud-sync.mjs</string>
    </array>
    <key>StartInterval</key><integer>3600</integer>
    <key>RunAtLoad</key><true/>
    <key>StandardOutPath</key><string>$LOG_PATH</string>
    <key>StandardErrorPath</key><string>$LOG_PATH</string>
</dict>
</plist>
EOF
launchctl bootout "gui/$(id -u)/$PLIST_LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST_PATH"
echo "   Agente instalado: $PLIST_PATH"

# 6. Primeira sincronização, na sua frente
say "6/6 Rodando a primeira sincronização (últimos 30 dias)..."
"$NODE_BIN" "$INSTALL_DIR/plaud-sync.mjs" --verbose || true

say "Pronto!"
echo "  • Notas em:            $VAULT_DIR/Plaud/"
echo "  • Roda sozinho:        a cada 1h e sempre que você logar no Mac"
echo "  • Log:                 $LOG_PATH"
echo "  • Rodar manualmente:   node $INSTALL_DIR/plaud-sync.mjs --verbose"
echo "  • Desinstalar:         launchctl bootout gui/\$(id -u)/$PLIST_LABEL && rm -rf $PLIST_PATH $INSTALL_DIR"
