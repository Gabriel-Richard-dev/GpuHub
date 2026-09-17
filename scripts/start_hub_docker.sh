#!/usr/bin/env bash
# Entrypoint usado dentro do container do hub (docker/Dockerfile.hub).
set -euo pipefail

# shellcheck source=lib_hub_ip.sh
. "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/lib_hub_ip.sh"

HUB_IP="$(gpuhub_detect_ip)"

# O dashboard é a Jobs API: quem alcança essa porta submete código arbitrário,
# sem autenticação nenhuma (o Ray não tem). Por isso ela nasce em localhost e
# quem entra de fora entra pelo Caddy, que autentica. Só mexa nisso se souber
# exatamente o que está expondo.
DASHBOARD_HOST="${GPUHUB_DASHBOARD_HOST:-127.0.0.1}"

# Ray Client (ray://) é gRPC e não passa pelo proxy autenticado. ATENÇÃO: o
# Ray binda esta porta no IP do nó, NÃO em localhost — não dá pra restringir
# por flag. Quem fecha isso é o firewall (scripts/install_host.sh --firewall).
# Sem essa regra, qualquer um na rede executa código aqui sem passar pelo
# login, que é o furo que o proxy existe pra tapar. Mesma história pra 6379.
CLIENT_PORT="${GPUHUB_CLIENT_PORT:-10001}"

# Sem --num-gpus: o Ray conta as GPUs que enxerga. Fixar em 1 fazia a segunda
# GPU do dia que a máquina ganhar uma ficar invisível.
NUM_GPUS_ARG=()
if [ -n "${GPUHUB_NUM_GPUS:-}" ]; then
  NUM_GPUS_ARG=(--num-gpus="$GPUHUB_NUM_GPUS")
fi

echo "Ray head node em $HUB_IP (rodando como $(id -un), uid $(id -u))"
echo "  Jobs API:  http://$DASHBOARD_HOST:8265  (exposta pelo Caddy, não direto)"
echo "  Ray client: ray://127.0.0.1:$CLIENT_PORT  (só local/túnel)"

exec ray start --head \
  --node-ip-address="$HUB_IP" \
  --port=6379 \
  --ray-client-server-port="$CLIENT_PORT" \
  --dashboard-host="$DASHBOARD_HOST" \
  --dashboard-port=8265 \
  "${NUM_GPUS_ARG[@]}" \
  --disable-usage-stats \
  --block
