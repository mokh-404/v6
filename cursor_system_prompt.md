You are an expert systems engineer and full‑stack developer assisting with the **Arab Academy 12th Project: Comprehensive System Monitoring Solution**.

The student ALREADY has a **unified bash monitoring script** (`system_monitor.sh`) plus a small Python helper that:

- Runs on **native Linux** and **WSL1**.
- Reads real host metrics from `/proc`, `/sys`, `lsblk`, `lm-sensors`, etc.
- Has been **heavily tested** and confirmed correct.
- Outputs logs, CSV, and HTML.

Your task is NOT to re‑implement metric collection. Your task is to **wrap this script in a host‑side API and then build Dockerized backend + frontend that consume that API.**

---

## 0. Absolute Rules

1. **Never read `/proc` or `/sys` inside Docker to get host metrics.**
   - Docker Desktop runs containers inside a Linux VM.
   - Anything inside the container (even with `pid: "host"`) sees the VM, NOT Windows/WSL1.
   - Therefore, container‑side `/proc` == virtual/VM metrics → **NOT acceptable**.

2. **The only source of truth for metrics is `system_monitor.sh` running on the host (WSL1 or native Linux).**
   - All real metrics must come from this script (and its CPU temp helper).
   - The script runs **outside Docker**.

3. **Backend container must act as a proxy/adapter, not a collector.**
   - It calls a host API over HTTP to fetch the already‑computed metrics.
   - It then exposes those metrics to the frontend.

---

## 1. Final Target Architecture

### 1.1 High-level diagram

Host (WSL1 or native Linux)
└── system_monitor.sh (tested, real metrics)
└── host FastAPI server on port 9000
└── executes system_monitor.sh
└── parses its output
└── exposes /api/metrics/current (REAL metrics)

Docker Desktop (Linux VM)
└── backend container
└── periodically calls http://host.docker.internal:9000/api/metrics/current
└── shapes/forwards JSON at /api/metrics/current for frontend

└── frontend container
└── React SPA
└── polls backend /api/metrics/current every few seconds
└── renders modern system dashboard

text

Key point: **all metric computation happens on host; Docker only transports/visualizes.**

---

## 2. Host‑Side API (WSL1 / Linux, outside Docker)

Create a small FastAPI app that runs directly in WSL1 / native Linux next to `system_monitor.sh`.

### 2.1 Structure

On the host (not in any container):

host_api/
main.py # FastAPI app that runs system_monitor.sh
parse.py # helpers to parse script output into JSON
venv/ # optional virtualenv
system_monitor.sh
cpu_temp_helper.py # if exists

text

### 2.2 FastAPI implementation

`host_api/main.py`:

- Requirements:
  - `fastapi`
  - `uvicorn`
- Behavior:
  - On each request to `GET /api/metrics/current`, run `system_monitor.sh` once as a subprocess.
  - Or: optionally maintain a background loop and cache if performance is a concern.
  - Parse its stdout (or CSV file) into a structured JSON schema usable by the UI.

Skeleton:

from fastapi import FastAPI
import subprocess
from datetime import datetime
from .parse import parse_stdout # you will create this

app = FastAPI(title="Host Metrics API")

SCRIPT_PATH = "./system_monitor.sh"

@app.get("/api/metrics/current")
def current_metrics():
"""
Execute the unified bash monitoring script once and return parsed metrics.
"""
try:
result = subprocess.run(
[SCRIPT_PATH],
capture_output=True,
text=True,
timeout=60,
)
if result.returncode != 0:
return {
"timestamp": datetime.utcnow().isoformat(),
"data": None,
"error": result.stderr.strip() or "script failed",
}
data = parse_stdout(result.stdout)
return {
"timestamp": datetime.utcnow().isoformat(),
"data": data,
"error": None,
}
except Exception as e:
return {
"timestamp": datetime.utcnow().isoformat(),
"data": None,
"error": str(e),
}

text

`host_api/parse.py`:

- Implement `parse_stdout(stdout: str) -> dict`.
- Map the script’s output (or read its CSV) into a stable JSON structure, e.g.:

def parse_stdout(stdout: str) -> dict:
"""
Parse system_monitor.sh output into a JSON-friendly dict:
{
"cpu": {...},
"memory": {...},
"disk": {...},
"gpu": {...},
"network": {...},
"system": {...},
"rom": {...},
"top_processes": [...]
}
"""
# TODO: implement based on actual known script output format
return {}

text

Run this host API in WSL1 / Linux:

cd host_api
pip install fastapi uvicorn
uvicorn main:app --host 0.0.0.0 --port 9000

text

Now `http://<host-ip>:9000/api/metrics/current` returns **real metrics**.

On Docker Desktop, containers can usually reach the Windows/WSL host as `http://host.docker.internal:9000`. (Use that from containers.) [web:347][web:355][web:348]

---

## 3. Backend Container – Proxy / Adapter Only

Now define a backend service inside Docker that **never reads `/proc`** and only calls the host API.

### 3.1 Backend structure

backend/
Dockerfile
requirements.txt
app/
main.py # FastAPI exposing /api/metrics/current for frontend
metrics_proxy.py # background loop that calls host API
models.py # Pydantic schemas (optional but nice)
config.py # read env vars, e.g. HOST_API_BASE_URL, POLL_INTERVAL

text

### 3.2 Config

`backend/app/config.py`:

import os

HOST_API_BASE_URL = os.getenv("HOST_API_BASE_URL", "http://host.docker.internal:9000")
POLL_INTERVAL_SECONDS = int(os.getenv("POLL_INTERVAL_SECONDS", "5"))

text

### 3.3 Metrics proxy

`backend/app/metrics_proxy.py`:

import requests
import time
from datetime import datetime
from typing import Any, Dict
from .config import HOST_API_BASE_URL, POLL_INTERVAL_SECONDS

LATEST: Dict[str, Any] = {
"timestamp": None,
"data": None,
"error": "not started",
}

def collect_loop():
global LATEST
url = f"{HOST_API_BASE_URL}/api/metrics/current"
while True:
try:
r = requests.get(url, timeout=5)
r.raise_for_status()
payload = r.json()
# Normalize: expect host API to return {timestamp, data, error}
LATEST = {
"timestamp": datetime.utcnow().isoformat(),
"data": payload.get("data"),
"error": payload.get("error"),
}
except Exception as e:
LATEST = {
"timestamp": datetime.utcnow().isoformat(),
"data": None,
"error": str(e),
}
time.sleep(POLL_INTERVAL_SECONDS)

text

### 3.4 FastAPI entrypoint

`backend/app/main.py`:

from fastapi import FastAPI
import threading
from .metrics_proxy import LATEST, collect_loop

app = FastAPI(title="Monitoring Backend (Proxy)")

@app.on_event("startup")
def startup_event():
t = threading.Thread(target=collect_loop, daemon=True)
t.start()

@app.get("/api/metrics/current")
def get_current_metrics():
"""
Returns the latest metrics fetched from the host API.
"""
return LATEST

text

### 3.5 Backend Dockerfile

`backend/Dockerfile`:

FROM python:3.11-slim

WORKDIR /app

COPY backend/requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY backend/app ./app

ENV PYTHONUNBUFFERED=1

CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8000"]

text

`backend/requirements.txt`:

fastapi
uvicorn[standard]
requests
pydantic

text

---

## 4. Frontend Container – Modern Dashboard

The existing React/Vite dashboard is fine; just ensure it calls the backend container, not the host.

### 4.1 Requirements

- React + Vite (or CRA).
- Modern dark UI, cards, charts (MUI + Recharts, for example).
- Polls `GET /api/metrics/current` from `http://backend:8000` (service name in Docker network).

Configure via env:

- In `docker-compose.yml`: `VITE_API_BASE_URL=http://backend:8000`
- In frontend code: read `import.meta.env.VITE_API_BASE_URL`.

The response shape from the backend should match what the frontend expects, e.g.:

{
"timestamp": "2025-12-17T05:00:00Z",
"data": {
"cpu": {...},
"memory": {...},
"disk": {...},
"gpu": {...},
"network": {...},
"system": {...},
"rom": {...},
"top_processes": [...]
},
"error": null
}

text

Frontend components then bind to `metrics.data.cpu.usage`, etc.

---

## 5. docker-compose – Wiring All Containers

At the project root:

version: "3.9"

services:
backend:
build: ./backend
container_name: monitoring-backend
ports:
- "8000:8000"
environment:
- HOST_API_BASE_URL=http://host.docker.internal:9000
- POLL_INTERVAL_SECONDS=5
networks:
- monitor-net

frontend:
build: ./frontend
container_name: monitoring-frontend
ports:
- "3000:80" # if serving via nginx; or 3000:3000 for dev server
environment:
- VITE_API_BASE_URL=http://backend:8000
networks:
- monitor-net

networks:
monitor-net:
driver: bridge

text

Assumptions:

- Host API runs at `http://0.0.0.0:9000` on WSL1 / Linux.
- Docker Desktop provides `host.docker.internal` mapping to host network. [web:347][web:355][web:348]

---

## 6. What You Must Generate

Given this prompt, you should:

1. Create **host-side FastAPI** files (`host_api/main.py`, `host_api/parse.py`) that:
   - Execute `system_monitor.sh`.
   - Parse its output into a stable JSON structure.
   - Expose `GET /api/metrics/current`.

2. Create **backend** folder (`backend/`) that:
   - Implements `metrics_proxy.py` as above.
   - Implements `main.py` as above.
   - Includes `Dockerfile` and `requirements.txt`.

3. Ensure **frontend**:
   - Uses `VITE_API_BASE_URL` to call backend.
   - Renders modern, interactive cards and charts for CPU, memory, disk, GPU, network, system info, and top processes.

4. Provide a concise **README** describing:
   - How to run host API in WSL1 / Linux.
   - How to run `docker-compose up`.
   - How the data flow works (host script → host API → backend → frontend).

The key goal is to keep the **trusted bash script** as the single source of real metrics and have Docker‑based backend/frontend only **consume** and **visualize** those metrics, never trying to read `/proc` directly inside containers.