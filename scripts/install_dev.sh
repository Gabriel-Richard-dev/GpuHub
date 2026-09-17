#!/usr/bin/env bash
# Prepara uma máquina de dev do laboratório pra mandar treino pro hub.
# Não precisa clonar repo nem ter GPU local:
#
#   curl -fsSLk https://gpuhub.local/install | bash
#
# Faz três coisas: venv com o Python certo, cliente `gpuhub` no PATH, e o
# login. Rodar de novo é seguro — atualiza o que mudou.
set -euo pipefail

HUB_URL="${GPUHUB_URL:-https://gpuhub.local}"
PY_VERSION="3.11"
RAY_VERSION="2.57.0"
VENV_DIR="$HOME/.gpuhub-venv"
BIN_DIR="$HOME/.local/bin"

echo "== gpuhub: setup desta máquina =="
echo "   hub: $HUB_URL"
echo

# O Ray exige a MESMA versão major.minor de Python dos dois lados. Cada PC do
# lab tem o seu (aqui 3.10, ali 3.12...), e usar o python3 do sistema quebra
# silenciosamente só na hora de falar com o hub. O uv baixa um interpretador
# isolado, igual em qualquer máquina, sem sudo.
if ! command -v uv &>/dev/null; then
  export PATH="$HOME/.local/bin:$PATH"
fi
if ! command -v uv &>/dev/null; then
  echo "-> instalando uv (sem sudo)..."
  curl -LsSf https://astral.sh/uv/install.sh | sh
  export PATH="$HOME/.local/bin:$PATH"
fi

echo "-> venv com Python $PY_VERSION em $VENV_DIR"
# roda a partir do $HOME: se você chamar isso de dentro de um projeto com
# pyproject.toml, o uv tentaria casar a versão com o do projeto.
(cd "$HOME" && uv venv --quiet --python "$PY_VERSION" "$VENV_DIR")

echo "-> ray $RAY_VERSION (mesma versão do hub)"
uv pip install --quiet --python "$VENV_DIR/bin/python" "ray[default]==${RAY_VERSION}"

echo "-> cliente gpuhub em $BIN_DIR"
mkdir -p "$BIN_DIR"
# -k aqui porque a CA do hub é interna e você ainda não a tem: é exatamente o
# que o `gpuhub login` resolve logo em seguida, buscando e fixando a CA.
curl -fsSLk "$HUB_URL/gpuhub" -o "$BIN_DIR/gpuhub"
chmod +x "$BIN_DIR/gpuhub"

# O `gpuhub` chama o `ray`, então o venv precisa estar no PATH.
LINE="export PATH=\"\$HOME/.gpuhub-venv/bin:\$HOME/.local/bin:\$PATH\""
if ! grep -qF "$LINE" "$HOME/.bashrc" 2>/dev/null; then
  printf '\n# gpuhub\n%s\n' "$LINE" >> "$HOME/.bashrc"
  echo "-> PATH adicionado ao ~/.bashrc"
fi
export PATH="$VENV_DIR/bin:$BIN_DIR:$PATH"

echo
echo "Instalado. Falta o login (uma vez só):"
echo
echo "    gpuhub login <seu-nome>"
echo
echo "Depois: gpuhub submit seu_treino.py"
echo "Se o comando não for encontrado, abra um terminal novo (o PATH mudou)."
