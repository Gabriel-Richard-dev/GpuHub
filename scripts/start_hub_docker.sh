#!/usr/bin/env bash
# Entrypoint usado dentro do container do hub (docker/Dockerfile.hub).
set -euo pipefail

HUB_IP="${GPUHUB_HOST:-$(hostname -I | awk '{print $1}')}"

ray start --head \
  --node-ip-address="$HUB_IP" \
  --port=6379 \
  --ray-client-server-port=10001 \
  --dashboard-host=0.0.0.0 \
  --dashboard-port=8265 \
  --num-gpus=1

cd /opt/gpuhub
exec python3 -m uvicorn gpuhub.dashboard.server:app --host 0.0.0.0 --port 8000
