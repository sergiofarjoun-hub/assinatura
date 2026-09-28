#!/bin/bash
# mount-nas-br.sh — garante que os volumes do NAS BR estejam sempre montados no Mac.
# Rodado pelo LaunchAgent com.hamsa.nasbr.mount a cada 60s e em todo login/boot.
# Se a conexão cair (NAS reiniciou, rede caiu, Mac dormiu), remonta sozinho.
#
# ── CONFIGURAÇÃO ────────────────────────────────────────────────────────────
# Endereço do NAS BR: hostname Tailscale (funciona em casa e fora).
# hamsa-br = 100.70.191.55 na tailnet Hamsa Group.
NAS_HOST="${NAS_BR_HOST:-hamsa-br}"

# Shares a manter montados (nomes exatos das pastas compartilhadas no Synology).
SHARES=("SERVER" "Pessoal")
# ────────────────────────────────────────────────────────────────────────────

LOG="$HOME/Library/Logs/nas-br-mount.log"
mkdir -p "$(dirname "$LOG")"

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >> "$LOG"; }

# Mantém o log pequeno (~500 linhas)
if [ -f "$LOG" ] && [ "$(wc -l < "$LOG")" -gt 1000 ]; then
  tail -n 500 "$LOG" > "$LOG.tmp" && mv "$LOG.tmp" "$LOG"
fi

# NAS alcançável? Testa a porta SMB (445) — o Synology pode bloquear ICMP,
# então ping não é confiável como teste de vida.
if ! nc -z -G 3 "$NAS_HOST" 445 >/dev/null 2>&1; then
  log "NAS $NAS_HOST inalcançável (SMB 445) — aguardando rede/Tailscale."
  exit 0
fi

for SHARE in "${SHARES[@]}"; do
  # Já montado? Confere pela ORIGEM (host/share), não pelo caminho em /Volumes —
  # o Finder pode montar como "share-1" se o nome estiver ocupado (ex.: share
  # homônimo de outro NAS), e a origem é o que identifica o mount de verdade.
  if mount -t smbfs | grep -qi "@${NAS_HOST}/${SHARE} "; then
    continue
  fi

  # Pasta órfã em /Volumes sem mount por trás → Finder monta como "Share-1";
  # remove se estiver vazia para manter o caminho estável.
  if [ -d "/Volumes/${SHARE}" ] && ! mount -t smbfs | grep -qi "/Volumes/${SHARE}"; then
    rmdir "/Volumes/${SHARE}" 2>/dev/null
  fi

  # Monta via Finder (usa a credencial salva no Keychain — sem senha no script)
  if osascript -e "mount volume \"smb://${NAS_HOST}/${SHARE}\"" >/dev/null 2>&1; then
    log "Montado: smb://${NAS_HOST}/${SHARE}"
  else
    log "FALHA ao montar smb://${NAS_HOST}/${SHARE} — verificar credencial no Keychain."
  fi
done
