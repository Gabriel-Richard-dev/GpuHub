#!/usr/bin/env bash
# Contas do hub. Cada pessoa tem a sua: é o que permite saber quem está com a
# GPU e tirar o acesso de quem sai do lab sem trocar a senha de todo mundo.
#
#   ./scripts/gpuhub-user.sh add <nome> [senha]
#   ./scripts/gpuhub-user.sh remove <nome>
#   ./scripts/gpuhub-user.sh list
#
# A senha só aparece uma vez, na criação: o que fica guardado é o hash bcrypt.
# Perdeu, roda `add` de novo com o mesmo nome — sobrescreve.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
USERS_FILE="$REPO_DIR/docker/caddy/users.caddy"
COMPOSE=(docker compose -f "$REPO_DIR/docker/docker-compose.yml")
HEADER='# Contas do hub. Gerado por scripts/gpuhub-user.sh — nao edite na mao.'

usage() { sed -n '2,12p' "${BASH_SOURCE[0]}" | sed 's/^# \?//' >&2; exit 1; }

# O Caddy sobe com `admin off`, então não dá pra recarregar pela API — e não
# vale abrir a API de admin só por isso. Reiniciar o proxy leva ~1s e não
# encosta no Ray: job em andamento não cai.
reload_proxy() {
  if "${COMPOSE[@]}" ps --status running --services 2>/dev/null | grep -qx caddy; then
    echo "Reiniciando o proxy pra aplicar..."
    "${COMPOSE[@]}" restart caddy >/dev/null
  else
    echo "Proxy não está rodando — vai valer quando ele subir."
  fi
}

ensure_file() {
  [ -f "$USERS_FILE" ] || { mkdir -p "$(dirname "$USERS_FILE")"; printf '%s\n' "$HEADER" > "$USERS_FILE"; }
}

cmd_add() {
  local name="${1:-}" pass="${2:-}"
  [ -n "$name" ] || usage
  # O nome vai pro Caddyfile e pro log de acesso; corta injeção e confusão.
  if ! [[ "$name" =~ ^[a-z][a-z0-9._-]{1,31}$ ]]; then
    echo "Nome inválido: use minúsculas, 2-32 chars, começando por letra." >&2
    exit 1
  fi
  if [ -z "$pass" ]; then
    pass="$(openssl rand -base64 18 | tr -d '/+=' | cut -c1-20)"
    local generated=1
  fi

  echo "Gerando hash..."
  local hash
  hash="$(docker run --rm caddy:2-alpine caddy hash-password --plaintext "$pass")"

  ensure_file
  local tmp
  tmp="$(mktemp)"
  grep -v -E "^[[:space:]]*${name}[[:space:]]" "$USERS_FILE" > "$tmp" || true
  printf '%s %s\n' "$name" "$hash" >> "$tmp"
  mv "$tmp" "$USERS_FILE"
  chmod 600 "$USERS_FILE"

  reload_proxy
  echo
  echo "Conta '$name' criada."
  if [ "${generated:-0}" = 1 ]; then
    echo "  senha: $pass"
    echo "  (aparece só agora — passe pra pessoa por canal privado)"
  fi
  echo
  echo "Ela configura a máquina dela com:"
  echo "  gpuhub login $name"
}

cmd_remove() {
  local name="${1:-}"
  [ -n "$name" ] || usage
  ensure_file
  if ! grep -q -E "^[[:space:]]*${name}[[:space:]]" "$USERS_FILE"; then
    echo "Conta '$name' não existe." >&2
    exit 1
  fi
  local tmp
  tmp="$(mktemp)"
  grep -v -E "^[[:space:]]*${name}[[:space:]]" "$USERS_FILE" > "$tmp" || true
  mv "$tmp" "$USERS_FILE"
  chmod 600 "$USERS_FILE"
  reload_proxy
  echo "Conta '$name' removida."
}

cmd_list() {
  ensure_file
  local n
  n="$(grep -c -E '^[a-z]' "$USERS_FILE" || true)"
  if [ "$n" = 0 ]; then
    echo "Nenhuma conta ainda. Crie com: $0 add <nome>"
    return
  fi
  echo "Contas com acesso ao hub ($n):"
  awk '/^[a-z]/ {print "  " $1}' "$USERS_FILE"
}

case "${1:-}" in
  add)    shift; cmd_add "$@" ;;
  remove) shift; cmd_remove "$@" ;;
  list)   shift; cmd_list "$@" ;;
  *)      usage ;;
esac
