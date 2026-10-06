#!/usr/bin/env bash
# Backup do GPUHUB. Guarda em ~/gpuhub-backups (ou $BACKUP_DIR), mantem os ultimos 7.
# Cron-avel:  0 2 * * *  /home/labnuven/GpuHub/scripts/backup.sh >> ~/gpuhub-backups/cron.log 2>&1
#
# Pega: Keycloak (realm+usuarios, via pg_dump), DB do filebrowser e os configs
# (compose/Caddyfiles/realm/.env). /data (datasets) so entra se BACKUP_DATA_DEST
# estiver setado (e grande; mande pra outro disco/maquina).
set -uo pipefail
TS=$(date +%Y%m%d-%H%M%S)
DIR="${BACKUP_DIR:-$HOME/gpuhub-backups}"
OUT="$DIR/$TS"
mkdir -p "$OUT"

echo "== Keycloak (Postgres) =="
if docker exec keycloak-kc-db-1 pg_dump -U keycloak keycloak 2>/dev/null | gzip > "$OUT/keycloak-db.sql.gz"; then
  echo "  ok ($(du -h "$OUT/keycloak-db.sql.gz" | cut -f1))"
else
  echo "  !! falhou o dump do Keycloak"
fi

echo "== Filebrowser DB =="
docker run --rm -v docker_fb_config:/c -v "$OUT":/out alpine sh -c 'cp /c/filebrowser.db /out/ 2>/dev/null && chown 1000:1000 /out/filebrowser.db' && [ -f "$OUT/filebrowser.db" ] && echo "  ok" || echo "  (sem db ainda)"

echo "== Configs (inclui .env com segredos) =="
tar czf "$OUT/configs.tgz" -C "$HOME/GpuHub" \
  docker/docker-compose.yml docker/Caddyfile docker/Caddyfile.jwt \
  docker/Dockerfile.hub docker/Dockerfile.caddy docker/.env docker/caddy/users.caddy \
  keycloak/docker-compose.yml keycloak/.env keycloak/realm/lab-realm.json \
  bin scripts systemd 2>/dev/null && echo "  ok ($(du -h "$OUT/configs.tgz" | cut -f1))"

chmod -R go-rwx "$OUT"   # segredos (.env): so o dono le

if [ -n "${BACKUP_DATA_DEST:-}" ]; then
  echo "== /data -> $BACKUP_DATA_DEST (rsync) =="
  rsync -a --delete /data/ "$BACKUP_DATA_DEST/" && echo "  ok"
else
  echo "== /data: pulado (defina BACKUP_DATA_DEST=/caminho ou user@host:/caminho pra incluir) =="
fi

# retencao: ultimos 7
ls -1dt "$DIR"/*/ 2>/dev/null | tail -n +8 | xargs -r rm -rf
echo "== pronto: $OUT  ($(du -sh "$OUT" | cut -f1)) =="
