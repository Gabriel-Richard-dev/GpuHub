#!/usr/bin/env bash
# Smoke-test do GPUHUB: valida a plataforma ponta a ponta num comando.
# Usa tokens descartaveis (writer+viewer), roda um job REAL na GPU, e limpa tudo.
set -uo pipefail
KCX="docker exec keycloak-keycloak-1 /opt/keycloak/bin/kcadm.sh"
P=$(grep KC_BOOTSTRAP_ADMIN_PASSWORD "$HOME/GpuHub/keycloak/.env" | cut -d= -f2)
OIDC=http://127.0.0.1:8080/auth/realms/lab/protocol/openid-connect
HOST=https://gpuhub.local
RES=(--resolve gpuhub.local:443:127.0.0.1)
pass=0; fail=0; cid=""
ok(){ echo "  OK   $1"; pass=$((pass+1)); }
no(){ echo "  FAIL $1"; fail=$((fail+1)); }
warn(){ echo "  --   $1"; }
chk(){ [ "$2" = "$1" ] && ok "$3 ($2)" || no "$3 (got $2 want $1)"; }
code(){ curl -sk "${RES[@]}" -o /dev/null -w '%{http_code}' "$@"; }

cleanup(){
  for u in smokew smokev; do uid=$($KCX get users -r lab -q username=$u --fields id --format csv 2>/dev/null | tr -d '"\r'); [ -n "$uid" ] && $KCX delete "users/$uid" -r lab 2>/dev/null; done
  [ -n "$cid" ] && $KCX update "clients/$cid" -r lab -s directAccessGrantsEnabled=false 2>/dev/null
  rm -f /tmp/smokeca.crt
}
trap cleanup EXIT

echo "===================  SMOKE TEST GPUHUB  ==================="
echo "## 1. Containers"
for c in gpuhub gpuhub-caddy keycloak-keycloak-1 keycloak-kc-db-1 gpuhub-filebrowser; do
  st=$(docker inspect "$c" --format '{{.State.Status}}' 2>/dev/null || echo ausente)
  [ "$st" = running ] && ok "$c" || no "$c ($st)"
done

echo "## 2. GPU no container"
g=$(docker exec gpuhub python -c "import torch;print(torch.cuda.is_available())" 2>/dev/null | tail -1)
[ "$g" = True ] && ok "torch cuda disponivel" || no "torch cuda = $g"

echo "## 3. Keycloak"
iss=$(curl -sk "${RES[@]}" "$HOST/auth/realms/lab/.well-known/openid-configuration" 2>/dev/null | python3 -c 'import sys,json;print(json.load(sys.stdin).get("issuer",""))' 2>/dev/null)
chk "https://gpuhub.local/auth/realms/lab" "$iss" "issuer"

echo "## 4. Tokens descartaveis"
$KCX config credentials --server http://localhost:8080/auth --realm master --user admin --password "$P" >/dev/null 2>&1
cid=$($KCX get clients -r lab -q clientId=gpuhub-cli --fields id --format csv | tr -d '"\r')
$KCX update "clients/$cid" -r lab -s directAccessGrantsEnabled=true >/dev/null
mku(){ $KCX create users -r lab -s username=$1 -s enabled=true -s emailVerified=true -s email=$1@t.local -s firstName=T -s lastName=$1 >/dev/null 2>&1
  local u=$($KCX get users -r lab -q username=$1 --fields id --format csv|tr -d '"\r'); $KCX update "users/$u" -r lab -s 'requiredActions=[]' >/dev/null
  $KCX set-password -r lab --username $1 --new-password 'Smoke-throwaway' >/dev/null; [ -n "$2" ] && $KCX add-roles -r lab --uusername $1 --rolename $2 >/dev/null; }
mku smokew professor; mku smokev viewer
mint(){ curl -s -d client_id=gpuhub-cli -d grant_type=password -d username=$1 -d password='Smoke-throwaway' -d scope=openid "$OIDC/token"|python3 -c 'import sys,json;print(json.load(sys.stdin).get("access_token",""))'; }
TW=$(mint smokew); TV=$(mint smokev); [ -n "$TW" ] && ok "mint token writer" || no "mint token writer"

echo "## 5. Rotas publicas + gate (RBAC)"
chk 200 "$(code $HOST/ca.crt)"   "/ca.crt publico"
chk 200 "$(code $HOST/install)"  "/install publico"
chk 200 "$(code $HOST/gpuhub)"   "/gpuhub publico"
chk 401 "$(code $HOST/api/version)" "sem token -> 401"
chk 200 "$(code -H "Authorization: Bearer $TW" $HOST/api/version)" "writer GET -> 200"
chk 403 "$(code -X POST -H "Authorization: Bearer $TV" $HOST/api/jobs)" "viewer POST -> 403"

echo "## 6. Drive + Console (precisam do simplify-deploy)"
r=$(code $HOST/files/); case "$r" in 200|301|302) ok "/files drive ($r)";; *) warn "/files = $r (rode simplify-deploy.sh)";; esac
r=$(code $HOST/auth/admin/); case "$r" in 200|301|302) ok "/auth/admin console ($r)";; *) warn "/auth/admin = $r (rode simplify-deploy.sh)";; esac

echo "## 7. JOB REAL na GPU (writer, via gate)"
curl -sk "${RES[@]}" "$HOST/ca.crt" -o /tmp/smokeca.crt
CURL=(curl -s "${RES[@]}" --cacert /tmp/smokeca.crt -H "Authorization: Bearer $TW")
SID="smoke-$(date +%s)"
BODY=$(python3 -c "import json,sys;print(json.dumps({'entrypoint':\"python -c 'import torch,socket;print(socket.gethostname(),torch.cuda.get_device_name(0))'\",'entrypoint_num_gpus':1,'submission_id':sys.argv[1]}))" "$SID")
echo "$BODY" | "${CURL[@]}" -H "Content-Type: application/json" -X POST "$HOST/api/jobs/" -d @- >/dev/null
st=""
for i in $(seq 1 40); do st=$("${CURL[@]}" "$HOST/api/jobs/$SID" 2>/dev/null|python3 -c 'import sys,json;print(json.load(sys.stdin).get("status",""))' 2>/dev/null); case "$st" in SUCCEEDED|FAILED|STOPPED) break;; esac; sleep 3; done
log=$("${CURL[@]}" "$HOST/api/jobs/$SID/logs" 2>/dev/null|python3 -c 'import sys,json;print(json.load(sys.stdin).get("logs",""))' 2>/dev/null|tail -1)
[ "$st" = SUCCEEDED ] && ok "job rodou na GPU: $log" || no "job status=$st ($log)"

echo "## 8. Backup recente (<26h)"
latest=$(ls -1dt "$HOME"/gpuhub-backups/*/ 2>/dev/null|head -1)
if [ -n "$latest" ] && [ -f "$latest/keycloak-db.sql.gz" ]; then
  age=$(( ( $(date +%s) - $(stat -c %Y "$latest/keycloak-db.sql.gz") ) / 3600 ))
  [ "$age" -lt 26 ] && ok "backup ha ${age}h" || warn "backup antigo (${age}h)"
else no "sem backup"; fi

echo "=========================================================="
echo "RESULTADO: $pass OK, $fail FAIL"
[ "$fail" = 0 ] && echo ">>> PLATAFORMA OK <<<" || echo ">>> VEJA OS FAIL ACIMA <<<"
