#!/bin/sh
# FASE B1 — Atualiza os icones do CRM/Sales Pipeline (static/img) para o logo 2026
# + inspecao (somente leitura) dos servers de Renovacoes e Claims para a Fase B2.
# Nenhum HTML ou manifest e alterado.
#
# Uso (no NAS): sudo sh /tmp/fase-b-crm.sh
set -e

RAW="https://raw.githubusercontent.com/sergiofarjoun-hub/assinatura/978d189/icons"
STAMP=$(date +%Y%m%d_%H%M%S)
TMP=/tmp/hamsa-icons-2026
mkdir -p "$TMP"

echo "== 1/3 Baixando icones (se ainda nao baixados) =="
for f in hamsa-192.png hamsa-512.png; do
  [ -s "$TMP/$f" ] || curl -sfL "$RAW/$f" -o "$TMP/$f" || { echo "ERRO: download de $f"; exit 1; }
  head -c 4 "$TMP/$f" | grep -q "PNG" || { echo "ERRO: $f nao e PNG valido"; exit 1; }
done
echo "   OK"

IMG="/volume1/docker/hamsa-crm/app/static/img"
echo ""
echo "== 2/3 CRM: trocando icones em static/img (com backup) =="
[ -d "$IMG" ] || { echo "ERRO: pasta nao existe: $IMG"; exit 1; }
for size in 192 512; do
  if [ -f "$IMG/icon-$size.png" ]; then
    cp "$IMG/icon-$size.png" "$IMG/icon-$size.png.bak.$STAMP"
  fi
  cp "$TMP/hamsa-$size.png" "$IMG/icon-$size.png"
  echo "   icon-$size.png atualizado (backup: .bak.$STAMP)"
done

echo ""
echo "== 3/3 Verificando =="
CODE=$(curl -s -o /dev/null -w "%{http_code}" "http://127.0.0.1:5556/static/img/icon-192.png" || echo ERR)
echo "   CRM (porta 5556) /static/img/icon-192.png -> HTTP $CODE"

echo ""
echo "===== INFO PARA A FASE B2 (somente leitura) ====="
echo "--- Renovacoes server.py: roteamento/estaticos:"
grep -nE "def do_GET|_dispatch|route|send_file|send_header|open\(|static|mimetypes|guess_type|index.html|\.png|manifest" \
  "/volume1/Sistema/RENOVACOES APP/repo/docker/app/server.py" 2>/dev/null | head -25 || echo "(nada)"
echo ""
echo "--- Renovacoes index.html: primeiras linhas do <head>:"
head -20 "/volume1/Sistema/RENOVACOES APP/repo/docker/app/index.html" 2>/dev/null || echo "(nada)"
echo ""
echo "--- Claims server.py: bloco de roteamento (linhas 505-575):"
sed -n '505,575p' "/volume1/Sistema/desktop HAMSA AI/claims-app-deploy/app/server.py" 2>/dev/null || echo "(nada)"
echo ""
echo "--- Claims index.html: primeiras linhas do <head>:"
head -20 "/volume1/Sistema/desktop HAMSA AI/claims-app-deploy/app/index.html" 2>/dev/null || echo "(nada)"
echo ""
echo "===== FASE B1 CONCLUIDA ====="
