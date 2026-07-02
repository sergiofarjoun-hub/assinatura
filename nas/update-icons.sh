#!/bin/sh
# FASE A — Atualiza os ícones PWA para o logo 2026 (hamsa dourado sobre navy)
# Apps: Command Center, Multi Cálculo, Multi Apólices
# (esses 3 já têm manifest.json + links no HTML de uma fase anterior;
#  este script SÓ troca os arquivos icon-192.png / icon-512.png, com backup.
#  Nenhum HTML ou manifest é alterado.)
#
# Uso (no NAS): sudo sh /tmp/update-icons.sh
set -e   # protocolo Hamsa: 1 falha -> parar

# ícones pinados no commit 978d189 (imutável)
RAW="https://raw.githubusercontent.com/sergiofarjoun-hub/assinatura/978d189/icons"
STAMP=$(date +%Y%m%d_%H%M%S)
TMP=/tmp/hamsa-icons-2026
mkdir -p "$TMP"

echo "== 1/3 Baixando icones novos do GitHub =="
for f in hamsa-192.png hamsa-512.png; do
  curl -sfL "$RAW/$f" -o "$TMP/$f" || { echo "ERRO: falha no download de $f"; exit 1; }
done
for f in hamsa-192.png hamsa-512.png; do
  # valida assinatura PNG e tamanho minimo
  head -c 4 "$TMP/$f" | grep -q "PNG" || { echo "ERRO: $f nao e PNG valido"; exit 1; }
  SIZE=$(wc -c < "$TMP/$f")
  [ "$SIZE" -gt 5000 ] || { echo "ERRO: $f muito pequeno ($SIZE bytes)"; exit 1; }
done
echo "   OK: 2 icones baixados e validados"

update_icons() {
  APPDIR="$1"; NAME="$2"
  echo ""
  echo "== $NAME =="
  [ -d "$APPDIR" ] || { echo "ERRO: pasta nao existe: $APPDIR"; exit 1; }
  for size in 192 512; do
    if [ -f "$APPDIR/icon-$size.png" ]; then
      cp "$APPDIR/icon-$size.png" "$APPDIR/icon-$size.png.bak.$STAMP"
    fi
    cp "$TMP/hamsa-$size.png" "$APPDIR/icon-$size.png"
    echo "   icon-$size.png atualizado (backup: icon-$size.png.bak.$STAMP)"
  done
}

echo ""
echo "== 2/3 Atualizando icones (com backup) =="
update_icons "/volume1/Sistema/HAMSA COMMAND CENTER/repo/docker/app" "Command Center"
update_icons "/volume1/Sistema/MUTI CALCULO APP/repo/docker/app"     "Multi Calculo"
update_icons "/volume1/Sistema/MULTI APOLICES APP/repo/docker/app"   "Multi Apolices"

echo ""
echo "== 3/3 Verificando que os apps servem o icone novo =="
for entry in "CommandCenter:4000" "MultiCalculo:9191" "MultiApolices:8080"; do
  NAME=${entry%%:*}; PORT=${entry##*:}
  CODE=$(curl -s -o /dev/null -w "%{http_code}" "http://127.0.0.1:$PORT/icon-192.png" || echo "ERR")
  echo "   $NAME (porta $PORT) /icon-192.png -> HTTP $CODE"
done

echo ""
echo "===== INFO PARA A FASE B (somente leitura, nada alterado) ====="
echo "--- CRM static/manifest.json:"
cat "/volume1/docker/hamsa-crm/app/static/manifest.json" 2>/dev/null || echo "(nao encontrado)"
echo ""
echo "--- CRM static/img:"
ls "/volume1/docker/hamsa-crm/app/static/img" 2>/dev/null || echo "(vazio)"
echo ""
echo "--- CRM base.html (links de manifest/icone):"
grep -niE "manifest|apple-touch|theme-color|icon" "/volume1/docker/hamsa-crm/app/templates/base.html" 2>/dev/null | head -10 || echo "(nada)"
echo ""
echo "--- Renovacoes: quem escuta na 3001 (para saber se serve estaticos):"
grep -rlnE "3001" --include="*.py" "/volume1/Sistema/RENOVACOES APP/repo/docker/app" 2>/dev/null | head -3 || echo "(nao achei)"
echo ""
echo "--- Claims server.py (como serve estaticos):"
grep -nE "route|send_file|static|index.html|SimpleHTTP|do_GET|guess_type" "/volume1/Sistema/desktop HAMSA AI/claims-app-deploy/app/server.py" 2>/dev/null | head -15 || echo "(nada)"
echo ""
echo "===== FASE A CONCLUIDA ====="
