#!/bin/sh
# FASE B2 — PWA para RENOVACOES e CLAIMS
#  - adiciona manifest.json + icon-192/512.png em cada app
#  - adiciona rota estatica no server.py de cada um (no estilo do codigo)
#  - adiciona <link rel="manifest"> etc. no <head> de cada index.html
#  - valida sintaxe Python ANTES de reiniciar; restaura backup se falhar
#  - Renovacoes: docker restart | Claims: docker compose up -d --build
#
# Uso (no NAS): sudo sh /tmp/fase-b2-renovacoes-claims.sh
set -e

RAW="https://raw.githubusercontent.com/sergiofarjoun-hub/assinatura/978d189/icons"
STAMP=$(date +%Y%m%d_%H%M%S)
TMP=/tmp/hamsa-icons-2026
SNIP=/tmp/hamsa-b2-snips
mkdir -p "$TMP" "$SNIP"

RENOV="/volume1/Sistema/RENOVACOES APP/repo/docker/app"
CLAIMS="/volume1/Sistema/desktop HAMSA AI/claims-app-deploy/app"
CLAIMS_PROJ="/volume1/Sistema/desktop HAMSA AI/claims-app-deploy"

# util: insere o arquivo $3 depois da linha $2 do arquivo $1 (via head/tail)
splice_after() {
  FILE="$1"; LINE="$2"; SNIPPET="$3"
  head -n "$LINE" "$FILE" >  "$FILE.new"
  cat "$SNIPPET"          >> "$FILE.new"
  tail -n +"$((LINE+1))" "$FILE" >> "$FILE.new"
  mv "$FILE.new" "$FILE"
}

echo "== 0/6 Baixando icones =="
for f in hamsa-192.png hamsa-512.png; do
  [ -s "$TMP/$f" ] || curl -sfL "$RAW/$f" -o "$TMP/$f" || { echo "ERRO download $f"; exit 1; }
  head -c 4 "$TMP/$f" | grep -q "PNG" || { echo "ERRO: $f invalido"; exit 1; }
done
echo "   OK"

# ============================================================ RENOVACOES ====
echo ""
echo "== 1/6 RENOVACOES: arquivos =="
cp "$TMP/hamsa-192.png" "$RENOV/icon-192.png"
cp "$TMP/hamsa-512.png" "$RENOV/icon-512.png"
cat > "$RENOV/manifest.json" << 'EOF'
{
  "name": "HAMSA Renovações",
  "short_name": "Renovações",
  "description": "Gestão de apólices e renovações — Hamsa Group",
  "start_url": "/",
  "scope": "/",
  "id": "hamsa-renovacoes",
  "display": "standalone",
  "orientation": "any",
  "background_color": "#070d1c",
  "theme_color": "#070d1c",
  "lang": "pt-BR",
  "prefer_related_applications": false,
  "icons": [
    { "src": "/icon-192.png", "sizes": "192x192", "type": "image/png", "purpose": "any" },
    { "src": "/icon-192.png", "sizes": "192x192", "type": "image/png", "purpose": "maskable" },
    { "src": "/icon-512.png", "sizes": "512x512", "type": "image/png", "purpose": "any" },
    { "src": "/icon-512.png", "sizes": "512x512", "type": "image/png", "purpose": "maskable" }
  ]
}
EOF
echo "   manifest.json + icones OK"

echo "== 2/6 RENOVACOES: patch server.py + index.html =="
cp "$RENOV/server.py"   "$RENOV/server.py.bak.$STAMP"
cp "$RENOV/index.html"  "$RENOV/index.html.bak.$STAMP"

if grep -q "Static: PWA" "$RENOV/server.py"; then
  echo "   server.py ja tem a rota PWA, pulando"
else
  N=$(grep -n "return self\._serve_index()" "$RENOV/server.py" | head -1 | cut -d: -f1)
  [ -n "$N" ] || { echo "ERRO: ancora nao achada no server.py (renov)"; exit 1; }
  cat > "$SNIP/renov-server.txt" << 'EOF'

        # Static: PWA (manifest + icones)
        if method == "GET" and path in ("/manifest.json", "/icon-192.png", "/icon-512.png"):
            f = HERE / path.lstrip("/")
            if not f.exists():
                return self._send_error(404, f"arquivo ausente: {path}")
            ctype = "application/manifest+json" if path.endswith(".json") else "image/png"
            return self._send_bytes(f.read_bytes(), ctype)
EOF
  splice_after "$RENOV/server.py" "$N" "$SNIP/renov-server.txt"
  echo "   rota PWA inserida apos a linha $N"
fi

if grep -q 'rel="manifest"' "$RENOV/index.html"; then
  echo "   index.html ja tem manifest, pulando"
else
  N=$(grep -n 'name="viewport"' "$RENOV/index.html" | head -1 | cut -d: -f1)
  [ -n "$N" ] || { echo "ERRO: ancora viewport nao achada (renov)"; exit 1; }
  cat > "$SNIP/renov-head.txt" << 'EOF'
  <link rel="manifest" href="/manifest.json">
  <meta name="theme-color" content="#070d1c">
  <link rel="apple-touch-icon" href="/icon-192.png">
EOF
  splice_after "$RENOV/index.html" "$N" "$SNIP/renov-head.txt"
  echo "   <head> atualizado"
fi

echo "   validando sintaxe Python (dentro do container)..."
if sudo docker exec renovacoes-app python3 -c "import ast; ast.parse(open('/app/server.py',encoding='utf-8').read())"; then
  echo "   sintaxe OK -> reiniciando renovacoes-app"
  sudo docker restart renovacoes-app > /dev/null
else
  echo "   ERRO DE SINTAXE -> restaurando backups e PARANDO"
  cp "$RENOV/server.py.bak.$STAMP"  "$RENOV/server.py"
  cp "$RENOV/index.html.bak.$STAMP" "$RENOV/index.html"
  exit 1
fi

echo "== 3/6 RENOVACOES: verificando =="
sleep 4
for u in / /manifest.json /icon-192.png; do
  CODE=$(curl -s -o /dev/null -w "%{http_code}" "http://127.0.0.1:3001$u" || echo ERR)
  echo "   :3001$u -> HTTP $CODE"
done

# ================================================================ CLAIMS ====
echo ""
echo "== 4/6 CLAIMS: arquivos =="
cp "$TMP/hamsa-192.png" "$CLAIMS/icon-192.png"
cp "$TMP/hamsa-512.png" "$CLAIMS/icon-512.png"
cat > "$CLAIMS/manifest.json" << 'EOF'
{
  "name": "HAMSA Claims",
  "short_name": "Claims",
  "description": "Gestão de reembolsos e tickets — Hamsa Group",
  "start_url": "/",
  "scope": "/",
  "id": "hamsa-claims",
  "display": "standalone",
  "orientation": "any",
  "background_color": "#0b1424",
  "theme_color": "#1a56db",
  "lang": "pt-BR",
  "prefer_related_applications": false,
  "icons": [
    { "src": "/icon-192.png", "sizes": "192x192", "type": "image/png", "purpose": "any" },
    { "src": "/icon-192.png", "sizes": "192x192", "type": "image/png", "purpose": "maskable" },
    { "src": "/icon-512.png", "sizes": "512x512", "type": "image/png", "purpose": "any" },
    { "src": "/icon-512.png", "sizes": "512x512", "type": "image/png", "purpose": "maskable" }
  ]
}
EOF
echo "   manifest.json + icones OK"

echo "== 5/6 CLAIMS: patch server.py + index.html =="
cp "$CLAIMS/server.py"  "$CLAIMS/server.py.bak.$STAMP"
cp "$CLAIMS/index.html" "$CLAIMS/index.html.bak.$STAMP"

if grep -q "PWA estaticos" "$CLAIMS/server.py"; then
  echo "   server.py ja tem a rota PWA, pulando"
else
  N=$(grep -n "qs = parse_qs(parsed.query, keep_blank_values=True)" "$CLAIMS/server.py" | head -1 | cut -d: -f1)
  [ -n "$N" ] || { echo "ERRO: ancora nao achada no server.py (claims)"; exit 1; }
  cat > "$SNIP/claims-server.txt" << 'EOF'

        # PWA estaticos (manifest + icones)
        if self.command == "GET" and path in ("/manifest.json", "/icon-192.png", "/icon-512.png"):
            fp = os.path.join(APP_DIR, path.lstrip("/"))
            if os.path.exists(fp):
                with open(fp, "rb") as f:
                    body = f.read()
                mime = "application/manifest+json" if path.endswith(".json") else "image/png"
                self._send_headers(200, mime, len(body))
                self.wfile.write(body)
                return
EOF
  splice_after "$CLAIMS/server.py" "$N" "$SNIP/claims-server.txt"
  echo "   rota PWA inserida apos a linha $N"
fi

if grep -q 'rel="manifest"' "$CLAIMS/index.html"; then
  echo "   index.html ja tem manifest, pulando"
else
  N=$(grep -n 'name="viewport"' "$CLAIMS/index.html" | head -1 | cut -d: -f1)
  [ -n "$N" ] || { echo "ERRO: ancora viewport nao achada (claims)"; exit 1; }
  cat > "$SNIP/claims-head.txt" << 'EOF'
<link rel="manifest" href="/manifest.json">
<meta name="theme-color" content="#1a56db">
<link rel="apple-touch-icon" href="/icon-192.png">
EOF
  splice_after "$CLAIMS/index.html" "$N" "$SNIP/claims-head.txt"
  echo "   <head> atualizado"
fi

echo "   validando sintaxe Python (na imagem do claims)..."
if sudo docker run --rm --entrypoint python3 \
     -v "$CLAIMS/server.py:/tmp/check.py:ro" \
     claims-app-deploy-claims-app \
     -c "import ast; ast.parse(open('/tmp/check.py',encoding='utf-8').read())"; then
  echo "   sintaxe OK"
else
  echo "   ERRO DE SINTAXE -> restaurando backups e PARANDO"
  cp "$CLAIMS/server.py.bak.$STAMP"  "$CLAIMS/server.py"
  cp "$CLAIMS/index.html.bak.$STAMP" "$CLAIMS/index.html"
  exit 1
fi

echo "   rebuild do claims-app (pode levar alguns minutos)..."
cd "$CLAIMS_PROJ"
if sudo docker compose version > /dev/null 2>&1; then
  sudo docker compose up -d --build
else
  sudo docker-compose up -d --build
fi

echo "== 6/6 CLAIMS: verificando =="
sleep 6
for u in / /manifest.json /icon-192.png; do
  CODE=$(curl -s -o /dev/null -w "%{http_code}" "http://127.0.0.1:9292$u" || echo ERR)
  echo "   :9292$u -> HTTP $CODE"
done

echo ""
echo "===== FASE B2 CONCLUIDA ====="
echo "Se todos os checks acima deram 200:"
echo "  Renovações: https://hamsa-usa.taild4370d.ts.net:8443/"
echo "  Claims:     https://hamsa-usa.taild4370d.ts.net:10000/"
echo "Instalar no Android: Chrome -> menu (3 pontos) -> Instalar app"
