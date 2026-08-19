#!/usr/bin/env bash
# Entrypoint usado dentro do container do hub (docker/Dockerfile.hub).
set -euo pipefail

HUB_IP="${GPUHUB_HOST:-$(hostname -I | awk '{print $1}')}"

exec ray start --head \
  --node-ip-address="$HUB_IP" \
  --port=6379 \
  --ray-client-server-port=10001 \
  --dashboard-host=0.0.0.0 \
  --dashboard-port=8265 \
  --num-gpus=1 \
  --block
