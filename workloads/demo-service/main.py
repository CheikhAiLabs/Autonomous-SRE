import os
import random

from fastapi import FastAPI, Response
from prometheus_client import CONTENT_TYPE_LATEST, Counter, generate_latest

app = FastAPI(title="SRE Demo Service")
requests_total = Counter("sre_demo_requests_total", "Demo requests", ["status"])
error_rate = float(os.getenv("ERROR_RATE", "0"))


@app.get("/")
async def root() -> Response:
    if random.random() < error_rate:
        requests_total.labels(status="500").inc()
        return Response("simulated failure\n", status_code=500)
    requests_total.labels(status="200").inc()
    return Response("healthy\n", status_code=200)


@app.get("/healthz")
async def healthz() -> dict[str, str]:
    return {"status": "ok"}


@app.get("/metrics")
async def metrics() -> Response:
    return Response(generate_latest(), media_type=CONTENT_TYPE_LATEST)
