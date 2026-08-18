#!/usr/bin/env bash
# Setup de uma máquina de dev do laboratório: cria um venv com o gpuhub já
# instalado e configurado com o IP do hub, sem precisar mexer em .env depois.
#
# Uso: ./setup_dev.sh <ip-do-hub>
set -euo pipefail

HUB_ADDRESS="${1:-}"
if [ -z "$HUB_ADDRESS" ]; then
  echo "uso: $0 <ip-do-hub>" >&2
  exit 1
fi

VENV_DIR="$HOME/.gpuhub-venv"

python3.10 -m venv "$VENV_DIR"
source "$VENV_DIR/bin/activate"
pip install --upgrade pip -q
pip install -q "git+https://github.com/Gabriel-Richard-dev/GpuHub.git"

cat >> "$VENV_DIR/bin/activate" <<EOF

export GPUHUB_TARGET=hub
export GPUHUB_ADDRESS=$HUB_ADDRESS
EOF

echo
echo "Pronto. Pra usar, em qualquer terminal novo:"
echo "  source $VENV_DIR/bin/activate"
echo "  python seu_treino.py"
