# gpuhub

Infra do **servidor** que compartilha a GPU de uma máquina (o "hub") do
laboratório pra outros PCs rodarem treinos de IA nela remotamente, sem
precisar de GPU local. Sobe um [Ray](https://docs.ray.io/) head node com a
GPU exposta como recurso de cluster.

Este repo só cuida do hub. Quem manda treinos pra rodar aqui é o
`vigia-gpu-submit`, que já vem embutido no
[`vigia-ia-lab`](https://github.com/nuven-vigia/vigia-ia-lab)
(`vigia/gpuclient.py`) — nenhum PC de dev precisa clonar este repo.

## Como funciona

- O hub sobe um Ray head node em container Docker, com a GPU passada via
  `nvidia-container-toolkit`.
- Um script de treino normal em `.py` (sem nenhum código específico de GPU
  hub) é enviado pra rodar lá via `ray job submit` — é isso que o
  `vigia-gpu-submit` faz por trás.
- Com 1 GPU só no hub, o Ray enfileira automaticamente
  (`--entrypoint-num-gpus=1`): um job usa a GPU por vez, os demais esperam.
- O [dashboard nativo do Ray](http://10.50.21.14:8265) mostra em tempo real
  quem está rodando, quem está na fila, uso de GPU e logs — não tem
  dashboard customizado aqui, é o que o Ray já entrega de fábrica.

## Setup do hub

```bash
cd docker
docker compose up --build -d
```

Fica disponível na rede:

| Serviço              | Endereço                    |
|-----------------------|------------------------------|
| Ray client            | `ray://<ip-do-hub>:10001`   |
| Ray dashboard (Jobs)  | `http://<ip-do-hub>:8265`   |

O hub descobre sozinho em qual IP se anunciar (`scripts/lib_hub_ip.sh`): ele
espera a rede subir e pega o IP da interface que tem a rota default,
ignorando as bridges do Docker. Isso importa porque o Ray **fixa esse
endereço no start** — se ele subir antes da rede, o cluster nasce bindado na
`docker0` e fica invisível pra LAN sem dar erro nenhum. Se precisar forçar um
endereço, use `GPUHUB_HOST=<ip>` no `docker-compose.yml`.

O IP atual (`10.50.21.14`) vem de **DHCP**, e a máquina tem cabo e Wi-Fi —
trocar de interface muda o endereço e exige reiniciar o container pro Ray
rebindar. Reserva de DHCP no roteador do lab (ou IP fixo) resolve de vez.

```bash
docker compose logs -f gpuhub   # logs
docker compose down             # parar
docker compose up -d            # subir de novo sem rebuildar
```

`docker-compose.yml` já tem `restart: unless-stopped`, e o serviço `docker`
do sistema normalmente já inicia no boot — então depois do primeiro
`docker compose up -d` o container volta sozinho quando a máquina reinicia.

Alternativa sem Docker: `./scripts/setup_hub.sh` (cria venv, instala Ray +
stack do vigia-ia-lab) e `./scripts/start_hub.sh` (sobe o Ray head node,
fica preso no terminal — use tmux/screen ou monte seu próprio serviço
systemd em cima dele). Não rode as duas formas ao mesmo tempo, competem
pelas mesmas portas.

Portas a liberar no firewall pra rede local (`ufw allow <porta>/tcp`):
`10001` (Ray client, essencial), `8265` (Ray dashboard / Jobs API).

## Versão do Python

O Ray Client/Jobs exige a mesma versão major.minor de Python dos dois lados
da conexão (patch pode diferir — 3.11.2 e 3.11.9 conversam, 3.11 e 3.14
não). A versão usada hoje é a **3.11**, porque é o `requires-python` mínimo
do `vigia-ia-lab` — quem consome essa GPU compartilhada é quem manda na
versão, não este repo. Está fixada em `PY_VERSION` em dois lugares que
precisam ficar em sincronia: `docker/Dockerfile.hub` e
`scripts/setup_hub.sh`.

Instalamos via [`uv`](https://docs.astral.sh/uv/) em vez do `python3` do
apt/imagem base: baixa um interpretador isolado, funciona igual não importa
o Ubuntu da base, sem depender do que a distro oferece.

Se o `requires-python` do vigia-ia-lab mudar, atualize `PY_VERSION` nos
dois lugares acima e rebuilde a imagem do hub (`docker compose up --build
-d`).

## Dependências pré-instaladas no hub

A imagem já vem com a stack do `vigia-ia-lab` (numpy, opencv-headless,
mediapipe, deepface, torch, torchvision, facenet-pytorch) instalada de
fábrica — o primeiro job de qualquer dev não perde tempo baixando isso.
Se a lista de deps do vigia-ia-lab mudar, atualize a mesma lista em
`docker/Dockerfile.hub` (e `scripts/setup_hub.sh`, pro caminho bare-metal)
e rebuilde a imagem.

## Uso pelo dev (outra máquina do lab)

Não precisa clonar este repo. No `vigia-ia-lab`:

```bash
git clone git@github.com:nuven-vigia/vigia-ia-lab.git
cd vigia-ia-lab
uv venv --python 3.11 .venv && uv pip install -e .
vigia-gpu-submit train/seu_treino.py
```

Sem o vigia-ia-lab, o mesmo efeito na mão (venv com Python 3.11):

```bash
export RAY_ADDRESS=http://10.50.21.14:8265
ray job submit --entrypoint-num-gpus=1 --working-dir . -- python train/seu_treino.py
```

`--entrypoint-num-gpus=1` é o que faz a fila funcionar — sem isso dois treinos
disputam a mesma GPU em vez de esperar a vez. E **dataset não vai no
`--working-dir`**: ele é zipado e enviado por HTTP a cada submit (limite
prático ~100 MB). Dados grandes ficam em `/mnt/pesquisa`, que o container já
monta, e o script lê o caminho de lá.

Ou pelo VSCode: abre o script, aperta F5, escolhe "Treinar no GPU Hub" —
já configurado em `.vscode/launch.json` no vigia-ia-lab. Detalhes em
`vigia/gpuclient.py` do vigia-ia-lab.

## Estrutura

```
scripts/
  setup_hub.sh, start_hub.sh, stop_hub.sh   # caminho bare-metal
  start_hub_docker.sh                       # entrypoint do container
  lib_hub_ip.sh                             # descoberta do IP, usada pelos dois
docker/
  Dockerfile.hub, docker-compose.yml
```
