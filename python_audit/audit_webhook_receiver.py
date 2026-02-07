#!/usr/bin/env python3

"""
Kubernetes Audit Webhook → NATS JetStream ingester.

Kubernetes audit logs are produced by the kube-apiserver and provide a total order over
API requests as processed by the apiserver. We treat this ordered stream as the input
trace for downstream analysis (TLA+).

This service:
- Accepts Kubernetes audit webhook POSTs (single event or EventList),
- Publishes each event to a JetStream subject (default: audit.full) in a configured stream,
- Exposes /healthz for readiness checks.
"""

from __future__ import annotations

import json
import logging
import os
from contextlib import asynccontextmanager
from datetime import timedelta
from typing import Final

import nats
from fastapi import FastAPI, HTTPException, Request

from stream_functions import ensure_stream

log = logging.getLogger(__name__)

# -----------------------------------------------------------------------------
# Config helpers
# -----------------------------------------------------------------------------
def env_str(name: str, default: str) -> str:
    v = os.environ.get(name, default).strip()
    return v

def env_int(name: str, default: int) -> int:
    v = os.environ.get(name)
    if v is None:
        return default
    try:
        return int(v)
    except ValueError as e:
        raise RuntimeError(f"Invalid int for {name}={v!r}") from e

def env_duration_sec(name: str, default_seconds: int) -> timedelta:
    """Parse duratiopn from env var as seconds
       Example: RETENTION_SECONDS=86400 (1 day)"""
    seconds = env_int(name, default_seconds)
    if seconds < 0:
        raise RuntimeError(f"{name} must be >= 0")
    return timedelta(seconds=seconds)

# -----------------------------------------------------------------------------
# Configuration
# -----------------------------------------------------------------------------

NATS_SERVER: Final[str] = env_str("NATS_URL", "nats://localhost:4222")
JS_STREAM: Final[str] = env_str("JS_STREAM", "AUDIT")
RAW_SUBJECT: Final[str] = env_str("RAW_SUBJECT", "audit.full")

# Retention default is 1 day, override with RETENTION_SECONDS
MAX_AGE: Final[timedelta] = env_duration_sec("RETENTION_SECONDS", 24 * 60 * 60)

# stream subjects we want JetStream to capture (subject appears only after first message).
# note: this script publishes only to RAW_SUBJECT; other subjects may be published by other scripts
WANTED_SUBJECTS: Final[list[str]] = [
    env_str("RAW_SUBJECT", "audit.full"),
    "audit.multitenancy"
]

# -----------------------------------------------------------------------------
# App lifecycle (connect/disconnect NATS)
# -----------------------------------------------------------------------------

@asynccontextmanager
async def lifespan(app: FastAPI):
    nc = await nats.connect(servers=[NATS_SERVER])
    js = nc.jetstream()

    await ensure_stream(
        js,
        stream_name=JS_STREAM, 
        subjects=WANTED_SUBJECTS,
        max_age=MAX_AGE
    )

    app.state.nc = nc
    app.state.js = js
    
    log.info(
        "Connected to NATS JetStream server=%s stream=%s subject=%s max_age=%s",
        NATS_SERVER,
        JS_STREAM,
        RAW_SUBJECT,
        MAX_AGE
    )

    try:
        yield
    finally:
        # drain flushes in-flight publishes and closes nicely
        await nc.drain()
        log.info("NATS connection drained and closed")


app = FastAPI(lifespan=lifespan)

# -----------------------------------------------------------------------------
# Routes
# -----------------------------------------------------------------------------

@app.get("/healthz")
async def healthz():
    """Readiness endpoint: returns ok if JetStream stream exists and is readable."""
    try:
        info = await app.state.js.stream_info(JS_STREAM)
        return {
                "status": "ok", 
                "stream": JS_STREAM, 
                "subjects": list(info.config.subjects),
                "max_age": info.config.max_age
            }
    except Exception as e:
        return {"status": "error", "detail": str(e)}


@app.post("/")
async def receive_audit_log(request: Request):
    """
    Kubernetes audit webhook handler. Supports:
    - A single audit event object
    - An EventList object (kind == "EventList") with an "items" array
    - For batching see https://kubernetes.io/docs/tasks/debug/debug-cluster/audit/#batching
    """
    try:
        data = await request.json()
    except Exception as e:
        raise HTTPException(status_code=400, detail=f"Invalid JSON body: {e}")
    
    if not isinstance(data, dict):
        raise HTTPException(status_code=400, detail="Expected a JSON object (dict)")

    if data.get("kind") == "EventList":
        items = data.get("items", [])
        if not isinstance(items, list):
            raise HTTPException(status_code=400, detail='EventList "items" must be a list')
    else:
        items = [data]

    # reuse the connection created at startup
    js = request.app.state.js
    published = 0

    for item in items:
        try:
            # encode to bytes 4 nats
            payload = json.dumps(item, separators=(",", ":")).encode("utf-8")
            await js.publish(RAW_SUBJECT, payload)  # returns PubAck; we don't use it here
            published += 1
        except Exception:
            log.exception("Failed to publish audit event to subject=%s", RAW_SUBJECT)

    # for debugging, if ever; we can send with curl a log to see the response
    return {"status": "ok", "published": published, "received": len(items), "errors": len(items) - published}

# -----------------------------------------------------------------------------
# Local dev entrypoint
# -----------------------------------------------------------------------------

if __name__ == "__main__":
    logging.basicConfig(
        level=env_str("LOG_LEVEL", "INFO").upper(),
        format="%(asctime)s %(levelname)s %(name)s: %(message)s",
    )

    import uvicorn

    uvicorn.run(app, host="0.0.0.0", port=env_int("PORT", "9770"))
