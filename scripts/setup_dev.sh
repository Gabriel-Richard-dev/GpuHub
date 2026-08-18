#!/usr/bin/env bash
# Setup de uma máquina de dev do laboratório: cria um venv com o gpuhub já
# instalado, e deixa um comando "gpuhub-python" pronto no PATH — sem precisar
# ativar venv nem configurar variável de ambiente toda vez.
#
# Uso: ./setup_dev.sh <ip-do-hub>
set -euo pipefail

HUB_ADDRESS="${1:-}"
if [ -z "$HUB_ADDRESS" ]; then
  echo "uso: $0 <ip-do-hub>" >&2
  exit 1
fi

VENV_DIR="$HOME/.gpuhub-venv"
BIN_DIR="$HOME/.local/bin"

python3.10 -m venv "$VENV_DIR"
"$VENV_DIR/bin/pip" install --upgrade pip -q
"$VENV_DIR/bin/pip" install -q "git+https://github.com/Gabriel-Richard-dev/GpuHub.git"

mkdir -p "$BIN_DIR"
cat > "$BIN_DIR/gpuhub-python" <<EOF
#!/usr/bin/env bash
export GPUHUB_TARGET=hub
export GPUHUB_ADDRESS=$HUB_ADDRESS
exec "$VENV_DIR/bin/python" "\$@"
EOF
chmod +x "$BIN_DIR/gpuhub-python"

echo
echo "Pronto. Pra rodar um treino, de qualquer pasta/terminal:"
echo "  gpuhub-python seu_treino.py"
echo
if [[ ":$PATH:" != *":$BIN_DIR:"* ]]; then
  echo "Aviso: $BIN_DIR não está no PATH. Adicione ao seu ~/.bashrc:"
  echo "  export PATH=\"\$HOME/.local/bin:\$PATH\""
fi
