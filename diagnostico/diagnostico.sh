#!/usr/bin/env bash
#
# Diagnostico do site da Katy (http://192.168.1.147:8082)
# Uso:
#   ./diagnostico.sh                      -> usa IP 192.168.1.147 e porta 8082
#   ./diagnostico.sh 192.168.1.147 8082   -> informa IP e porta manualmente
#
# Rode este script de DENTRO da rede local. Se rodar no PROPRIO servidor
# (192.168.1.147), ele tambem checa o servico/porta localmente.

set -u

HOST="${1:-192.168.1.147}"
PORT="${2:-8082}"
URL="http://${HOST}:${PORT}/"

linha() { printf '%s\n' "------------------------------------------------------------"; }
titulo() { linha; printf '>> %s\n' "$1"; linha; }

printf '\n=== DIAGNOSTICO: %s ===\n' "$URL"
printf 'Data: %s\n' "$(date)"
printf 'Rodando em: %s (%s)\n\n' "$(hostname 2>/dev/null || echo '?')" "$(uname -a 2>/dev/null || echo '?')"

titulo "1) Ping (a maquina responde na rede?)"
if command -v ping >/dev/null 2>&1; then
  ping -c 4 "$HOST" || echo "[!] Ping falhou ou foi bloqueado (ICMP pode estar desativado)."
else
  echo "[!] comando 'ping' nao encontrado."
fi
echo

titulo "2) A porta ${PORT} esta aberta? (teste de conexao TCP)"
if command -v nc >/dev/null 2>&1; then
  nc -zv -w 5 "$HOST" "$PORT" 2>&1 || echo "[!] Porta ${PORT} nao respondeu."
elif command -v curl >/dev/null 2>&1; then
  curl -sS -m 8 -o /dev/null -w "Conexao HTTP: %{http_code} em %{time_total}s\n" "$URL" \
    || echo "[!] Nao foi possivel conectar em ${URL}"
else
  echo "[!] Nem 'nc' nem 'curl' disponiveis para testar a porta."
fi
echo

titulo "3) Resposta HTTP do site"
if command -v curl >/dev/null 2>&1; then
  curl -sS -m 10 -D - -o /dev/null "$URL" 2>&1 \
    || echo "[!] Sem resposta HTTP de ${URL}"
else
  echo "[!] 'curl' nao encontrado, pulando teste HTTP."
fi
echo

# --- Checagens locais: so fazem sentido se este script roda NO servidor ---
titulo "4) [Somente se rodando NO servidor] Quem escuta na porta ${PORT}?"
if command -v ss >/dev/null 2>&1; then
  ss -tlnp 2>/dev/null | grep -E ":${PORT}\b" || echo "[!] Nada escutando na porta ${PORT} (ou sem permissao - tente com sudo)."
elif command -v netstat >/dev/null 2>&1; then
  netstat -tlnp 2>/dev/null | grep -E ":${PORT}\b" || echo "[!] Nada escutando na porta ${PORT}."
else
  echo "[!] 'ss'/'netstat' nao encontrados."
fi
echo

titulo "5) [Somente se rodando NO servidor] Containers Docker"
if command -v docker >/dev/null 2>&1; then
  echo "--- Containers ativos ---"
  docker ps 2>&1 || echo "[!] Falha ao listar (precisa de permissao/sudo?)."
  echo
  echo "--- Containers parados (possivel causa da queda) ---"
  docker ps -a --filter "status=exited" 2>&1 || true
else
  echo "[i] Docker nao instalado nesta maquina (ou nao e onde o site roda)."
fi
echo

titulo "6) [Somente se rodando NO servidor] Uso de disco e memoria"
echo "--- Disco ---"
df -h 2>/dev/null | grep -vE 'tmpfs|udev' || echo "[!] df indisponivel."
echo
echo "--- Memoria ---"
free -h 2>/dev/null || echo "[i] 'free' indisponivel (normal no macOS)."
echo

titulo "FIM"
echo "Copie TODA a saida acima e envie de volta para analise."
