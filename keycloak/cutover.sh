#!/usr/bin/env bash
# Swap do gate: basic_auth -> JWT (Keycloak). Backup + verificacao + rollback automatico.
set -uo pipefail
cd ~/GpuHub/docker
KCX="docker exec keycloak-keycloak-1 /opt/keycloak/bin/kcadm.sh"
fail=0

rollback() {
  echo "!!! ROLLBACK (restaurando basic_auth)"
  cp Caddyfile.basicauth.bak Caddyfile
  sed -i 's#image: gpuhub-caddy:jwt#image: caddy:2-alpine#' docker-compose.yml
  cp ../bin/gpuhub.basic.bak ../bin/gpuhub
  docker compose up -d --no-deps caddy 2>&1 | tail -3
  echo "rollback concluido."
}

echo "== 1. backups =="
cp Caddyfile Caddyfile.basicauth.bak && echo "  Caddyfile.basicauth.bak"
cp ../bin/gpuhub ../bin/gpuhub.basic.bak && echo "  bin/gpuhub.basic.bak"

echo "== 2. stage: Caddyfile.jwt + CLI device-flow =="
cp Caddyfile.jwt Caddyfile
cp ../bin/gpuhub.jwt ../bin/gpuhub && chmod +x ../bin/gpuhub && echo "  bin/gpuhub <- device-flow"

echo "== 3. compose -> imagem gpuhub-caddy:jwt =="
sed -i 's#image: caddy:2-alpine#image: gpuhub-caddy:jwt#' docker-compose.yml
grep -q 'image: gpuhub-caddy:jwt' docker-compose.yml && echo "  ok" || { echo "  !! sed falhou"; exit 1; }

echo "== 4. recria SO o caddy (Ray intocado) =="
docker compose up -d --no-deps caddy 2>&1 | tail -4
sleep 5

echo "== 5. token descartavel p/ testar o gate vivo =="
P=$(grep KC_BOOTSTRAP_ADMIN_PASSWORD "$HOME/GpuHub/keycloak/.env" | cut -d= -f2)
$KCX config credentials --server http://localhost:8080/auth --realm master --user admin --password "$P" >/dev/null
cid=$($KCX get clients -r lab -q clientId=gpuhub-cli --fields id --format csv | tr -d '"\r')
$KCX update "clients/$cid" -r lab -s directAccessGrantsEnabled=true >/dev/null
mku() { $KCX create users -r lab -s username=$1 -s enabled=true -s emailVerified=true -s email=$1@t.local -s firstName=T -s lastName=$1 >/dev/null 2>&1
  local u=$($KCX get users -r lab -q username=$1 --fields id --format csv | tr -d '"\r')
  $KCX update "users/$u" -r lab -s 'requiredActions=[]' >/dev/null
  $KCX set-password -r lab --username $1 --new-password 'SwapCheck-throwaway' >/dev/null
  [ -n "$2" ] && $KCX add-roles -r lab --uusername $1 --rolename $2 >/dev/null; }
mku swapw professor; mku swapv viewer
mint() { curl -s -d client_id=gpuhub-cli -d grant_type=password -d username=$1 -d password='SwapCheck-throwaway' -d scope=openid \
  http://127.0.0.1:8080/auth/realms/lab/protocol/openid-connect/token | python3 -c 'import sys,json;print(json.load(sys.stdin).get("access_token",""))'; }
TW=$(mint swapw); TV=$(mint swapv)

echo "== 6. verificacao do gate VIVO (https://gpuhub.local) =="
code() { curl -sk -o /dev/null -w '%{http_code}' --resolve gpuhub.local:443:127.0.0.1 "$@"; }
chk() { if [ "$2" = "$1" ]; then echo "  OK   $3 ($2)"; else echo "  FAIL $3 (got $2, want $1)"; fail=1; fi; }
chk 200 "$(code https://gpuhub.local/ca.crt)"            "/ca.crt publico"
chk 200 "$(code https://gpuhub.local/gpuhub)"            "/gpuhub publico"
chk 401 "$(code https://gpuhub.local/api/version)"       "sem token -> 401"
chk 200 "$(code -H "Authorization: Bearer $TW" https://gpuhub.local/api/version)" "writer GET -> 200"
chk 403 "$(code -X POST -H "Authorization: Bearer $TV" https://gpuhub.local/api/jobs)" "viewer POST -> 403"
chk 403 "$(code https://gpuhub.local/auth/admin/)"       "admin console -> 403"
iss=$(curl -sk --resolve gpuhub.local:443:127.0.0.1 https://gpuhub.local/auth/realms/lab/.well-known/openid-configuration 2>/dev/null | python3 -c 'import sys,json;print(json.load(sys.stdin).get("issuer",""))' 2>/dev/null)
chk "https://gpuhub.local/auth/realms/lab" "$iss" "/auth discovery issuer"
chk 200 "$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:8265/api/version)" "Ray :8265 saudavel"

echo "== 7. limpa tokens de teste =="
for u in swapw swapv; do uid=$($KCX get users -r lab -q username=$u --fields id --format csv 2>/dev/null | tr -d '"\r'); [ -n "$uid" ] && $KCX delete "users/$uid" -r lab 2>/dev/null; done
$KCX update "clients/$cid" -r lab -s directAccessGrantsEnabled=false >/dev/null
echo "  ok"

echo "== 8. resultado =="
if [ "$fail" = 1 ]; then rollback; echo "=== SWAP REVERTIDO (veja os FAIL acima) ==="; exit 1; else echo "=== SWAP OK: gate agora e JWT/Keycloak ==="; fi
