"""Conexão do lado do dev: escolhe se o código roda local ou no hub remoto."""
import os

import ray

DEFAULT_RAY_CLIENT_PORT = 10001


def connect(target=None, address=None, ray_client_port=DEFAULT_RAY_CLIENT_PORT):
    """Conecta a sessão atual ao ambiente de treino escolhido.

    target:
        "local" -> roda na própria máquina (bom para testar o script antes
                   de mandar pro hub). Lido de GPUHUB_TARGET se omitido.
        "hub"   -> roda na GPU do hub, via Ray client.

    address:
        IP/hostname do hub quando target="hub". Lido de GPUHUB_ADDRESS
        se omitido.
    """
    if ray.is_initialized():
        return

    target = target or os.environ.get("GPUHUB_TARGET", "local")

    if target == "local":
        ray.init(namespace="gpuhub")
        return

    if target == "hub":
        address = address or os.environ.get("GPUHUB_ADDRESS")
        if not address:
            raise ValueError(
                "target='hub' precisa do endereço do hub "
                "(passe address=... ou defina a variável GPUHUB_ADDRESS)"
            )
        ray.init(address=f"ray://{address}:{ray_client_port}", namespace="gpuhub")
        return

    raise ValueError(f"target inválido: {target!r} (use 'local' ou 'hub')")


def disconnect():
    if ray.is_initialized():
        ray.shutdown()
