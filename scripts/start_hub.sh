#!/usr/bin/env bash
# Sobe o Ray head node (caminho bare-metal). Mantenha rodando (tmux/screen/
# systemd) — fica preso no terminal (--block).
set -euo pipefail

VENV_DIR="${GPUHUB_VENV:-$HOME/.gpuhub/venv}"
source "$VENV_DIR/bin/activate"

# shellcheck source=lib_hub_ip.sh
. "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/lib_hub_ip.sh"

HUB_IP="$(gpuhub_detect_ip)"

echo "Iniciando Ray head node em $HUB_IP ..."
echo "Ray client:    ray://$HUB_IP:10001"
echo "Ray dashboard: http://$HUB_IP:8265"
echo

exec ray start --head \
  --node-ip-address="$HUB_IP" \
  --port=6379 \
  --ray-client-server-port=10001 \
  --dashboard-host=0.0.0.0 \
  --dashboard-port=8265 \
  --num-gpus=1 \
  --disable-usage-stats \
  --block
