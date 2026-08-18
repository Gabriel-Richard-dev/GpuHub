#!/usr/bin/env bash
# Setup único do ambiente do hub: cria venv e instala a lib gpuhub.
set -euo pipefail

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

echo "Criando venv em $VENV_DIR ..."
python3 -m venv "$VENV_DIR"
source "$VENV_DIR/bin/activate"
pip install --upgrade pip
pip install -e "$ROOT_DIR"

echo
echo "Setup completo."
echo "Para iniciar o hub: source $VENV_DIR/bin/activate && $ROOT_DIR/scripts/start_hub.sh"
