#!/bin/sh
# INSPECAO B2 — somente leitura: trechos exatos dos servers de Renovacoes e
# Claims para escrever os patches de rota (/manifest.json, /icon-*.png).
# Nao altera nada.
# Uso (no NAS): sudo sh /tmp/inspect-b2.sh
set -e

R="/volume1/Sistema/RENOVACOES APP/repo/docker/app/server.py"
C="/volume1/Sistema/desktop HAMSA AI/claims-app-deploy/app/server.py"

echo "===== RENOVACOES ====="
echo "--- helpers de envio (linhas 425-470):"
sed -n '425,470p' "$R"
echo ""
echo "--- inicio do _route + rota do index (linhas 495,540p):"
sed -n '495,540p' "$R"
echo ""
echo "--- fim da lista de rotas + fallthrough 404 (linhas 605,640p):"
sed -n '605,640p' "$R"
echo ""
echo "===== CLAIMS ====="
echo "--- _dispatch + tabela de rotas (linhas 440,515p):"
sed -n '440,515p' "$C"
echo ""
echo "--- helper _send_headers (procurando):"
grep -n "def _send_headers" "$C"
N=$(grep -n "def _send_headers" "$C" | head -1 | cut -d: -f1)
[ -n "$N" ] && sed -n "${N},$((N+12))p" "$C"
echo ""
echo "===== INSPECAO B2 CONCLUIDA ====="
