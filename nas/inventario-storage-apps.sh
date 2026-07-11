#!/bin/sh
# INVENTÁRIO — onde cada app guarda dados hoje (SOMENTE LEITURA)
# Subsídio para as fases de import/sync do banco unificado (ver ARQUITETURA.md):
# antes de importar clientes/apólices para cadastro.* e comissoes.*, é preciso
# saber a fonte em cada app (SQLite? JSON? CSV? Postgres?).
# Nada é alterado. A saída responde:
#   1. Onde cada app persiste dados hoje
#   2. Quem ocupa a porta 5432 (esperado: hamsa-comissoes-db, se a fase 0 de
#      Comissões já rodou — nas/comissoes-fase0.sh)
#   3. Que outros bancos em container existem no NAS (ex.: o do DocuSeal)
#
# Uso (no NAS): sudo sh /tmp/inventario-storage-apps.sh | tee /tmp/inventario-resultado.txt

echo "===== INVENTÁRIO de storage dos apps (somente leitura) ====="
echo "data: $(date)"

echo ""
echo "== 1/4 Porta 5432 e containers =="
if netstat -tln 2>/dev/null | grep -q ':5432 '; then
  echo "   porta 5432 em uso (esperado se hamsa-comissoes-db ja subiu):"
  netstat -tlnp 2>/dev/null | grep ':5432 ' || netstat -tln | grep ':5432 '
else
  echo "   porta 5432 livre (fase 0 de Comissoes ainda nao rodou)"
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
echo "===== FIM — nada foi alterado ====="
echo "Com esta saida em maos: planejar o import/sync de cada modulo"
echo "(cadastro.pessoa/cliente, comissoes.apolice — ver ARQUITETURA.md)."
