"""Backend web do dashboard do gpuhub: mostra quem está usando a GPU agora."""
import subprocess
from pathlib import Path

import ray
from fastapi import FastAPI
from fastapi.responses import JSONResponse
from fastapi.staticfiles import StaticFiles

from gpuhub.tracker import get_tracker

STATIC_DIR = Path(__file__).parent / "static"

app = FastAPI(title="GPU Hub Dashboard")


@app.on_event("startup")
def _connect_to_cluster():
    if not ray.is_initialized():
        ray.init(address="auto", namespace="gpuhub")


@app.get("/api/status")
def status():
    tracker = get_tracker()
    state = ray.get(tracker.get_state.remote())
    return JSONResponse(state)


@app.get("/api/gpu")
def gpu():
    try:
        out = subprocess.check_output(
            [
                "nvidia-smi",
                "--query-gpu=name,utilization.gpu,memory.used,memory.total,temperature.gpu",
                "--format=csv,noheader,nounits",
            ],
            text=True,
            timeout=5,
        )
    except Exception as exc:
        return JSONResponse({"error": str(exc)}, status_code=500)

    rows = []
    for line in out.strip().splitlines():
        name, util, mem_used, mem_total, temp = [p.strip() for p in line.split(",")]
        rows.append(
            {
                "name": name,
                "utilization_pct": float(util),
                "memory_used_mb": float(mem_used),
                "memory_total_mb": float(mem_total),
                "temperature_c": float(temp),
            }
        )
    return JSONResponse(rows)


app.mount("/", StaticFiles(directory=str(STATIC_DIR), html=True), name="static")
