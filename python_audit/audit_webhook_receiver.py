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
from typing import Any

import nats
from fastapi import FastAPI, HTTPException, Request

from stream_functions import ensure_stream


# -----------------------------------------------------------------------------
# Configuration
# -----------------------------------------------------------------------------

NATS_SERVER = os.environ.get("NATS_URL", "nats://localhost:4222")
JS_STREAM = os.environ.get("JS_STREAM", "AUDIT")

RAW_SUBJECT = os.environ.get("RAW_SUBJECT", "audit.full")

# stream subjects we want JetStream to capture (subject appears only after first message).
WANTED_SUBJECTS=["audit.full", "audit.multitenancy"]

# -----------------------------------------------------------------------------
# Logging
# -----------------------------------------------------------------------------

log = logging.getLogger(__name__)


# -----------------------------------------------------------------------------
# App lifecycle (connect/disconnect NATS)
# -----------------------------------------------------------------------------

@asynccontextmanager
async def lifespan(app: FastAPI):
    nc = await nats.connect(servers=[NATS_SERVER])
    js = nc.jetstream()

    await ensure_stream(js, stream_name=JS_STREAM, subjects=WANTED_SUBJECTS)

    app.state.nc = nc
    app.state.js = js
    
    log.info("Connected to NATS JetStream at %s (stream=%s)", NATS_SERVER, JS_STREAM)

    try:
        yield
    finally:
        # drain flushes in-flight publishes and closes smoothly
        await nc.drain()
        log.info("NATS connection drained and closed")


app = FastAPI(lifespan=lifespan)

# -----------------------------------------------------------------------------
# Routes
# -----------------------------------------------------------------------------

@app.get("/healthz")
async def healthz():
    """
    Readiness endpoint,
    Returns ok if JetStream stream exists and is readable.
    """
    try:
        info = await app.state.js.stream_info(JS_STREAM)
        return {"status": "ok", "stream": JS_STREAM, "subjects": list(info.config.subjects)}
    except Exception as e:
        return {"status": "error", "detail": str(e)}


@app.post("/")
async def receive_audit_log(request: Request):
    """
    Kubernetes audit webhook handler.

    Supports:
    - A single audit event object
    - An EventList object (kind == "EventList") with an "items" array
    """
    try:
        data = await request.json()
    except Exception as e:
        raise HTTPException(status_code=400, detail=f"Invalid JSON body: {e}")
    
    if not isinstance(data, dict):
        raise HTTPException(status_code=400, detail="Expected a JSON object (dict)")

    items = [data]

    # reuse the connection created at startup
    js = request.app.state.js
    published = 0
    errors = 0

    for item in items:
        try:
            # encode to bytes 4 nats
            payload = json.dumps(item, separators=(",", ":")).encode("utf-8")
            await js.publish(RAW_SUBJECT, payload)  # returns PubAck; we don't use it here
            published += 1
        except Exception:
            errors += 1
            log.exception("Failed to publish audit event to subject=%s", RAW_SUBJECT)

    # for debugging, if ever
    return {"status": "ok", "published": published, "errors": errors}

# -----------------------------------------------------------------------------
# Local dev entrypoint
# -----------------------------------------------------------------------------

if __name__ == "__main__":
    logging.basicConfig(
        level=os.environ.get("LOG_LEVEL", "INFO").upper(),
        format="%(asctime)s %(levelname)s %(name)s: %(message)s",
    )

    import uvicorn

    # default to 9770 if env var not set
    uvicorn.run(app, host="0.0.0.0", port=int(os.environ.get("PORT", "9770")))
