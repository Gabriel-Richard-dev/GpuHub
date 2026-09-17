#!/usr/bin/env bash
# Descoberta do IP de LAN do hub, compartilhada pelo caminho Docker e pelo
# bare-metal.
#
# Por que não `hostname -I | awk '{print $1}'` (o que fazíamos antes): a ordem
# dessa lista não é estável. No boot, se o Docker sobe antes da rede terminar
# de subir, o primeiro IP é o da bridge docker0 (172.17.0.1) — o Ray então
# bindava o client server nela e o hub ficava invisível pra LAN, sem erro
# nenhum no log. Aqui a gente espera a rota default existir e ignora as faixas
# de bridge do próprio Docker.

# Faixas que nunca são o IP de LAN do hub: loopback, link-local (DHCP falhou) e
# as bridges que o Docker cria (172.16/12 inteiro, pra pegar docker0 e as redes
# de compose).
_gpuhub_ip_is_lan() {
  case "$1" in
    127.*|169.254.*|172.1[6-9].*|172.2[0-9].*|172.3[01].*|"") return 1 ;;
    *) return 0 ;;
  esac
}

# Melhor sinal disponível: qual IP local o kernel usaria pra falar com a
# internet. Não envia pacote (UDP não conecta de verdade), só consulta a tabela
# de rotas — mas falha enquanto não houver rota default, que é exatamente o
# "ainda não tem rede" que a gente quer detectar.
_gpuhub_ip_via_route() {
  python - <<'PY' 2>/dev/null
import socket
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
try:
    s.connect(("1.1.1.1", 53))
    print(s.getsockname()[0])
finally:
    s.close()
PY
}

# Rede do lab pode não ter saída pra internet. Aí caímos pra lista de IPs da
# máquina, filtrando as faixas acima.
_gpuhub_ip_via_hostname() {
  for ip in $(hostname -I 2>/dev/null); do
    if _gpuhub_ip_is_lan "$ip"; then
      echo "$ip"
      return 0
    fi
  done
  return 1
}

# Ecoa o IP de LAN, esperando a rede subir. GPUHUB_HOST manda em tudo (use pra
# fixar o IP e não depender de detecção).
gpuhub_detect_ip() {
  local timeout="${GPUHUB_IP_WAIT:-120}" waited=0 ip=""

  if [ -n "${GPUHUB_HOST:-}" ]; then
    echo "$GPUHUB_HOST"
    return 0
  fi

  while [ "$waited" -lt "$timeout" ]; do
    ip="$(_gpuhub_ip_via_route)"
    _gpuhub_ip_is_lan "$ip" || ip="$(_gpuhub_ip_via_hostname)" || ip=""

    if _gpuhub_ip_is_lan "$ip"; then
      echo "$ip"
      return 0
    fi

    [ "$waited" -eq 0 ] && echo "Esperando a rede subir para descobrir o IP de LAN..." >&2
    sleep 2
    waited=$((waited + 2))
  done

  echo "Não achei um IP de LAN em ${timeout}s (só loopback/bridge do Docker)." >&2
  echo "Confira a rede da máquina, ou force com GPUHUB_HOST=<ip>." >&2
  return 1
}
