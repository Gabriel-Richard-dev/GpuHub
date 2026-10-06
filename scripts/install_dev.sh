#!/usr/bin/env bash
# Prepara uma maquina de dev do lab pra mandar treino pro hub, em UM comando.
# Nao precisa clonar repo nem ter GPU local:
#
#   curl -fsSLk --resolve gpuhub.local:443:10.50.21.14 https://gpuhub.local/install | bash
#
# (o --resolve so e preciso no 1o acesso; o script fixa o gpuhub.local no
#  /etc/hosts, e dai em diante e so `gpuhub ...`)
#
# Faz: resolve gpuhub.local, venv com o Python certo, cliente `gpuhub` no PATH
# (bash e fish), e te manda logar. Rodar de novo e seguro.
set -euo pipefail

HUB_HOST="${GPUHUB_HOST:-gpuhub.local}"
HUB_IP="${GPUHUB_IP:-10.50.21.14}"
HUB_URL="https://$HUB_HOST"
PY_VERSION="3.11"
RAY_VERSION="2.57.0"
VENV_DIR="$HOME/.gpuhub-venv"
BIN_DIR="$HOME/.local/bin"

echo "== gpuhub: setup desta maquina ($HUB_URL) =="

# 1) DNS: .local nao cruza sub-redes do campus. Se nao resolve, fixa no hosts.
if ! getent hosts "$HUB_HOST" >/dev/null 2>&1; then
  echo "-> $HUB_HOST nao resolve; fixando $HUB_IP no /etc/hosts (pede sudo uma vez)"
  echo "$HUB_IP $HUB_HOST" | sudo tee -a /etc/hosts >/dev/null
fi

# 2) uv (interpretador isolado, sem sudo) — o Ray exige a MESMA versao
#    major.minor de Python dos dois lados; usar o python do sistema quebra calado.
export PATH="$BIN_DIR:$PATH"
if ! command -v uv &>/dev/null; then
  echo "-> instalando uv (sem sudo)..."
  curl -LsSf https://astral.sh/uv/install.sh | sh
  export PATH="$BIN_DIR:$PATH"
fi

echo "-> venv Python $PY_VERSION em $VENV_DIR"
(cd "$HOME" && uv venv --quiet --python "$PY_VERSION" "$VENV_DIR")
echo "-> ray $RAY_VERSION (igual ao hub)"
uv pip install --quiet --python "$VENV_DIR/bin/python" "ray[default]==${RAY_VERSION}"

echo "-> cliente gpuhub em $BIN_DIR"
mkdir -p "$BIN_DIR"
curl -fsSLk "$HUB_URL/gpuhub" -o "$BIN_DIR/gpuhub"
chmod +x "$BIN_DIR/gpuhub"

# 3) PATH no shell certo — bash E fish (o lab usa os dois)
PATHLINE_BASH='export PATH="$HOME/.gpuhub-venv/bin:$HOME/.local/bin:$PATH"'
if ! grep -qF "$PATHLINE_BASH" "$HOME/.bashrc" 2>/dev/null; then
  printf '\n# gpuhub\n%s\n' "$PATHLINE_BASH" >> "$HOME/.bashrc"
fi
if [ -d "$HOME/.config/fish" ] || command -v fish >/dev/null 2>&1; then
  mkdir -p "$HOME/.config/fish/conf.d"
  printf '# gpuhub\nfish_add_path "$HOME/.gpuhub-venv/bin" "$HOME/.local/bin"\n' > "$HOME/.config/fish/conf.d/gpuhub.fish"
fi
export PATH="$VENV_DIR/bin:$BIN_DIR:$PATH"

echo
echo "Instalado. Agora logue (uma vez; abre uma URL pra aprovar no navegador):"
echo
echo "    gpuhub login"
echo
echo "Depois: gpuhub submit seu_treino.py"
echo "Se 'gpuhub' nao for encontrado, abra um terminal novo (o PATH mudou)."
