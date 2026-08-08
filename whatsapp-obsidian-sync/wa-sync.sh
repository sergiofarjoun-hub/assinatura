#!/bin/bash
# wa-sync — orquestra: backup crypt15 mais novo → wtsexporter (JSON) → wa2vault → vault.
# Roda via launchd 1x/dia. Só trabalha se houver backup novo desde a última execução.
set -euo pipefail

CONF_DIR="$HOME/.wa-obsidian-sync"
CONFIG="$CONF_DIR/config.json"
STAMP="$CONF_DIR/last-backup.stamp"
WORK="$CONF_DIR/work"
LOG_PREFIX="[$(date '+%Y-%m-%dT%H:%M:%S')]"

[ -f "$CONFIG" ] || { echo "$LOG_PREFIX Config não encontrada em $CONFIG. Rode o install.sh."; exit 2; }

py() { /usr/bin/env python3 -c "import json,sys;print(json.load(open('$CONFIG'))$1)"; }
BACKUP_DIR="$(py "['backupDir']")"
KEY_HEX="$(py "['keyHex']")"
VAULT_DIR="$(py "['vaultDir']")"
VCF="$(py ".get('contactsVcf','')")"

# mounts fora do ar → sai quieto, tenta amanhã
[ -d "$BACKUP_DIR" ] || { echo "$LOG_PREFIX Pasta de backup indisponível ($BACKUP_DIR) — mount fora? O backup do celular já subiu?"; exit 0; }
[ -d "$VAULT_DIR" ] || { echo "$LOG_PREFIX Vault indisponível ($VAULT_DIR) — mount fora?"; exit 0; }

# backup mais recente (o WhatsApp mantém msgstore.db.crypt15 + datados)
NEWEST="$(ls -t "$BACKUP_DIR"/msgstore*.crypt15 2>/dev/null | head -1 || true)"
[ -n "$NEWEST" ] || { echo "$LOG_PREFIX Nenhum msgstore*.crypt15 em $BACKUP_DIR ainda."; exit 0; }

SIG="$(stat -f '%N %m %z' "$NEWEST" 2>/dev/null || stat -c '%n %Y %s' "$NEWEST")"
if [ -f "$STAMP" ] && [ "$(cat "$STAMP")" = "$SIG" ]; then
  echo "$LOG_PREFIX Backup inalterado desde a última execução — nada a fazer."
  exit 0
fi

echo "$LOG_PREFIX Backup novo: $NEWEST"
rm -rf "$WORK" && mkdir -p "$WORK"

EXTRA=()
if [ -n "$VCF" ] && [ -f "$VCF" ]; then
  EXTRA+=(--enrich-from-vcards "$VCF" --default-country-code 55)
fi

# descriptografa e exporta JSON (sem HTML); tudo em pasta de trabalho local
(
  cd "$WORK"
  wtsexporter -a -b "$NEWEST" -k "$KEY_HEX" --json result.json --no-html \
    --avoid-encoding-json --dont-filter-empty "${EXTRA[@]}" >wtsexporter.log 2>&1
) || { echo "$LOG_PREFIX ERRO no wtsexporter — veja $WORK/wtsexporter.log (chave certa?)"; exit 1; }

[ -f "$WORK/result.json" ] || { echo "$LOG_PREFIX wtsexporter não gerou result.json"; exit 1; }

python3 "$CONF_DIR/wa2vault.py" "$WORK/result.json" "$CONFIG"

# sucesso: registra assinatura do backup processado e apaga o material descriptografado
echo "$SIG" > "$STAMP"
rm -rf "$WORK"
echo "$LOG_PREFIX Sync WhatsApp concluído."
