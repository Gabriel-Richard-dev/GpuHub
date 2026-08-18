"""Decorator que transforma uma função de treino numa tarefa remota rastreada."""
import traceback
import uuid

import ray

from .tracker import get_tracker


def gpu_task(num_gpus=1, **ray_kwargs):
    """Decora uma função para rodar como tarefa Ray usando `num_gpus` GPU(s).

    Uso:
        @gpuhub.gpu_task(num_gpus=1)
        def train(epochs):
            ...

        train.run(epochs=5, user="gabriel", name="meu-treino")   # bloqueia até terminar
        ref = train.submit(epochs=5, user="gabriel")             # não bloqueia, retorna ObjectRef
    """

    def decorator(func):
        remote_func = ray.remote(num_gpus=num_gpus, **ray_kwargs)(_tracked(func))

        class GpuTask:
            def submit(self, *args, user="anonimo", name=None, **kwargs):
                tracker = get_tracker()
                job_id = uuid.uuid4().hex[:8]
                job_name = name or func.__name__
                ray.get(tracker.register.remote(job_id, user, job_name))
                return remote_func.remote(job_id, user, job_name, *args, **kwargs)

            def run(self, *args, user="anonimo", name=None, **kwargs):
                return ray.get(self.submit(*args, user=user, name=name, **kwargs))

        task = GpuTask()
        task.__name__ = func.__name__
        task.__doc__ = func.__doc__
        return task

    return decorator


def _tracked(func):
    # sem functools.wraps: copiaria __wrapped__, e o Ray valida os args da
    # chamada remota pela assinatura de `func` em vez da de `inner`.
    def inner(job_id, user, job_name, *args, **kwargs):
        tracker = get_tracker()
        ray.get(tracker.mark_started.remote(job_id))
        try:
            result = func(*args, **kwargs)
        except Exception:
            tracker.mark_finished.remote(job_id, "failed", traceback.format_exc())
            raise
        else:
            tracker.mark_finished.remote(job_id, "completed")
            return result

    inner.__name__ = func.__name__
    return inner
