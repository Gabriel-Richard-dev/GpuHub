#!/usr/bin/env bash
# Setup de uma máquina de dev do laboratório: cria um venv com o gpuhub já
# instalado, e deixa um comando "gpuhub-python" pronto no PATH — sem precisar
# ativar venv nem configurar variável de ambiente toda vez.
#
# O Ray Client exige a MESMA versão major.minor de Python dos dois lados da
# conexão. Cada PC do lab tem seu próprio python3 do sistema (aqui pode ser
# 3.10, ali 3.12, em outro 3.14...) — usar esse python3 direto quebra
# silenciosamente só na hora de conectar no hub. Por isso usamos o `uv` pra
# criar o venv: ele baixa um Python isolado, igual em qualquer máquina, sem
# depender do que a distro oferece nem de sudo.
#
# PY_VERSION segue o requires-python do vigia-ia-lab (fonte da verdade —
# é quem consome essa GPU compartilhada), não uma escolha própria do
# gpuhub. Se o vigia-ia-lab subir o mínimo de Python, atualize aqui e em
# scripts/setup_hub.sh / docker/Dockerfile.hub (mesma variável) e rebuilde
# a imagem do hub.
#
# Uso: ./setup_dev.sh <ip-do-hub>
set -euo pipefail

HUB_ADDRESS="${1:-}"
if [ -z "$HUB_ADDRESS" ]; then
  echo "uso: $0 <ip-do-hub>" >&2
  exit 1
fi

PY_VERSION="3.11"
VENV_DIR="$HOME/.gpuhub-venv"
BIN_DIR="$HOME/.local/bin"

if ! command -v uv &>/dev/null; then
  export PATH="$HOME/.local/bin:$PATH"
fi
if ! command -v uv &>/dev/null; then
  echo "uv não encontrado, instalando (curl | sh, sem sudo)..."
  curl -LsSf https://astral.sh/uv/install.sh | sh
  export PATH="$HOME/.local/bin:$PATH"
fi

echo "Criando venv com Python $PY_VERSION (via uv, isolado do python3 do sistema)..."
# roda fora de qualquer projeto (cwd pode ter um pyproject.toml com outro
# requires-python, ex: rodando o setup de dentro de um repo) pra uv não
# tentar casar a versão com ele
(cd "$HOME" && uv venv --python "$PY_VERSION" "$VENV_DIR")
uv pip install --python "$VENV_DIR/bin/python" -q "git+https://github.com/Gabriel-Richard-dev/GpuHub.git"

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
