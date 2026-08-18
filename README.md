# gpuhub

Compartilha a GPU de uma máquina (o "hub") pra outros computadores rodarem
treinos de IA nela remotamente, sem precisar de GPU local. Usa
[Ray](https://docs.ray.io/): o hub roda um Ray head node com a GPU exposta
como recurso de cluster; os devs conectam da própria máquina (ex: VSCode) e
mandam funções de treino que executam na GPU do hub.

## Como funciona

- **Hub**: sobe um Ray head node + um dashboard web (`gpuhub/dashboard`),
  rodando em container Docker com a GPU passada via `nvidia-container-toolkit`.
- **Dev**: escreve o script de treino normalmente em `.py`, decora a função
  principal com `@gpuhub.gpu_task`, e escolhe o ambiente (`local` ou `hub`)
  por variável de ambiente — o mesmo código roda nos dois casos.
- Com 1 GPU só no hub, o Ray enfileira automaticamente: um job usa a GPU por
  vez, os demais esperam.
- O dashboard mostra em tempo real quem está rodando, quem está na fila,
  uso/temperatura/VRAM da GPU e o histórico de jobs.

## Setup do hub

```bash
cd docker
docker compose up --build -d
```

Fica disponível na rede:

| Serviço              | Endereço                    |
|-----------------------|------------------------------|
| Ray client (jobs)     | `ray://<ip-do-hub>:10001`   |
| Ray dashboard nativo  | `http://<ip-do-hub>:8265`   |
| gpuhub dashboard      | `http://<ip-do-hub>:8000`   |

```bash
docker compose logs -f gpuhub   # logs
docker compose down             # parar
docker compose up -d            # subir de novo sem rebuildar
```

`docker-compose.yml` já tem `restart: unless-stopped`, e o serviço `docker`
do sistema normalmente já inicia no boot — então depois do primeiro
`docker compose up -d` o container volta sozinho quando a máquina reinicia.

Alternativa sem Docker: `./scripts/setup_hub.sh` (cria venv, instala a lib)
e `./scripts/start_hub.sh` (sobe Ray + dashboard, fica preso no terminal —
use tmux/screen ou monte seu próprio serviço systemd em cima dele).
Não rode as duas formas ao mesmo tempo, competem pelas mesmas portas.

Portas a liberar no firewall pra rede local (`ufw allow <porta>/tcp`):
`10001` (Ray client, essencial), `8265` (Ray dashboard), `8000` (gpuhub
dashboard).

## Versão do Python

O Ray Client exige a mesma versão major.minor de Python dos dois lados da
conexão (patch pode diferir — 3.10.12 e 3.10.21 conversam, 3.10 e 3.14 não).
A imagem Docker do hub usa Python 3.10 (base `ubuntu22.04`); crie o venv do
dev também em 3.10 (`python3.10 -m venv .venv`). Se o hub rodar bare-metal em
vez de Docker, use a versão de Python instalada naquela máquina.

## Configuração

Copie `.env.example` pra `.env` e coloque o IP do hub na rede:

```bash
cp .env.example .env
# edite GPUHUB_ADDRESS no .env
set -a && source .env && set +a
```

## Setup do dev (outra máquina)

```bash
python3.10 -m venv .venv
source .venv/bin/activate
pip install --upgrade pip       # pip velho + setuptools novo instala "vazio", sem avisar
```

Instalação rápida, direto do GitHub (sem precisar clonar):

```bash
pip install "git+https://github.com/Gabriel-Richard-dev/GpuHub.git"
```

Ou clonando (melhor se você quiser mexer nos exemplos em `examples/`):

```bash
git clone https://github.com/Gabriel-Richard-dev/GpuHub.git
cd GpuHub
pip install -e .
pip install -e ".[examples]"    # opcional, instala torch pros exemplos
```

Teste a conexão:

```bash
GPUHUB_TARGET=hub GPUHUB_ADDRESS=<ip-do-hub> python -c "
import gpuhub, ray
gpuhub.connect()
print(ray.cluster_resources())
"
```

Script de treino:

```python
import gpuhub

gpuhub.connect()  # lê GPUHUB_TARGET / GPUHUB_ADDRESS do ambiente

@gpuhub.gpu_task(num_gpus=1)
def train(epochs: int):
    import torch
    ...
    return model.state_dict()

if __name__ == "__main__":
    weights = train.run(epochs=5, user="gabriel", name="meu-treino")
```

```bash
GPUHUB_TARGET=local python train.py                          # teste local
GPUHUB_TARGET=hub GPUHUB_ADDRESS=<ip-do-hub> python train.py  # GPU do hub
```

No VSCode, fixe isso em `.vscode/launch.json` pra trocar de ambiente sem
editar o código:

```json
{
  "configurations": [
    {
      "name": "Treinar no GPU Hub",
      "type": "debugpy",
      "request": "launch",
      "program": "${file}",
      "env": { "GPUHUB_TARGET": "hub", "GPUHUB_ADDRESS": "<ip-do-hub>" }
    },
    {
      "name": "Treinar local (teste)",
      "type": "debugpy",
      "request": "launch",
      "program": "${file}",
      "env": { "GPUHUB_TARGET": "local" }
    }
  ]
}
```

`user=` é uma string livre, só aparece no dashboard identificando quem está
usando a GPU — sem login.

Exemplos: `examples/train_example.py` (MLP simples) e
`examples/heavy_train_example.py` (CNN pesada de propósito, boa pra sentir a
diferença entre `local` numa máquina sem GPU e `hub`).

## Estrutura

```
gpuhub/
  client.py          # connect(): escolhe rodar local ou no hub
  decorators.py       # @gpu_task: transforma a função em job rastreado
  tracker.py           # ator Ray com quem está rodando/na fila/histórico
  dashboard/
    server.py           # API FastAPI (/api/status, /api/gpu)
    static/index.html   # página do dashboard
scripts/
  setup_hub.sh, start_hub.sh, stop_hub.sh   # caminho bare-metal
  start_hub_docker.sh                         # entrypoint do container
docker/
  Dockerfile.hub, docker-compose.yml
examples/
  train_example.py, heavy_train_example.py
```

## Notas

- `num_gpus=1` em `@gpuhub.gpu_task` é o que faz o Ray enfileirar jobs
  quando a GPU já está ocupada, sem lógica de fila própria.
- Pra isolar dependências por job, dá pra passar
  `runtime_env={"pip": [...]}` no `@gpuhub.gpu_task` em vez de container por
  job.
