#!/usr/bin/env bash
# Setup único do ambiente do hub (caminho bare-metal, sem Docker): cria venv
# e instala o Ray + a stack do vigia-ia-lab.
#
# Usa Python fixo (via uv) pelo mesmo motivo do Dockerfile.hub: o Ray Client
# exige a mesma versão major.minor dos dois lados. PY_VERSION segue o
# requires-python do vigia-ia-lab (fonte da verdade) — mantenha igual ao
# PY_VERSION de docker/Dockerfile.hub.
set -euo pipefail

PY_VERSION="3.11"
VENV_DIR="${GPUHUB_VENV:-$HOME/.gpuhub/venv}"

echo "== gpuhub: setup do hub =="

if ! command -v nvidia-smi &>/dev/null; then
  echo "nvidia-smi não encontrado. Instale os drivers da NVIDIA antes de continuar." >&2
  exit 1
fi
nvidia-smi --query-gpu=name,memory.total --format=csv,noheader

if ! command -v uv &>/dev/null; then
  export PATH="$HOME/.local/bin:$PATH"
fi
if ! command -v uv &>/dev/null; then
  echo "uv não encontrado, instalando (curl | sh, sem sudo)..."
  curl -LsSf https://astral.sh/uv/install.sh | sh
  export PATH="$HOME/.local/bin:$PATH"
fi

echo "Criando venv em $VENV_DIR com Python $PY_VERSION ..."
(cd "$HOME" && uv venv --python "$PY_VERSION" "$VENV_DIR")
uv pip install --python "$VENV_DIR/bin/python" \
    "ray[default]==2.57.0" \
    "numpy==1.26.4" \
    "opencv-python-headless==4.10.0.84" \
    "mediapipe==0.10.18" \
    "deepface>=0.0.93" \
    "tf-keras>=2.16.0" \
    "torch" \
    "torchvision" \
    "facenet-pytorch"

echo
echo "Setup completo."
echo "Para iniciar o hub: $(dirname "${BASH_SOURCE[0]}")/start_hub.sh"
