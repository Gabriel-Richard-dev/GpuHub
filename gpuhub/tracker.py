"""Ator Ray que mantém o estado de quem está usando a GPU do hub."""
import time
from collections import deque

import ray

TRACKER_NAME = "gpuhub_tracker"
TRACKER_NAMESPACE = "gpuhub"
HISTORY_LIMIT = 100


@ray.remote(num_cpus=0)
class JobTracker:
    def __init__(self):
        self._jobs = {}
        self._history = deque(maxlen=HISTORY_LIMIT)

    def register(self, job_id, user, name):
        self._jobs[job_id] = {
            "id": job_id,
            "user": user,
            "name": name,
            "status": "queued",
            "submitted_at": time.time(),
            "started_at": None,
            "ended_at": None,
            "error": None,
        }

    def mark_started(self, job_id):
        job = self._jobs.get(job_id)
        if job is not None:
            job["status"] = "running"
            job["started_at"] = time.time()

    def mark_finished(self, job_id, status, error=None):
        job = self._jobs.pop(job_id, None)
        if job is not None:
            job["status"] = status
            job["ended_at"] = time.time()
            job["error"] = error
            self._history.appendleft(job)

    def get_state(self):
        jobs = list(self._jobs.values())
        return {
            "running": [j for j in jobs if j["status"] == "running"],
            "queued": [j for j in jobs if j["status"] == "queued"],
            "history": list(self._history),
        }


def get_tracker():
    """Retorna (criando se necessário) o ator singleton que rastreia os jobs."""
    return JobTracker.options(
        name=TRACKER_NAME,
        namespace=TRACKER_NAMESPACE,
        lifetime="detached",
        get_if_exists=True,
    ).remote()
