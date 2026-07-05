#!/bin/sh
# FASE DB2 — Backup diario do hamsa-db (pg_dump formato custom, retencao 14 dias)
# Agendar no DSM: Painel de Controle -> Task Scheduler -> tarefa agendada como
# root, diaria (ex.: 02:00), comando:  sh /volume1/docker/hamsa-db/backup-db.sh
# Incluir /volume1/docker/hamsa-db/backups no Hyper Backup (o dump, nunca o data/ vivo).
set -e

BASE=/volume1/docker/hamsa-db
DEST="$BASE/backups"
KEEP_DAYS=14
STAMP=$(date +%Y%m%d_%H%M%S)
OUT="$DEST/hamsa_$STAMP.dump"

mkdir -p "$DEST"

docker exec hamsa-db pg_dump -U hamsa_admin -Fc hamsa > "$OUT"

# valida: um dump custom comeca com "PGDMP" e nao pode ser minusculo
head -c 5 "$OUT" | grep -q "PGDMP" || { echo "ERRO: dump invalido ($OUT)"; rm -f "$OUT"; exit 1; }
SIZE=$(wc -c < "$OUT")
[ "$SIZE" -gt 1024 ] || { echo "ERRO: dump suspeito de vazio ($SIZE bytes)"; exit 1; }

# retencao
find "$DEST" -name 'hamsa_*.dump' -mtime +"$KEEP_DAYS" -delete

echo "OK: $OUT ($SIZE bytes); retencao ${KEEP_DAYS}d; $(ls "$DEST" | wc -l) dump(s) em $DEST"

# Restaurar (manual):
#   sudo docker exec -i hamsa-db pg_restore -U hamsa_admin -d hamsa --clean < arquivo.dump
# Teste trimestral: restaurar em banco hamsa_teste e conferir contagens.
