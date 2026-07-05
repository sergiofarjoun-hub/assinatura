#!/bin/sh
# FASE DB0 — Inventário de armazenamento dos apps (SOMENTE LEITURA)
# Nada é alterado. A saída responde:
#   1. Onde cada app guarda dados hoje (SQLite? JSON? CSV? Postgres?)
#   2. A porta 5432 está livre no NAS?
#   3. Já existe algum Postgres em container (ex.: embutido no DocuSeal)?
# Com isso se decide a fonte da carga inicial dos mestres (Fase DB3).
#
# Uso (no NAS): sudo sh /tmp/fase-db0-inspect-storage.sh | tee /tmp/db0-resultado.txt

echo "===== FASE DB0 — inventario de dados (somente leitura) ====="
echo "data: $(date)"

echo ""
echo "== 1/4 Porta 5432 e containers =="
if netstat -tln 2>/dev/null | grep -q ':5432 '; then
  echo "   ATENCAO: a porta 5432 JA ESTA EM USO no NAS:"
  netstat -tlnp 2>/dev/null | grep ':5432 ' || netstat -tln | grep ':5432 '
else
  echo "   porta 5432 livre"
fi
echo ""
echo "   containers ativos:"
sudo docker ps --format '   {{.Names}}\t{{.Image}}\t{{.Ports}}' 2>/dev/null || echo "   (docker ps falhou)"
echo ""
echo "   imagens/containers com cara de banco (postgres/mysql/mariadb/mongo/redis):"
sudo docker ps -a --format '{{.Names}}\t{{.Image}}' 2>/dev/null \
  | grep -iE 'postgres|mysql|mariadb|mongo|redis' || echo "   (nenhum)"

# ---------------------------------------------------------------------------
# 2. Arquivos de dados por app (procura no diretorio-pai do app, prof. max 4)
# ---------------------------------------------------------------------------
inspect_app() {
  NAME="$1"; DIR="$2"
  echo ""
  echo "== $NAME =="
  echo "   dir: $DIR"
  [ -d "$DIR" ] || { echo "   (pasta nao existe — conferir caminho)"; return 0; }

  echo "   -- arquivos de dados (.db .sqlite* .json .csv .xlsx, > 1KB, top 15 por tamanho):"
  find "$DIR" -maxdepth 4 \
       \( -name '*.db' -o -name '*.sqlite' -o -name '*.sqlite3' \
          -o -name '*.json' -o -name '*.csv' -o -name '*.xlsx' \) \
       -size +1k 2>/dev/null \
    | grep -vE 'node_modules|manifest\.json|package(-lock)?\.json|tsconfig' \
    | head -15 \
    | while read -r f; do
        printf '      %8s  %s\n' "$(du -h "$f" 2>/dev/null | cut -f1)" "$f"
      done
  echo "   -- como o codigo persiste (grep em *.py):"
  grep -rniE 'sqlite3|\.db["'"'"']|json\.(load|dump)|csv\.|psycopg|sqlalchemy|POSTGRES|DATABASE_URL|open\(.*(\.json|\.csv)' \
       --include='*.py' "$DIR" 2>/dev/null \
    | grep -v '\.bak\.' | cut -c1-160 | head -12 || echo "      (nada encontrado)"
}

echo ""
echo "== 2/4 Apps =="
inspect_app "Command Center" "/volume1/Sistema/HAMSA COMMAND CENTER/repo"
inspect_app "Renovacoes"     "/volume1/Sistema/RENOVACOES APP/repo"
inspect_app "Claims"         "/volume1/Sistema/desktop HAMSA AI/claims-app-deploy"
inspect_app "Multi Calculo"  "/volume1/Sistema/MUTI CALCULO APP/repo"
inspect_app "Multi Apolices" "/volume1/Sistema/MULTI APOLICES APP/repo"
inspect_app "Pipeline (CRM)" "/volume1/docker/hamsa-crm"

echo ""
echo "== 3/4 Volumes docker com dados (top nivel de /volume1/docker) =="
ls -la /volume1/docker 2>/dev/null | head -25 || echo "   (sem acesso)"

echo ""
echo "== 4/4 Espaco em disco =="
df -h /volume1 2>/dev/null | tail -1

echo ""
echo "===== FIM DB0 — nada foi alterado ====="
echo "Proximo passo: com esta saida em maos, decidir a fonte da carga (DB3)"
echo "e rodar a Fase DB1 (fase-db1-provision.sh) se a 5432 estiver livre."
