# Guia de uso do GPU Hub

Guia completo da plataforma: pra quem vai **usar** a GPU de outra máquina, e pra
quem **administra** o hub (criar contas, drive, operação, backup).

O hub compartilha a GPU de uma máquina do lab via [Ray](https://docs.ray.io/).
Você manda um script `.py` normal, ele roda lá com a GPU inteira, e você
acompanha o log do seu PC. A entrada é uma única porta HTTPS (Caddy) que valida
um **token do Keycloak** (conta individual) antes de deixar qualquer coisa
chegar no Ray.

**Índice**
- [1. Pré-requisitos](#1-pré-requisitos)
- [2. Instalar o CLI](#2-instalar-o-cli-uma-vez-por-máquina)
- [3. Login](#3-login-uma-vez)
- [4. Rodar e acompanhar treinos](#4-rodar-e-acompanhar-treinos)
- [5. Dados grandes e o Drive web](#5-dados-grandes-e-o-drive-web)
- [6. Papéis e o que cada um pode](#6-papéis-e-o-que-cada-um-pode)
- [7. Resolução de problemas](#7-resolução-de-problemas)
- [Admin A — Registrar e remover usuários](#admin-a--registrar-e-remover-usuários)
- [Admin B — O Drive (Filebrowser)](#admin-b--o-drive-filebrowser)
- [Admin C — Operação do hub](#admin-c--operação-do-hub)
- [Admin D — Backup e restauração](#admin-d--backup-e-restauração)
- [Admin E — Verificar a plataforma (smoke-test)](#admin-e--verificar-a-plataforma-smoke-test)
- [Como está montado](#como-está-montado)

---

## 1. Pré-requisitos

- Estar na **rede do campus** (o hub atende `gpuhub.local` → `10.50.21.14`, um
  endereço privado; de fora, só por VPN do IFCE).
- Ter uma **conta no hub**, criada pelo admin ([Admin A](#admin-a--registrar-e-remover-usuários)).
- **Não precisa** de GPU local, nem clonar o repositório, nem ser root.

---

## 2. Instalar o CLI (uma vez por máquina)

```bash
curl -fsSLk https://gpuhub.local/install | bash
```

Faz tudo **sem sudo**: instala o [`uv`](https://docs.astral.sh/uv/) se faltar,
cria um ambiente com o **Python certo** (3.11) em `~/.gpuhub-venv` com o cliente
do Ray (`ray[default]==2.57.0`), baixa o CLI `gpuhub` pra `~/.local/bin/` e põe o
PATH no seu `~/.bashrc`.

> O Ray exige a **mesma versão major.minor de Python** nos dois lados — por isso
> o `uv` em vez do `python3` do sistema. O `-k` no `curl` é de propósito: a CA do
> hub é interna e você ainda não a tem; é o `gpuhub login` que a busca e passa a
> confiar nela.

Depois, **abra um terminal novo** (o PATH mudou) ou `source ~/.bashrc`. Confira:

```bash
gpuhub            # ajuda
ray --version     # 2.57.0
```

<details>
<summary>Instalação manual (se não alcançar o <code>/install</code>)</summary>

```bash
uv venv --python 3.11 ~/.gpuhub-venv
uv pip install --python ~/.gpuhub-venv/bin/python 'ray[default]==2.57.0'
mkdir -p ~/.local/bin
curl -fsSLk https://gpuhub.local/gpuhub -o ~/.local/bin/gpuhub && chmod +x ~/.local/bin/gpuhub
echo 'export PATH="$HOME/.gpuhub-venv/bin:$HOME/.local/bin:$PATH"' >> ~/.bashrc
```
</details>

---

## 3. Login (uma vez)

```bash
gpuhub login
```

O CLI mostra uma **URL** e um **código**. Abra a URL no navegador, confira o
código e entre com **seu usuário e senha do hub**. Ao aprovar, o terminal
destrava:

```
  Abra no navegador:  https://gpuhub.local/auth/realms/lab/device?user_code=ABCD-EFGH
  Código:             ABCD-EFGH

Aguardando você aprovar...
Pronto. Manda um treino com: gpuhub submit seu_treino.py
```

É o fluxo *device authorization* do OAuth: nenhuma senha passa pelo CLI, só pelo
navegador (Keycloak). O token fica em `~/.gpuhub/` e **se renova sozinho**; você
só repete o `login` se ficar dias sem usar.

- Ver quem você é e seus papéis: `gpuhub whoami`
- Apontar pra outro hub: `gpuhub login https://outro-hub` (sem argumento usa `https://gpuhub.local`)

```bash
$ gpuhub whoami
usuario: gabriel
papeis : ['admin']
hub    : https://gpuhub.local
```

---

## 4. Rodar e acompanhar treinos

Seu script é um `.py` comum — **nenhuma linha específica de GPU hub**:

```bash
gpuhub submit train/treino.py                 # manda e já acompanha o log
gpuhub submit train/treino.py --epochs 50     # argumentos vão pro seu script
GPUHUB_GPUS=2 gpuhub submit train/treino.py   # mais de 1 GPU (quando houver)
```

```bash
gpuhub queue            # o que está rodando e o que está na fila
gpuhub logs <job-id>    # acompanha o log de um job
gpuhub status <job-id>  # estado de um job
gpuhub stop <job-id>    # mata um job
```

O que o `submit` faz: sobe **a pasta do script inteira** por HTTPS; se houver um
**`requirements.txt`** ao lado, instala essas deps no job; reserva **1 GPU**
(mude com `GPUHUB_GPUS`); e carimba o job com seu usuário.

> **Uma GPU = um treino por vez.** O segundo job **espera** o primeiro (fila
> FIFO) — `gpuhub queue` mostra a ordem. Não é travamento.

---

## 5. Dados grandes e o Drive web

A pasta do script vai **inteira** a cada `submit`; o CLI avisa se passar de
**50 MB**. Então separe:

- **código** → na pasta do script (sobe junto);
- **datasets, checkpoints, pesos** → em **`/data` no hub**, lido por caminho
  absoluto. Não ponha dataset dentro da pasta do código.

```python
import os
DATA = os.environ.get("GPUHUB_DATA", "/data")
dataset = carregar(f"{DATA}/meu-dataset")
```

Pra subir/baixar/organizar esses arquivos sem terminal, use o **Drive web**:

**https://gpuhub.local/files/** — gerenciador de arquivos do `/data` no
navegador (upload, download, pastas). Login próprio do drive; peça o acesso ao
admin ([Admin B](#admin-b--o-drive-filebrowser)).

---

## 6. Papéis e o que cada um pode

Cada conta tem um papel no realm `lab` (veja com `gpuhub whoami`). O proxy
aplica o papel **por método HTTP**:

| Papel | Pode submeter/parar jobs? | Para quem |
|---|---|---|
| `admin` | sim | administra a plataforma e as contas |
| `professor` | sim | orienta, executa jobs |
| `pesquisador` | sim | executa jobs, usa a GPU |
| `viewer` | **não** (só lê status/logs) | acompanhar sem executar |

Token sem nenhum desses papéis → `403 conta sem papel no hub`. `viewer` tentando
submeter → `403 papel somente-leitura`.

---

## 7. Resolução de problemas

| Sintoma | Causa / solução |
|---|---|
| `gpuhub: command not found` | PATH não recarregou. Terminal novo ou `source ~/.bashrc`. |
| `o comando ray nao esta no PATH` | `export PATH="$HOME/.gpuhub-venv/bin:$PATH"` (o instalador já põe no `~/.bashrc`). |
| `nao consegui falar com https://gpuhub.local` | Fora da rede do hub. Está no campus/VPN? O hub está no ar? |
| `No route to host` | Fora do campus — conecte na VPN do IFCE. |
| `sessao expirou. Rode: gpuhub login` | Token velho demais. Refaça `gpuhub login`. |
| HTTP 401 ao submeter | Sem token válido — `gpuhub login`. |
| HTTP 403 "sem papel" / "somente-leitura" | Sua conta não tem papel executor. Peça ao admin pra ajustar. |
| Job morre com `No module named pip` | Problema no ambiente do hub — avise o admin. |
| Versões de Python incompatíveis | Cliente e hub precisam da mesma major.minor (**3.11**). Não troque o venv na mão. |

---

# Para o administrador

## Admin A — Registrar e remover usuários

As contas vivem no **Keycloak** (realm `lab`). O antigo `scripts/gpuhub-user.sh`
era da época do `basic_auth` e **não vale mais** — ignore-o.

Há dois caminhos. Pelo **console web** (mais simples):

1. Acesse **https://gpuhub.local/auth/admin/** (só da rede do campus) e entre
   como admin (`gabriel`, ou o admin de bootstrap).
2. Troque pro realm **`lab`** (seletor no topo à esquerda).
3. **Users → Add user**: `Username` (minúsculas), `Email`, marque **Email
   verified**, salve.
4. **Credentials → Set password**: defina a senha e **desligue "Temporary"**
   (senão força troca no 1º login).
5. **Role mapping → Assign role**: `professor`, `pesquisador`, `viewer` ou `admin`.
6. Passe usuário e senha **por canal privado**. A pessoa roda `gpuhub login`.

Pelo **terminal** (`kcadm`, útil pra criar vários) — o container é
`keycloak-keycloak-1`:

```bash
cd ~/GpuHub
P=$(grep KC_BOOTSTRAP_ADMIN_PASSWORD keycloak/.env | cut -d= -f2)
KC="docker exec keycloak-keycloak-1 /opt/keycloak/bin/kcadm.sh"

$KC config credentials --server http://localhost:8080/auth --realm master --user admin --password "$P"

# criar um usuário com papel (repita por pessoa)
$KC create users -r lab -s username=fulano -s enabled=true -s emailVerified=true
$KC set-password -r lab --username fulano --new-password 'SENHA_FORTE'      # +--temporary pra forçar troca
$KC add-roles   -r lab --uusername fulano --rolename pesquisador
```

Remover acesso: no console **Users →** (a pessoa) **→ Delete**, ou
`$KC delete "users/$($KC get users -r lab -q username=fulano --fields id --format csv|tr -d '\"')" -r lab`.

> Os usuários **não** estão no `lab-realm.json` (são criados por `kcadm`/console),
> então o `--import-realm` não os recria. É o backup do Postgres do Keycloak que
> os preserva ([Admin D](#admin-d--backup-e-restauração)).

## Admin B — O Drive (Filebrowser)

O drive em **https://gpuhub.local/files/** é um [Filebrowser](https://filebrowser.org/)
servindo o `/data`. Tem **login próprio** (não é o Keycloak).

Senha inicial do admin do filebrowser (gerada no 1º boot — **troque na UI**):

```bash
docker logs gpuhub-filebrowser 2>&1 | grep -i password
```

Entre em `/files/` como `admin`, troque a senha em **Settings**, e crie usuários
do drive conforme precisar. O serviço roda como uid 2000 nos grupos `lab`/`vigia`,
então lê e escreve em `/data` respeitando as permissões.

## Admin C — Operação do hub

São **dois** composes: o do hub (`docker/`) e o do Keycloak (`keycloak/`).

```bash
# Hub = Ray + Caddy + Filebrowser (gerenciado pelo systemd)
systemctl start|stop|status gpuhub
docker compose -f ~/GpuHub/docker/docker-compose.yml logs -f gpuhub   # ou caddy / filebrowser

# Keycloak + Postgres (compose separado; NÃO está no systemd)
cd ~/GpuHub/keycloak && docker compose up -d
docker compose logs -f keycloak
```

O `gpuhub.service` roda `docker compose up -d` em `docker/` no boot. O Keycloak
tem `restart: unless-stopped`, então volta sozinho após um reboot **depois** de
subir uma vez — mas não é o systemd quem o gerencia.

- **Primeira vez numa máquina nova:** veja o `README.md` (§ *Setup do hub*):
  `sudo ./scripts/install_host.sh --users ... --firewall`, subir os dois composes,
  e `scripts/simplify-deploy.sh` (liga o drive `/files` e o console `/auth/admin`).
- **Quem opera** precisa estar no grupo `docker` (o `--users` do `install_host.sh`
  cuida disso) — senão não reinicia o hub.

## Admin D — Backup e restauração

```bash
bash ~/GpuHub/scripts/backup.sh
```

Guarda em `~/gpuhub-backups/<timestamp>/` e mantém os **últimos 7**. Pega o
Postgres do Keycloak (realm **+ usuários**), o DB do Filebrowser e os configs
(composes, Caddyfiles, realm, `.env` com segredos — por isso a pasta fica só pro
dono). O `/data` **não** entra por padrão (é grande); pra incluir:
`BACKUP_DATA_DEST=user@host:/caminho bash scripts/backup.sh`.

Cron diário (2h) sugerido:

```cron
0 2 * * *  /home/labnuven/GpuHub/scripts/backup.sh >> ~/gpuhub-backups/cron.log 2>&1
```

Restaurar o Keycloak (exemplo): suba o `kc-db`, e
`gunzip -c keycloak-db.sql.gz | docker exec -i keycloak-kc-db-1 psql -U keycloak keycloak`.

## Admin E — Verificar a plataforma (smoke-test)

```bash
bash ~/GpuHub/scripts/smoke-test.sh
```

Valida ponta a ponta num comando: containers, GPU no container, Keycloak, rotas
públicas, **gate + RBAC** (sem token → 401; viewer POST → 403; writer → 200),
drive, console e um **job real na GPU** — com tokens descartáveis que ele mesmo
limpa no fim. Termina em `>>> PLATAFORMA OK <<<`.

---

## Como está montado

```
dev ──HTTPS + Bearer JWT──> Caddy :443 ──┬─ /            → Ray Jobs API 127.0.0.1:8265 → GPU
                                          ├─ /auth/*      → Keycloak 127.0.0.1:8080 (realm lab)
                                          ├─ /files/*     → Filebrowser 127.0.0.1:8090 (/data)
                                          └─ /ca.crt /install /gpuhub  (públicos, pré-credencial)
```

Só o Caddy escuta na rede (443). A Jobs API do Ray (`:8265`) e as portas internas
(`6379`, `10001`) ficam em `127.0.0.1` + firewall: quem alcança a `8265` executa
código **sem senha**. O Caddy valida o JWT do Keycloak (realm `lab`, audience
`gpuhub-api`), aplica papel por método, e proxia pro Ray. O container roda como
uid 2000 (não-root) e a GPU entra via **CDI** (`nvidia.com/gpu=all`), que
sobrevive a `systemctl daemon-reload` (o caminho legado não sobrevivia).

Detalhes de infra (descoberta de IP, versão do Python, deps pré-instaladas,
segunda GPU, abrir pra internet) estão no [`README.md`](../README.md) e, pro
cutover do Keycloak, em [`keycloak/NEXT-CUTOVER.md`](../keycloak/NEXT-CUTOVER.md).
