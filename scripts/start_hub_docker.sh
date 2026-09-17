#!/usr/bin/env bash
# Entrypoint usado dentro do container do hub (docker/Dockerfile.hub).
set -euo pipefail

# shellcheck source=lib_hub_ip.sh
. "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/lib_hub_ip.sh"

HUB_IP="$(gpuhub_detect_ip)"

echo "Ray head node em $HUB_IP"
echo "  Ray client:    ray://$HUB_IP:10001"
echo "  Ray dashboard: http://$HUB_IP:8265"

exec ray start --head \
  --node-ip-address="$HUB_IP" \
  --port=6379 \
  --ray-client-server-port=10001 \
  --dashboard-host=0.0.0.0 \
  --dashboard-port=8265 \
  --num-gpus=1 \
  --disable-usage-stats \
  --block
