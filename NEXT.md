# O que falta fazer

Escrito em 2026-09-17, depois da sessão que pôs autenticação na frente do hub.
Estado do repo nesse ponto: commit `6d25af1`, nada publicado (`git push`
pendente).

---

## 1. Estado atual

### Está no ar e verificado

| Coisa | Estado |
|---|---|
| Ray head node | rodando como uid 2000 (não-root), 0 restarts |
| GPU | RTX 5060 Ti 16 GB, torch 2.13+cu130 com `sm_120`, job real rodou |
| Caddy | TLS com CA interna, basic auth por conta nomeada |
| `gpuhub login` / `gpuhub submit` | testado ponta a ponta, job chegou na GPU |
| `/install` e `/gpuhub` | servidos pelo hub sem auth, HTTP 200 |
| Autenticação | sem credencial → 401, senha errada → 401, certa → 200 |
| Descoberta de IP | espera a rede, ignora bridge do Docker, testada em 3 cenários |

Contas criadas até agora: `gabriel` (**trocar a senha** — ela apareceu no
terminal da sessão: `./scripts/gpuhub-user.sh add gabriel`).

### Está quebrado agora

**As máquinas de dev não submetem.** O `vigia/gpuclient.py` do vigia-ia-lab
fala HTTP puro com `10.50.21.14:8265`, e essa porta passou a escutar só em
`127.0.0.1`. O erro que aparece lá é `ConnectionRefusedError: [Errno 111]`.
Isso é consequência direta da mudança de autenticação, não um bug solto — ver
decisão A.

---

## 2. Decisões que só você toma

### A. Como destravar as máquinas de dev

| Opção | Custo | Efeito na segurança |
|---|---|---|
| **A1.** Migrar o pessoal pro `gpuhub submit` | cada dev roda 2 comandos | nenhum |
| **A2.** Ajustar `vigia/gpuclient.py` pro endereço autenticado | mexer em outro repo | nenhum |
| **A3.** Reabrir a 8265 na LAN | 1 linha no compose | volta a ser execução de código sem senha |

A2 é a que mantém o F5 do VSCode funcionando **e** o login. O repo
`vigia-ia-lab` não está nesta máquina — só em `/home/grshard/code/` no PC de
dev. O que precisa mudar lá: endereço vira `https://gpuhub.local`, e o cliente
passa a mandar `Authorization: Basic <base64 user:senha>` e a confiar na CA do
hub (`~/.gpuhub/ca.crt`). O `bin/gpuhub` deste repo já faz exatamente isso —
serve de referência.

A3 desfaz o trabalho do dia. Se for por esse caminho, é `GPUHUB_DASHBOARD_HOST`
em `docker/docker-compose.yml`, e a regra de ufw vira a única proteção.

### B. Qual é o diretório de dados de verdade

Hoje isso está ambíguo e vai morder no próximo treino que salvar checkpoint:

- o container monta `/mnt/pesquisa`, que está **vazio**
- o `fstab` quer montar ali um CIFS de **outra máquina**
  (`//labnuven-b650m-gaming-wifi-3.local/pesquisa`) — não está montado
- o Samba **desta** máquina serve `[Pesquisa]` a partir de `/data/pesquisa`
  (disco de 1,8 TB, 1,5 T livre), restrito ao grupo `vigia` (richard, ronielle)
- o container roda como uid 2000, que **não** está no grupo `vigia` — mesmo
  montando o caminho certo, não leria

Decidido qual é o certo, o conserto é: ajustar o volume em
`docker/docker-compose.yml` e adicionar `group_add: ["1003"]` (gid do `vigia`)
no serviço `gpuhub`.

Cuidado com um detalhe: montar um ponto CIFS dentro do Docker é frágil. Se o
CIFS montar **depois** do container subir, o container continua vendo o
diretório vazio de antes, sem erro nenhum. Se for por esse caminho, o CIFS
precisa subir antes do `gpuhub.service`.

---

## 3. Passos, em ordem

### Passo 1 — fechar o furo (precisa de root, bloqueia o resto)

Hoje, **qualquer máquina da rede executa código no hub sem passar pelo login**,
pelas portas 6379 e 10001. Confirmado por teste de fora do host:

```
porta 443:   ABERTA   ← proxy, com login      (ok)
porta 8265:  fechada  ← Jobs API              (ok)
porta 6379:  ABERTA   ← Ray GCS, sem auth     (furo)
porta 10001: ABERTA   ← Ray Client, sem auth  (furo)
```

O Ray binda essas duas no IP do nó e não aceita restringir por flag — conferido
no `ray start --help`. Firewall é o único controle:

```bash
sudo ./scripts/install_host.sh --users henrique,matheusalmeida,richard --firewall
```

Isso também: cria o grupo `gpuhub`, põe essa gente no grupo `docker` (hoje só o
`labnuven` consegue operar o hub), ajusta o dono de `/mnt/pesquisa`, instala o
`gpuhub.service` e faz o avahi anunciar só a interface da LAN.

O script mostra as regras de firewall antes e depois e pede confirmação. Ele
**não** mexe em política padrão nem em SSH de propósito: fazer isso numa
máquina acessada por AnyDesk tranca vocês do lado de fora.

### Passo 2 — destravar as máquinas de dev

Conforme a decisão A. Se for A1, em cada PC:

```bash
curl -fsSLk https://gpuhub.local/install | bash
gpuhub login <nome>
gpuhub submit train/train.py
```

### Passo 3 — resolver os dados

Conforme a decisão B.

### Passo 4 — publicar o repo

```bash
git push origin master
```

Nada foi publicado. O README manda baixar o cliente do GitHub, o que só passa a
funcionar depois do push. (O `/install` servido pelo próprio hub não depende
disso — é o caminho recomendado mesmo.)

### Passo 5 — verificar que o `requirements.txt` voltou a funcionar

O rebuild que adiciona `pip`, `onnx` e `onnxscript` estava rodando quando a
sessão acabou. Confirme que pegou:

```bash
docker exec gpuhub python -c "import onnx, onnxscript, pip; print('ok')"
```

E que um job com `requirements.txt` ao lado do script sobe sem
`No module named pip`.

---

## 4. Coisas que custaram caro pra descobrir

Anotadas pra ninguém redescobrir.

**O `uv venv` cria o ambiente sem `pip`.** O Ray monta o ambiente de um job com
`requirements.txt` derivando um virtualenv do ambiente do hub e chamando
`python -m pip`. Sem pip no base, todo job com `requirements.txt` morre com
`No module named pip`. Quebrado desde `d384cb5`. **É por isso que dependência
vinha sendo instalada na mão com `docker exec ... pip install`** — e some toda
vez que o container é recriado.

**O `uv` guarda o interpretador em `/root/.local`, que é `0700`.** Rodando o
container como usuário comum, o venv vira um symlink que só o root segue, e o
container entra em loop com `bad interpreter: Permission denied`. Resolvido com
`UV_PYTHON_INSTALL_DIR=/opt/uv-python`.

**`hostname -I` não tem ordem estável.** Se o Docker sobe antes da rede, o
primeiro IP é o da `docker0`. O Ray fixa o endereço no start, então o cluster
nascia bindado em `172.17.0.1` e ficava invisível pra rede — sem erro no log,
só um `Local node IP: 172.17.0.1` no meio do output. Resolvido em
`scripts/lib_hub_ip.sh`.

**O avahi anuncia todas as interfaces.** Sem `allow-interfaces`, quem procurar
`gpuhub.local` na rede pode receber `172.17.0.1`, que é inalcançável. O
`install_host.sh` ajusta isso.

**`network_mode: host` faz o ufw valer pro container.** Com `bridge` + `ports`,
o Docker fura o ufw e as regras param de valer sem avisar. Se alguém trocar
isso, o firewall do Passo 1 vira decoração.

**O IP da máquina não é estável.** Ela tem cabo e Wi-Fi, os dois em DHCP, e
trocou de interface sozinha no meio da sessão (`10.50.25.187` → `10.50.21.14`).
Por isso o padrão é `gpuhub.local` e não IP. Reserva de DHCP no roteador do lab
resolve de vez.

---

## 5. Depois, quando der

- **Limite de tentativa de login.** O Caddy não traz isso de fábrica. Hoje nada
  impede alguém na rede de ficar chutando senha.
- **Isolamento entre pessoas.** Todos os jobs rodam como o mesmo uid 2000 e
  compartilham `/mnt/pesquisa`. Está bom pro lab; não está pra quem você não
  conhece.
- **Cota e prioridade.** A fila do Ray é FIFO pura: um treino de 3 dias segura
  todo mundo e não há como matá-lo por política. O `--metadata user=` que o
  `gpuhub submit` já manda é a base pra construir isso.
- **Histórico de jobs some no restart.** `/tmp/ray` vive dentro do container.
- **Segunda GPU.** O head não fixa mais `--num-gpus`: uma segunda placa nesta
  máquina já entra sozinha. Uma segunda **máquina** precisa alcançar a 6379 e a
  faixa de portas do Ray — que o Passo 1 fecha. É ajuste de regra, não
  redesenho.
- **Mudar o hub pra `/opt`.** O repo mora em `/home/labnuven` (modo 750): os
  outros 7 usuários da máquina não conseguem nem ler.

---

## 6. Comandos do dia a dia

```bash
# operar
systemctl start|stop|status gpuhub
docker compose -f docker/docker-compose.yml logs -f gpuhub

# contas
./scripts/gpuhub-user.sh add|remove|list <nome>

# ver o que está rodando
docker exec gpuhub ray status
gpuhub queue
```
