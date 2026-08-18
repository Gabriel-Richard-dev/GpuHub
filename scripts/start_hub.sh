#!/usr/bin/env bash
# Sobe o Ray head node e o dashboard web. Mantenha rodando (tmux/screen/systemd).
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VENV_DIR="${GPUHUB_VENV:-$HOME/.gpuhub/venv}"
DASHBOARD_PORT="${GPUHUB_DASHBOARD_PORT:-8000}"

source "$VENV_DIR/bin/activate"

HUB_IP="${GPUHUB_HOST:-$(hostname -I | awk '{print $1}')}"

cleanup() {
  echo
  echo "Encerrando ray..."
  ray stop
}
trap cleanup EXIT

echo "Iniciando Ray head node em $HUB_IP ..."
ray start --head \
  --node-ip-address="$HUB_IP" \
  --port=6379 \
  --ray-client-server-port=10001 \
  --dashboard-host=0.0.0.0 \
  --dashboard-port=8265 \
  --num-gpus=1

echo
echo "Ray client:      ray://$HUB_IP:10001"
echo "Ray dashboard:   http://$HUB_IP:8265"
echo "gpuhub dashboard http://$HUB_IP:$DASHBOARD_PORT"
echo

cd "$ROOT_DIR"
python -m uvicorn gpuhub.dashboard.server:app --host 0.0.0.0 --port "$DASHBOARD_PORT"
