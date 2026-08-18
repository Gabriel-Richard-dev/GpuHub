#!/usr/bin/env bash
set -euo pipefail
VENV_DIR="${GPUHUB_VENV:-$HOME/.gpuhub/venv}"
source "$VENV_DIR/bin/activate"
ray stop
