#!/usr/bin/env bash
# Sobe o drive web (Filebrowser em /files) e libera o console admin do Keycloak
# pro campus. Backup + validacao + rollback do Caddy. Nao precisa sudo (grupo docker).
set -uo pipefail
cd ~/GpuHub/docker

rollback() { echo "!!! ROLLBACK do Caddy"; cp Caddyfile.pre-drive.bak Caddyfile; docker compose up -d --no-deps caddy 2>&1 | tail -3; }

echo "== 1. volume do filebrowser gravavel pelo uid 2000 =="
docker volume create docker_fb_config >/dev/null
docker run --rm -v docker_fb_config:/c alpine chown -R 2000:2000 /c >/dev/null 2>&1 && echo "  ok"

echo "== 2. valida o Caddyfile novo =="
docker run --rm --network host -e GPUHUB_SITE_ADDRESS=gpuhub.local -e GPUHUB_TLS=internal \
  -v "$PWD/Caddyfile.jwt:/etc/caddy/Caddyfile:ro" gpuhub-caddy:jwt \
  caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile 2>&1 | grep -iE 'valid config|error' | tail -2

echo "== 3. backup + aplica Caddyfile =="
cp Caddyfile Caddyfile.pre-drive.bak
cp Caddyfile.jwt Caddyfile

echo "== 4. sobe caddy (novo) + filebrowser =="
docker compose up -d --no-deps caddy filebrowser 2>&1 | tail -6
sleep 6

echo "== 5. verificacao =="
fail=0
code() { curl -sk -o /dev/null -w '%{http_code}' --resolve gpuhub.local:443:127.0.0.1 "$@"; }
chk() { if [ "$2" = "$1" ]; then echo "  OK   $3 ($2)"; else echo "  FAIL $3 (got $2 want $1)"; fail=1; fi; }
chk 401 "$(code https://gpuhub.local/api/version)" "gate JWT ativo (sem token 401)"
r=$(code https://gpuhub.local/files/); case "$r" in 200|301|302) echo "  OK   /files responde ($r)";; *) echo "  FAIL /files ($r)"; fail=1;; esac
iss=$(curl -sk --resolve gpuhub.local:443:127.0.0.1 https://gpuhub.local/auth/realms/lab/.well-known/openid-configuration 2>/dev/null | python3 -c 'import sys,json;print(json.load(sys.stdin).get("issuer",""))' 2>/dev/null)
chk "https://gpuhub.local/auth/realms/lab" "$iss" "/auth ok"
chk 200 "$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:8265/api/version)" "Ray saudavel"

echo "== 6. resultado =="
if [ "$fail" = 1 ]; then rollback; echo "=== REVERTIDO (Caddy voltou). Veja os FAIL acima. ==="; exit 1; fi
echo "=== OK: drive /files + console admin (campus) no ar ==="
echo
echo "DRIVE:   https://gpuhub.local/files/"
echo "  senha inicial do admin do filebrowser (pegue e troque na UI):"
echo "    docker logs gpuhub-filebrowser 2>&1 | grep -i password"
echo "CONSOLE: https://gpuhub.local/auth/admin/   (realm lab; logue como gabriel)"
