#!/usr/bin/env bash
# Setup único do ambiente do hub: cria venv e instala a lib gpuhub.
#
# Usa Python fixo (via uv) pelo mesmo motivo do setup_dev.sh: o Ray Client
# exige a mesma versão major.minor dos dois lados. PY_VERSION segue o
# requires-python do vigia-ia-lab (fonte da verdade) — mantenha igual ao
# PY_VERSION de scripts/setup_dev.sh e docker/Dockerfile.hub.
set -euo pipefail

PY_VERSION="3.11"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VENV_DIR="${GPUHUB_VENV:-$HOME/.gpuhub/venv}"

echo "== gpuhub: setup do hub =="

if ! command -v nvidia-smi &>/dev/null; then
  echo "nvidia-smi não encontrado. Instale os drivers da NVIDIA antes de continuar." >&2
  exit 1
fi
nvidia-smi --query-gpu=name,memory.total --format=csv,noheader

if ! groups "$USER" | grep -q '\bdocker\b'; then
  echo "Aviso: usuário $USER não está no grupo docker (só necessário se for usar docker/Dockerfile.hub)."
  echo "  Para adicionar: sudo usermod -aG docker $USER   (depois faça login de novo)"
fi

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
source "$VENV_DIR/bin/activate"
uv pip install -e "$ROOT_DIR"

echo
echo "Setup completo."
echo "Para iniciar o hub: source $VENV_DIR/bin/activate && $ROOT_DIR/scripts/start_hub.sh"
