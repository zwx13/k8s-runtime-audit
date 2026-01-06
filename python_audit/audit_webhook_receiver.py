#!/usr/bin/env python3

'''
Kubernetes audit logs define a total order over API requests as processed by the kube-apiserver
which we use as the execution trace for our TLA+ specification.
'''

import os
import json
from contextlib import asynccontextmanager

from fastapi import FastAPI, Request
import nats

from stream_functions import ensure_stream

# --- config ---
# get env var but if unset use default
# connect to the running container
NATS_SERVER = os.environ.get("NATS_URL", "nats://localhost:4222")
JS_STREAM = "AUDIT"
# save everything
RAW_SUBJECT = "audit.full"

# what subjects we want to exist
WANTED_SUBJECTS=["audit.full", "audit.node.per.tenant"]


# fastAPI will run this function automatically when the app starts/stops
@asynccontextmanager
async def lifespan(app: FastAPI):
    # connect to NATS and JetStream before serving
    nc = await nats.connect(servers=[NATS_SERVER])
    js = nc.jetstream()
    await ensure_stream(js, JS_STREAM, WANTED_SUBJECTS)
    # nc is created dynamically here
    app.state.nc = nc
    # print(app.state)
    # print(app.state.nc)
    # store the NATS JetStream context in app state
    app.state.js = js
    print(f"Connected to NATS (JetStream) at {NATS_SERVER}")
    try:
        yield
    finally:
        # clean shutdown by draining both
        await nc.drain()
        print("NATS connection closed")

app = FastAPI(lifespan=lifespan)

@app.get("/healthz")
async def healthz():
    try:
        info = await app.state.js.stream_info(JS_STREAM)
        return {"status": "ok", "stream": JS_STREAM, "subjects": info.config.subjects}
    except Exception as e:
        return {"status": "error", "detail": str(e)}

# define the webhook and handle incoming json (POST only)
@app.post("/")
async def receive_audit_log(request: Request):
    """
    Receive Kubernetes audit events (single object or EventList),
    and publish EVERY item to JetStream subject 'audit.full'.
    """
    data = await request.json()
    # return list of events or event
    items = data.get("items", []) if data.get("kind") == "EventList" else [data]

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
    # for debugging, if ever
    return {"status": "ok", "published": published, "errors": errors}

"""
Entry point for running the FastAPI audit webhook server.

This block starts the ASGI server using Uvicorn:

- "audit_webhook_receiver:app" refers to the FastAPI instance app in this module
- host="0.0.0.0" makes the server accessible from any network interface
- port=9770 sets the HTTP port to listen for incoming Kubernetes audit POST requests

When the server starts:
1. The lifespan function is executed to connect to NATS and JetStream,
2. The FastAPI server begins listening for HTTP POST requests,
3. Each incoming audit event is forwarded to the configured JetStream subject.
"""

if __name__ == "__main__":
    import uvicorn
    uvicorn.run("audit_webhook_receiver:app", host="0.0.0.0", port=9770)
