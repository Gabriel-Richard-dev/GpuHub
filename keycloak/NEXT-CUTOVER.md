# Cutover do login: basic_auth -> Keycloak (device-flow + JWT)

Escrito em 2026-10-05. Tudo abaixo está **staged e verificado**, mas o gate vivo
ainda é `basic_auth` — o cutover (que tem blip de `:443` e risco de lockout) foi
deixado pra uma sessão com alguém por perto.

## Já pronto e verificado (nada disso está ligado no hub vivo)

- **Keycloak 26.8 + Postgres** rodando em `~/GpuHub/keycloak/` (compose), só em
  `127.0.0.1:8080` (fora da LAN, fora do ufw). Realm `lab` importado:
  - client `gpuhub-cli` (público, **device-flow**; ROPC/standard OFF)
  - audience mapper -> `gpuhub-api`; papéis `admin/professor/pesquisador/viewer`
    em `realm_access.roles`
  - **issuer** confirmado: `https://gpuhub.local/auth/realms/lab`
  - admin bootstrap em `~/GpuHub/keycloak/.env` (temporário — trocar no cutover)
- **Imagem** `gpuhub-caddy:jwt` (Caddy 2.11.6 + `ggicci/caddy-jwt`) buildada.
  Confere: `docker run --rm gpuhub-caddy:jwt caddy list-modules | grep jwt`
- **`docker/Caddyfile.jwt`**: gate JWT + papel por método (viewer só GET;
  escrita POST/PUT/DELETE/PATCH exige executor; `PUT /api/packages` = upload).
  Já passou `caddy validate` com JWKS alcançável.
- Pré-flight OK: `8080` livre, volume `docker_caddy_data` é **nomeado** (a CA
  interna sobrevive ao swap), caddy e gpuhub são containers separados, Ray
  `127.0.0.1:8265/api/version` -> 200. Relógio ~9s do real (dentro da tolerância;
  NTP do chrony não alcança os servidores — o campus bloqueia; resolver com um
  NTP interno quando der, não bloqueia).

## Runbook do cutover (ordem segura; cada passo verificável)

**0. Reprovar o relógio e o Ray**
```
ssh labnuven@10.50.21.14 'curl -s -o/dev/null -w "ray %{http_code}\n" http://127.0.0.1:8265/api/version; date -u'
```

**1. (offline, zero impacto) provar o gate num Caddy descartável**
Subir `gpuhub-caddy:jwt` numa porta alta com um upstream falso (`respond 200`),
mintar tokens de teste (criar user+role via kcadm; ROPC num client throwaway) e
confirmar: sem token -> 401; viewer POST -> 403; executor POST -> 200; sem
papel -> 403. Apagar o client/users de teste depois.

**2. criar os usuários reais no Keycloak** (dentro do container, senha temporária)
```
P=$(grep KC_BOOTSTRAP_ADMIN_PASSWORD ~/GpuHub/keycloak/.env | cut -d= -f2)
docker exec keycloak-keycloak-1 /opt/keycloak/bin/kcadm.sh config credentials \
  --server http://localhost:8080/auth --realm master --user admin --password "$P"
docker exec keycloak-keycloak-1 /opt/keycloak/bin/kcadm.sh create users -r lab \
  -s username=gabriel -s enabled=true
docker exec keycloak-keycloak-1 /opt/keycloak/bin/kcadm.sh set-password -r lab \
  --username gabriel --new-password 'TROCAR' --temporary
docker exec keycloak-keycloak-1 /opt/keycloak/bin/kcadm.sh add-roles -r lab \
  --uusername gabriel --rolename admin
```
Papéis (ajustar depois sem downtime): gabriel=admin; resto=pesquisador; definir
professor(es) e viewer(s).

**3. escrever o CLI device-flow** (`bin/gpuhub`) — trocar Basic por Bearer:
`login` = device grant (RFC 8628, curl+jq contra `.../auth/realms/lab/...`),
guarda access+refresh, renova por comando. `submit`/`queue`/`logs`/`stop` mandam
`Authorization: Bearer`. Referência pronta no design (device flow) + manter a
lógica de working-dir/size-warning/requirements.txt do CLI atual.

**4. expor `/auth` no Caddy ATUAL** (ainda basic_auth) — 1 restart
Adicionar `handle /auth/* { reverse_proxy 127.0.0.1:8080 }` antes do catch-all,
`docker compose -f docker/docker-compose.yml up -d --no-deps caddy`. Verificar:
`curl -sk https://gpuhub.local/auth/realms/lab/.well-known/openid-configuration`
-> issuer certo; hub ainda exige basic_auth.

**5. PRÉ-VALIDAR o token (antes de trocar o gate)**
Usuário roda `gpuhub login` (device-flow) com o hub AINDA em basic_auth; decodar
o access token e conferir: `iss`==issuer_whitelist, `aud` tem `gpuhub-api`,
`realm_access.roles` tem o papel, `alg`=RS256. Se não bater, corrigir o KC AQUI.

**6. O SWAP (basic_auth -> jwt)** — backup + rollback prontos
```
cd ~/GpuHub/docker
cp Caddyfile Caddyfile.basicauth.bak
# apontar o service caddy pra build: Dockerfile.caddy (em vez de image: caddy:2-alpine)
# e montar Caddyfile.jwt como /etc/caddy/Caddyfile
docker compose up -d --build --no-deps caddy    # NUNCA 'up' geral (recria o Ray!)
```
Reusa o volume `docker_caddy_data` (CA intacta). Verificar na hora:
(a) sem token -> 401; (b) token executor -> 200; (c) token viewer -> 403 no POST;
(d) Ray `127.0.0.1:8265/api/version` -> 200; (e) `gpuhub submit` sobe working-dir
e o log streama.
**Rollback (1 comando):** voltar o service pra `image: caddy:2-alpine` +
`Caddyfile.basicauth.bak`, `docker compose up -d --no-deps caddy`. As credenciais
basic_auth do gabriel seguem válidas até você removê-las no passo 7.

**7. finalizar (só campus)** — depois de um dia de uso Bearer OK
Remover basic_auth do fluxo, **exportar o realm + backup do volume Postgres do KC**
(users foram criados por kcadm; `--import-realm` não recria), trocar o admin
bootstrap por um admin real e remover `KC_BOOTSTRAP_ADMIN_*` do compose. **NÃO**
mexer no ufw (segue campus-only).

## Roadmap p/ PÚBLICO (decisão tomada: público com hardening completo)

NO-GO pra internet até existir (os verificadores foram categóricos):
1. **KC em host separado** — move pro VPS (`gabrielrichard.dev`), não no hub-RCE.
2. **Segmentar egress** do hub — job (host-networking) não pode pivotar pra
   `10.50.0.0/16`.
3. **Isolamento entre jobs** — hoje todos = uid 2000, `/data` compartilhado, sem
   cota. O mais difícil (Ray Jobs não tem multi-tenancy).
4. Entrada pública = **VPS-front** (público -> VPS -> hub pelo tailnet), hub nunca
   exposto direto. DNS `gpuhub.gabrielrichard.dev` + Let's Encrypt no VPS.
   Caddyfile: trocar site p/ o DNS, tirar `tls internal`, pôr `email`; atualizar
   `issuer_whitelist` e `KC_HOSTNAME`; restringir `/auth/admin` e realm master à
   rede interna; rate-limit (caddy-ratelimit) + brute-force do Keycloak.
