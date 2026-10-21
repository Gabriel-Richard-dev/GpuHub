# gpuhub

Infra do **servidor** que compartilha a GPU de uma máquina (o "hub") do
laboratório com os outros PCs, pra rodar treino de IA sem GPU local. Por
baixo é um [Ray](https://docs.ray.io/) head node com a GPU exposta como
recurso de cluster; por cima, um proxy com TLS e conta por pessoa.

## Pra quem vai usar (máquina de dev)

> **Guia completo (usuário e admin):** [`docs/GUIA-DE-USO.md`](docs/GUIA-DE-USO.md).

Instala o cliente uma vez (sem sudo, sem clonar o repo) e faz login:

```bash
curl -fsSLk https://gpuhub.local/install | bash   # venv + Python 3.11 + Ray + CLI
gpuhub login                                       # abre uma URL pra aprovar no navegador
```

O `login` é device-flow do Keycloak: o CLI mostra uma URL e um código, você
aprova no navegador com sua conta do hub, e o token fica guardado (renova
sozinho). Depois:

```bash
gpuhub submit train/seu_treino.py     # manda e acompanha o log
gpuhub queue                          # o que roda e o que espera
gpuhub logs <job-id>
gpuhub stop <job-id>
gpuhub whoami                         # quem você é e seus papéis
```

O script de treino é um `.py` normal — nenhuma linha de código específico de
GPU hub. Ele roda no hub, com a GPU inteira pra ele.

Duas coisas que economizam dor de cabeça:

- **Dataset não vai junto com o código.** A pasta do script sobe inteira por
  HTTP a cada submit. Dados grandes ficam em `/data` no hub (navegável pelo
  drive web em `/files/`), e o script lê de lá. O `gpuhub submit` avisa se a
  pasta passar de 50 MB.
- **Um treino por vez.** Com uma GPU só, o segundo job espera o primeiro
  terminar — isso é a fila funcionando, não travamento. `gpuhub queue` mostra
  a ordem.

O `ray://` (Ray Client) não é exposto: ele é gRPC e não passa pelo proxy
autenticado. Quem precisar dele usa túnel SSH até o hub.

## Como está montado

```
dev ──HTTPS + Bearer JWT──> Caddy :443 ──┬─ /         → Ray Jobs API 127.0.0.1:8265 → GPU
                                         ├─ /auth/*   → Keycloak 127.0.0.1:8080 (realm lab)
                                         └─ /files/*  → Filebrowser 127.0.0.1:8090 (/data)
```

Só o Caddy escuta na rede. Isso não é enfeite: **a Jobs API do Ray não tem
autenticação nenhuma** — quem alcança a porta 8265 executa código arbitrário
na máquina. Tem varredura em massa procurando exatamente essa porta aberta.
Por isso, neste repo:

- o Ray nasce em `127.0.0.1` (`GPUHUB_DASHBOARD_HOST`)
- o container roda como usuário comum (uid 2000), não como root; a GPU entra via
  **CDI** (`nvidia.com/gpu=all`), que sobrevive a `systemctl daemon-reload`
- o firewall fecha 6379/8265/10001 explicitamente
- o Caddy valida o **JWT do Keycloak** (realm `lab`, papéis por método) e
  registra quem submeteu

## Setup do hub (primeira vez)

```bash
cp docker/.env.example docker/.env                          # revise o endereço e o TLS
sudo ./scripts/install_host.sh --users alice,bob --firewall
docker compose -f docker/docker-compose.yml up --build -d    # Ray + Caddy + Filebrowser
(cd keycloak && docker compose up -d)                        # Keycloak + Postgres (compose separado)
./scripts/simplify-deploy.sh                                 # liga o drive /files e o console /auth/admin
```

Depois, crie as contas no Keycloak (console `/auth/admin` ou `kcadm`) — veja
[`docs/GUIA-DE-USO.md`](docs/GUIA-DE-USO.md) § *Admin A*.

O `install_host.sh` faz só o que precisa de root: grupo `gpuhub` e operadores,
dono de `/mnt/pesquisa`, serviço systemd, avahi na interface certa e (com
`--firewall`) as regras de ufw. Ele mostra o que vai fazer no firewall e pede
confirmação — de propósito não mexe nas políticas padrão nem em SSH, porque
isso tranca quem administra a máquina de fora.

## Operação

```bash
systemctl start|stop|status gpuhub          # Ray + Caddy + Filebrowser (compose docker/)
docker compose -f docker/docker-compose.yml logs -f gpuhub
(cd keycloak && docker compose up -d)       # Keycloak (compose separado, fora do systemd)
bash scripts/smoke-test.sh                  # valida a plataforma ponta a ponta
bash scripts/backup.sh                      # backup (Keycloak + filebrowser + configs)
```

Contas são no Keycloak (console `/auth/admin` ou `kcadm`), não mais no
`gpuhub-user.sh` — veja [`docs/GUIA-DE-USO.md`](docs/GUIA-DE-USO.md) § *Admin A*.

Quem opera precisa estar no grupo `docker`. O `--users` do `install_host.sh`
cuida disso: sem mais de uma pessoa no grupo, ninguém reinicia o hub quando
quem o montou não está.

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
  gpuhub                                    # cliente que o lab usa (login device-flow)
docs/
  GUIA-DE-USO.md                            # guia completo (usuário + admin)
scripts/
  install_host.sh                           # a parte que precisa de root
  install_dev.sh                            # instalador da máquina de dev (servido em /install)
  simplify-deploy.sh                        # liga o drive /files + console /auth/admin
  backup.sh, smoke-test.sh                  # backup diário e validação ponta a ponta
  gpuhub-user.sh                            # LEGADO (contas basic_auth; hoje é Keycloak)
  setup_hub.sh, start_hub.sh, stop_hub.sh   # caminho bare-metal (sem Docker)
  start_hub_docker.sh                       # entrypoint do container
  lib_hub_ip.sh                             # descoberta do IP
docker/
  Dockerfile.hub, Dockerfile.caddy
  docker-compose.yml                        # Ray + Caddy(JWT) + Filebrowser
  Caddyfile, .env.example                   # porta de entrada e endereço
keycloak/
  docker-compose.yml, realm/lab-realm.json  # IdP central (realm lab)
  NEXT-CUTOVER.md                           # como o basic_auth virou Keycloak
systemd/
  gpuhub.service
```
