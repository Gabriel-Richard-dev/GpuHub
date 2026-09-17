#!/usr/bin/env bash
# A parte do setup que precisa de root. Roda uma vez, é idempotente, e faz só
# o que está listado aqui:
#
#   1. cria o grupo `gpuhub` e põe quem você listar nele e no grupo `docker`
#      (hoje só o labnuven opera o hub — se ele não estiver por perto, ninguém
#      reinicia nada)
#   2. dá a /mnt/pesquisa um dono que o container não-root consegue escrever
#   3. instala o serviço systemd, pro hub subir no boot na ordem certa
#   4. faz o avahi anunciar só a interface da LAN (senão ele entrega o IP da
#      bridge do Docker pra quem procurar gpuhub.local na rede)
#   5. com --firewall: libera 443 pra faixa do campus e fecha as portas do Ray
#
# Uso:
#   sudo ./scripts/install_host.sh [--users alice,bob] [--firewall [FAIXA]] [--iface enp6s0]
set -euo pipefail

[ "$(id -u)" = 0 ] || { echo "rode com sudo." >&2; exit 1; }

REPO_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
GPUHUB_UID=2000            # igual ao ARG GPUHUB_UID do Dockerfile.hub
USERS=""
DO_FIREWALL=0
SUBNET="10.50.0.0/16"      # faixa do campus; ajuste se a sua for outra
IFACE=""

while [ $# -gt 0 ]; do
  case "$1" in
    --users)    USERS="${2:-}"; shift 2 ;;
    --iface)    IFACE="${2:-}"; shift 2 ;;
    --firewall) DO_FIREWALL=1
                case "${2:-}" in -*|"") shift ;; *) SUBNET="$2"; shift 2 ;; esac ;;
    *) echo "argumento desconhecido: $1" >&2; exit 1 ;;
  esac
done

echo "== 1. grupo gpuhub e operadores =="
getent group gpuhub >/dev/null || { groupadd gpuhub; echo "grupo gpuhub criado"; }
if [ -n "$USERS" ]; then
  for u in ${USERS//,/ }; do
    if ! id "$u" &>/dev/null; then echo "  ! usuário '$u' não existe, pulando"; continue; fi
    usermod -aG gpuhub,docker "$u"
    echo "  $u -> grupos gpuhub, docker (precisa deslogar e logar pra valer)"
  done
else
  echo "  (nenhum --users passado; membros atuais: $(getent group gpuhub | cut -d: -f4))"
fi

echo "== 2. /mnt/pesquisa gravável pelo container =="
# O container roda como uid 2000. Sem isso, todo job que tenta salvar
# checkpoint em /mnt/pesquisa morre com Permission denied.
mkdir -p /mnt/pesquisa
chown -R "${GPUHUB_UID}:gpuhub" /mnt/pesquisa
chmod 2775 /mnt/pesquisa      # setgid: o que for criado lá dentro nasce do grupo
echo "  /mnt/pesquisa -> uid ${GPUHUB_UID}, grupo gpuhub, setgid"

echo "== 3. serviço systemd =="
sed "s|__REPO_DIR__|${REPO_DIR}|g" "$REPO_DIR/systemd/gpuhub.service" > /etc/systemd/system/gpuhub.service
systemctl daemon-reload
systemctl enable gpuhub.service >/dev/null
echo "  gpuhub.service instalado e habilitado (aponta pra $REPO_DIR)"
echo "  use: systemctl start|stop|status gpuhub"

echo "== 4. avahi só na interface da LAN =="
if [ -z "$IFACE" ]; then
  IFACE="$(ip route show default | awk '{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1); exit}')"
fi
if [ -n "$IFACE" ] && [ -f /etc/avahi/avahi-daemon.conf ]; then
  # Sem isto o avahi anuncia TODAS as interfaces, inclusive a docker0, e quem
  # procura gpuhub.local na rede pode receber 172.17.0.1 — inalcançável.
  if grep -q '^allow-interfaces=' /etc/avahi/avahi-daemon.conf; then
    sed -i "s|^allow-interfaces=.*|allow-interfaces=${IFACE}|" /etc/avahi/avahi-daemon.conf
  else
    sed -i "s|^\[server\]|[server]\nallow-interfaces=${IFACE}|" /etc/avahi/avahi-daemon.conf
  fi
  systemctl restart avahi-daemon
  echo "  avahi anuncia só $IFACE"
else
  echo "  ! não achei a interface ou o avahi; pulando"
fi

if [ "$DO_FIREWALL" = 1 ]; then
  echo "== 5. firewall =="
  command -v ufw >/dev/null || { echo "  ! ufw não instalado, pulando"; exit 0; }
  echo "  Regras ANTES:"; ufw status | sed 's/^/    /'
  echo
  echo "  Vou aplicar:"
  echo "    ufw allow from $SUBNET to any port 443 proto tcp   (entrada do hub)"
  echo "    ufw deny 6379/tcp    (Ray GCS — sem autenticação)"
  echo "    ufw deny 8265/tcp    (Jobs API — sem autenticação)"
  echo "    ufw deny 10001/tcp   (Ray Client — sem autenticação)"
  echo
  echo "  NÃO mexo nas políticas padrão nem em SSH/AnyDesk de propósito:"
  echo "  mudar default deny numa máquina acessada remotamente tranca você do lado de fora."
  printf "  Confirma? [s/N] "
  read -r ans
  case "$ans" in
    s|S|y|Y)
      ufw allow from "$SUBNET" to any port 443 proto tcp
      # O Ray já nasce em 127.0.0.1, menos o GCS (6379) que escuta em *.
      # Regra explícita porque "está em localhost" é configuração, não garantia.
      ufw deny 6379/tcp
      ufw deny 8265/tcp
      ufw deny 10001/tcp
      echo "  Regras DEPOIS:"; ufw status | sed 's/^/    /'
      ;;
    *) echo "  pulado." ;;
  esac
else
  echo "== 5. firewall: pulado (rode de novo com --firewall pra aplicar) =="
fi

echo
echo "Pronto. Próximo passo: criar as contas do pessoal."
echo "  $REPO_DIR/scripts/gpuhub-user.sh add <nome>"
