# gpuhub

Infra do **servidor** que compartilha a GPU de uma máquina (o "hub") do
laboratório com os outros PCs, pra rodar treino de IA sem GPU local. Por
baixo é um [Ray](https://docs.ray.io/) head node com a GPU exposta como
recurso de cluster; por cima, um proxy com TLS e conta por pessoa.

## Pra quem vai usar (máquina de dev)

Instala o cliente uma vez:

```bash
uv venv --python 3.11 ~/.gpuhub-venv
uv pip install --python ~/.gpuhub-venv/bin/python 'ray[default]==2.57.0'
export PATH="$HOME/.gpuhub-venv/bin:$PATH"   # põe no ~/.bashrc

curl -fsSL https://raw.githubusercontent.com/Gabriel-Richard-dev/GpuHub/master/bin/gpuhub \
  -o ~/.local/bin/gpuhub && chmod +x ~/.local/bin/gpuhub
```

Configura (pede a senha que o admin do hub te passou):

```bash
gpuhub login <seu-nome>
```

E roda:

```bash
gpuhub submit train/seu_treino.py     # manda e acompanha o log
gpuhub queue                          # o que roda e o que espera
gpuhub logs <job-id>
gpuhub stop <job-id>
```

O script de treino é um `.py` normal — nenhuma linha de código específico de
GPU hub. Ele roda no hub, com a GPU inteira pra ele.

Duas coisas que economizam dor de cabeça:

- **Dataset não vai junto com o código.** A pasta do script sobe inteira por
  HTTP a cada submit. Dados grandes ficam em `/mnt/pesquisa` no hub (o
  container monta esse caminho), e o script lê de lá. O `gpuhub submit` avisa
  se a pasta passar de 50 MB.
- **Um treino por vez.** Com uma GPU só, o segundo job espera o primeiro
  terminar — isso é a fila funcionando, não travamento. `gpuhub queue` mostra
  a ordem.

O `ray://` (Ray Client) não é exposto: ele é gRPC e não passa pelo proxy
autenticado. Quem precisar dele usa túnel SSH até o hub.

## Como está montado

```
dev ──HTTPS + login──> Caddy :443 ──localhost──> Ray Jobs API :8265 ──> GPU
```

Só o Caddy escuta na rede. Isso não é enfeite: **a Jobs API do Ray não tem
autenticação nenhuma** — quem alcança a porta 8265 executa código arbitrário
na máquina. Tem varredura em massa procurando exatamente essa porta aberta.
Por isso, neste repo:

- o Ray nasce em `127.0.0.1` (`GPUHUB_DASHBOARD_HOST`)
- o container roda como usuário comum (uid 2000), não como root
- o firewall fecha 6379/8265/10001 explicitamente
- cada pessoa tem conta própria, e o log do Caddy registra quem submeteu

## Setup do hub (primeira vez)

```bash
cp docker/.env.example docker/.env      # revise o endereço e o TLS
sudo ./scripts/install_host.sh --users alice,bob --firewall
docker compose -f docker/docker-compose.yml up --build -d
./scripts/gpuhub-user.sh add alice
```

O `install_host.sh` faz só o que precisa de root: grupo `gpuhub` e operadores,
dono de `/mnt/pesquisa`, serviço systemd, avahi na interface certa e (com
`--firewall`) as regras de ufw. Ele mostra o que vai fazer no firewall e pede
confirmação — de propósito não mexe nas políticas padrão nem em SSH, porque
isso tranca quem administra a máquina de fora.

## Operação

```bash
systemctl start|stop|status gpuhub          # sobe/desce o conjunto
docker compose -f docker/docker-compose.yml logs -f gpuhub
./scripts/gpuhub-user.sh add|remove|list    # contas
```

Quem operou até hoje foi uma conta só (`labnuven`). O `--users` do
`install_host.sh` existe pra isso não continuar assim: sem mais de uma pessoa
no grupo `docker`, ninguém reinicia o hub quando quem o montou não está.

## Rede: campus hoje, público depois

Hoje o hub atende a rede do campus, com certificado de uma CA interna que o
próprio Caddy gera (o `gpuhub login` baixa e confia nela sozinho).

Pra abrir pra internet depois, o que muda no repo são **duas linhas** de
`docker/.env`:

```ini
GPUHUB_SITE_ADDRESS=gpuhub.seu-dominio.br
GPUHUB_TLS=lab@ifce.edu.br      # liga Let's Encrypt automático
```

O que **não** está no repo e é pré-requisito: um nome DNS apontando pro hub,
e a liberação de 80/443 na borda pela equipe de redes do IFCE — `10.50.21.14`
é endereço privado do campus. Vale também rever o `--firewall` (hoje ele
libera 443 só pra faixa do campus) e ter em mente que exposição pública pede
mais do que o repo entrega hoje: limite de tentativa de login e isolamento
mais forte entre jobs de pessoas diferentes.

### O endereço do hub

A máquina se chama `gpuhub` e o avahi a anuncia como `gpuhub.local` na LAN —
por isso o padrão não é IP. O IP em si (`10.50.21.14`) vem de DHCP e a
máquina tem cabo e Wi-Fi: se ela trocar de interface, o endereço muda e o Ray
precisa reiniciar pra rebindar. Reserva de DHCP no roteador resolve de vez.

O hub descobre sozinho em qual IP se anunciar (`scripts/lib_hub_ip.sh`):
espera a rede subir e pega o IP da interface com a rota default, ignorando as
bridges do Docker. Isso existe porque o Ray **fixa o endereço no start** — se
ele subir antes da rede, o cluster nasce bindado na `docker0` e fica invisível
pra rede sem erro nenhum no log. Pra forçar um endereço, use `GPUHUB_HOST`.

## Versão do Python

O Ray Client/Jobs exige a mesma versão major.minor de Python dos dois lados
(3.11.2 e 3.11.9 conversam, 3.11 e 3.14 não). Hoje é **3.11**, porque é o
`requires-python` mínimo do
[`vigia-ia-lab`](https://github.com/nuven-vigia/vigia-ia-lab) — quem consome
essa GPU é quem manda na versão, não este repo. Está fixada em `PY_VERSION`
em `docker/Dockerfile.hub` e `scripts/setup_hub.sh`, que precisam ficar em
sincronia.

Instalamos via [`uv`](https://docs.astral.sh/uv/) em vez do `python3` do
apt: baixa um interpretador isolado, igual em qualquer máquina. Ele vai pra
`/opt/uv-python` e não pro `/root` padrão do uv — senão o container não-root
não consegue nem executar o próprio Python.

## Dependências pré-instaladas

A imagem já vem com a stack do `vigia-ia-lab` (numpy, opencv-headless,
mediapipe, deepface, torch, torchvision, facenet-pytorch) — o primeiro job de
cada pessoa não perde tempo baixando isso. Se a lista de deps do vigia-ia-lab
mudar, atualize a mesma lista em `docker/Dockerfile.hub` (e em
`scripts/setup_hub.sh`, pro caminho bare-metal) e rebuilde.

## Quando o lab ganhar mais uma GPU

O Ray já é um cluster: a segunda máquina entra como worker, não como um
segundo hub. Nada muda pra quem submete — o `gpuhub submit` continua igual e
passa a ter duas GPUs de fila.

O head node não fixa mais `--num-gpus`: ele conta as GPUs que enxerga, então
uma segunda placa **nesta** máquina já é aproveitada sem mexer em nada. Pra
uma segunda **máquina**, o worker precisa alcançar o head (porta 6379 e a
faixa de portas do Ray) — o que hoje o firewall fecha. É um ajuste de regra
pra faixa onde os workers vivem, não um redesenho.

## Estrutura

```
bin/
  gpuhub                                    # cliente que o lab usa
scripts/
  install_host.sh                           # a parte que precisa de root
  gpuhub-user.sh                            # contas
  setup_hub.sh, start_hub.sh, stop_hub.sh   # caminho bare-metal (sem Docker)
  start_hub_docker.sh                       # entrypoint do container
  lib_hub_ip.sh                             # descoberta do IP, usada pelos dois
docker/
  Dockerfile.hub, docker-compose.yml
  Caddyfile, .env.example                   # porta de entrada e endereço
systemd/
  gpuhub.service
```
