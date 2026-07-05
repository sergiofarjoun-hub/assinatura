#!/bin/sh
# FASE DB1 — Provisiona o PostgreSQL unificado (hamsa-db) no NAS
#  - cria /volume1/docker/hamsa-db (compose + data + backups)
#  - sobe postgres:16-alpine como hamsa-db, porta 5432, restart unless-stopped
#  - aplica nas/db/schema-core.sql (schema core + schemas dos apps)
#  - cria 1 papel por app (senha propria, leitura em core + escrita no proprio
#    schema) e grava tudo em credenciais.txt (chmod 600)
#  - verifica com pg_isready + contagem de tabelas
# NAO toca em nenhum app existente.
#
# Uso (no NAS):
#   1. copiar este script E o schema-core.sql para /tmp
#   2. sudo sh /tmp/fase-db1-provision.sh
set -e   # protocolo Hamsa: 1 falha -> parar

BASE=/volume1/docker/hamsa-db
STAMP=$(date +%Y%m%d_%H%M%S)
PGIMAGE=postgres:16-alpine
RAW="https://raw.githubusercontent.com/sergiofarjoun-hub/assinatura/main/nas/db"

# senha aleatoria (32 hex) sem depender de openssl
genpw() { head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n'; }

dcompose() {
  if sudo docker compose version > /dev/null 2>&1; then
    (cd "$BASE" && sudo docker compose "$@")
  else
    (cd "$BASE" && sudo docker-compose "$@")
  fi
}

echo "== 1/7 Pre-checks =="
sudo docker version > /dev/null 2>&1 || { echo "ERRO: docker indisponivel"; exit 1; }
if sudo docker ps -a --format '{{.Names}}' | grep -qx 'hamsa-db'; then
  echo "ERRO: container hamsa-db ja existe. Este script e so para o primeiro provisionamento."
  echo "      (para reaplicar o schema: sudo docker exec -i hamsa-db psql -U hamsa_admin -d hamsa < schema-core.sql)"
  exit 1
fi
if netstat -tln 2>/dev/null | grep -q ':5432 '; then
  echo "ERRO: porta 5432 ja em uso no NAS (rodar a Fase DB0 para ver quem e)"; exit 1
fi
echo "   OK: docker disponivel, 5432 livre, hamsa-db inexistente"

echo ""
echo "== 2/7 Schema SQL =="
SCHEMA=/tmp/schema-core.sql
if [ -s "$(dirname "$0")/schema-core.sql" ]; then
  SCHEMA="$(dirname "$0")/schema-core.sql"
elif [ ! -s "$SCHEMA" ]; then
  echo "   baixando schema do GitHub..."
  curl -sfL "$RAW/schema-core.sql" -o "$SCHEMA" || { echo "ERRO: schema-core.sql nao encontrado (copie para /tmp)"; exit 1; }
fi
grep -q "CREATE SCHEMA IF NOT EXISTS core" "$SCHEMA" || { echo "ERRO: $SCHEMA nao parece ser o schema core"; exit 1; }
echo "   usando: $SCHEMA"

echo ""
echo "== 3/7 Estrutura em $BASE =="
sudo mkdir -p "$BASE/data" "$BASE/backups"
ADMIN_PW=$(genpw)
umask 077
cat << EOF | sudo tee "$BASE/.env" > /dev/null
POSTGRES_PASSWORD=$ADMIN_PW
EOF
sudo chmod 600 "$BASE/.env"

cat << 'EOF' | sudo tee "$BASE/compose.yml" > /dev/null
services:
  hamsa-db:
    image: postgres:16-alpine
    container_name: hamsa-db
    restart: unless-stopped
    ports:
      - "5432:5432"          # LAN/tailnet apenas (NAS nao exposto a internet)
    environment:
      POSTGRES_DB: hamsa
      POSTGRES_USER: hamsa_admin
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD}
      TZ: America/Sao_Paulo
      PGTZ: America/Sao_Paulo
    volumes:
      - ./data:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U hamsa_admin -d hamsa"]
      interval: 10s
      timeout: 5s
      retries: 6
EOF
echo "   compose.yml + .env (600) escritos"

echo ""
echo "== 4/7 Subindo o container =="
sudo docker pull "$PGIMAGE" > /dev/null
dcompose up -d
echo -n "   aguardando o postgres ficar pronto"
i=0
until sudo docker exec hamsa-db pg_isready -U hamsa_admin -d hamsa > /dev/null 2>&1; do
  i=$((i+1)); [ $i -le 30 ] || { echo ""; echo "ERRO: postgres nao ficou pronto em 60s"; sudo docker logs --tail 30 hamsa-db; exit 1; }
  echo -n "."; sleep 2
done
echo " OK"

echo ""
echo "== 5/7 Aplicando schema =="
sudo docker exec -i hamsa-db psql -v ON_ERROR_STOP=1 -U hamsa_admin -d hamsa < "$SCHEMA"
echo "   schema aplicado"

echo ""
echo "== 6/7 Papeis por app + credenciais =="
CRED="$BASE/credenciais.txt"
{
  echo "# hamsa-db — credenciais geradas em $STAMP (NAO commitar, NAO compartilhar entre apps)"
  echo "# host: 100.94.13.31  porta: 5432  banco: hamsa"
  echo ""
  echo "admin: hamsa_admin / $ADMIN_PW"
  echo "  dsn: postgresql://hamsa_admin:$ADMIN_PW@100.94.13.31:5432/hamsa"
} | sudo tee "$CRED" > /dev/null
sudo chmod 600 "$CRED"

for APP in renovacoes claims pipeline multicalculo multiapolices commandcenter; do
  PW=$(genpw)
  sudo docker exec hamsa-db psql -v ON_ERROR_STOP=1 -U hamsa_admin -d hamsa -q << EOF
CREATE ROLE app_$APP LOGIN PASSWORD '$PW';
-- leitura nos mestres (escrita em core vem so na fase DB4, de forma deliberada)
GRANT USAGE ON SCHEMA core TO app_$APP;
GRANT SELECT ON ALL TABLES IN SCHEMA core TO app_$APP;
ALTER DEFAULT PRIVILEGES IN SCHEMA core GRANT SELECT ON TABLES TO app_$APP;
-- dono do proprio schema
ALTER SCHEMA $APP OWNER TO app_$APP;
EOF
  {
    echo ""
    echo "app_$APP: $PW"
    echo "  dsn: postgresql://app_$APP:$PW@100.94.13.31:5432/hamsa"
  } | sudo tee -a "$CRED" > /dev/null
  echo "   app_$APP criado (leitura em core, dono do schema $APP)"
done
echo "   credenciais em $CRED (chmod 600)"

echo ""
echo "== 7/7 Verificando =="
sudo docker exec hamsa-db pg_isready -U hamsa_admin -d hamsa
NTAB=$(sudo docker exec hamsa-db psql -U hamsa_admin -d hamsa -tAc \
  "SELECT count(*) FROM information_schema.tables WHERE table_schema='core'")
echo "   tabelas em core: $NTAB (esperado: 5)"
[ "$NTAB" = "5" ] || { echo "ERRO: contagem inesperada de tabelas"; exit 1; }
sudo docker exec hamsa-db psql -U hamsa_admin -d hamsa -c "\dn" | sed 's/^/   /'

echo ""
echo "===== FASE DB1 CONCLUIDA ====="
echo "1. Ver credenciais:   sudo cat $CRED"
echo "2. Testar de um app:  psql 'postgresql://app_renovacoes:SENHA@100.94.13.31:5432/hamsa' -c 'SELECT 1'"
echo "3. AGENDAR O BACKUP (Fase DB2) antes de por dado de verdade:"
echo "   copiar backup-db.sh para $BASE e agendar no DSM Task Scheduler (root, diario 02:00)"
