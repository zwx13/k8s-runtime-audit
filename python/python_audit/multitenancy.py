"""
NATS JetStream forwarder: AUDIT(audit.full) -> AUDIT_MT(audit.multitenancy)

- Source: durable pull consumer on stream AUDIT, filter_subject=audit.full
- Destination: publish to audit.multitenancy, sotred in stream AUDIT_MT
"""

import asyncio
import os
from pathlib import Path
import json
import logging
from typing import Final
from datetime import timedelta

import nats
from nats.errors import TimeoutError as NatsTimeoutError
from nats.js.api import DeliverPolicy

from config_helpers import env_int, env_float, env_str, env_duration_sec
from utils import keep_alive, monitor_readiness, connect_nats
from stream_functions import ensure_stream, ensure_consumer



log = logging.getLogger(__name__)

# -----------------------------------------------------------------------------
# Configuration
# -----------------------------------------------------------------------------

# Source
NATS_SERVER: Final[str] = env_str("NATS_URL", "nats://127.0.0.1:4222")
RAW_STREAM: Final[str] = env_str("RAW_STREAM", "AUDIT")
SOURCE_SUBJ: Final[str] = env_str("SOURCE_SUBJ", "audit.full")
DURABLE: Final[str] = env_str("DURABLE", "audit-mt-filter")

# Destination
MT_STREAM: Final[str] = env_str("MT_STREAM", "AUDIT_MT")
DEST_SUBJ: Final[str] = env_str("DEST_SUBJ", "audit.multitenancy")
MT_MAX_AGE: Final[timedelta] = env_duration_sec("MT_RETENTION_SECONDS", 30 * 24 * 60 * 60)
MT_DUPLICATE_WINDOW: Final[int] = env_int("MT_DUPLICATE_WINDOW", 180)

# Pool loop
BATCH_SIZE: Final[int] = env_int("BATCH_SIZE", 50)
FETCH_TIMEOUT_S: Final[float] = env_float("FETCH_TIMEOUT_S", 1.0)
IDLE_SLEEP_S: Final[float] = env_float("IDLE_SLEEP_S", 0.2)

# Consumer behavior
ACK_WAIT_S: Final[int] = env_int("ACK_WAIT_S", 30)
# MAX_ACK_PENDING: Final[int] = env_int("MAX_ACK_PENDING", 1)
MAX_DELIVER: Final[int] = env_int("MAX_DELIVER", 5)

# -----------------------------------------------------------------------------
# HELPER ENV VARS
# -----------------------------------------------------------------------------
READ_VERBS = {"get", "list", "watch"}
WRITE_VERBS = {"create", "update", "patch"}
DELETE_VERBS = {"delete", "deletecollection"}

SUCCESS_CODES= {200, 201}

NAMESPACE_RESOURCE_PERMISSION_MAP = {
    # Pods
    ("pods", "get"): "read",
    ("pods", "list"): "read",
    ("pods", "watch"): "read",
    ("pods", "create"): "write",
    ("pods", "update"): "write",
    ("pods", "patch"): "write",
    ("pods", "delete"): "write",
    ("pods", "deletecollection"): "write",

     # Services
    ("services", "get"): "read",
    ("services", "list"): "read",
    ("services", "watch"): "read",
    ("services", "create"): "write",
    ("services", "update"): "write",
    ("services", "patch"): "write",
    ("services", "delete"): "write",
    ("services", "deletecollection"): "write",

    # ConfigMaps
    ("configmaps", "get"): "read",
    ("configmaps", "list"): "read",
    ("configmaps", "watch"): "read",
    ("configmaps", "create"): "write",
    ("configmaps", "update"): "write",
    ("configmaps", "patch"): "write",
    ("configmaps", "delete"): "write",
    ("configmaps", "deletecollection"): "write",

    # Secrets
    ("secrets", "get"): "admin",
    ("secrets", "list"): "admin",
    ("secrets", "watch"): "admin",
    ("secrets", "create"): "admin",
    ("secrets", "update"): "admin",
    ("secrets", "patch"): "admin",
    ("secrets", "delete"): "admin",
    ("secrets", "deletecollection"): "admin",
}

# -----------------------------------------------------------------------------
# Logic
# -----------------------------------------------------------------------------

# def is_real_user_attempt(ev):
#     imp = ev.get("impersonatedUser") or {}
#     user = imp.get("username")

#     return isinstance(user, str) and user != "kubernetes-admin"

def is_access_attempt(ev):
    verb = ev.get("verb")
    obj = ev.get("objectRef") or {}

    resource = obj.get("resource")
    namespace = obj.get("namespace")
    subresource = obj.get("subresource")
    
    if not namespace:
        return False
    
    # Ignore pod/log, pod/exec, pod/status etc.
    if subresource:
        return False

    return (resource, verb) in NAMESPACE_RESOURCE_PERMISSION_MAP

def classify_event(ev: dict) -> str | None:
    verb = ev.get("verb")
    obj = ev.get("objectRef") or {}
    resp = ev.get("responseStatus") or {}

    resource = obj.get("resource")
    code = resp.get("code")

    if verb == "create" and resource == "namespaces" and code in SUCCESS_CODES:
        return "ns.created"

    if verb == "create" and resource == "clusterroles" and code in SUCCESS_CODES:
        return "clusterrole.created"

    if verb == "create" and resource == "rolebindings" and code in SUCCESS_CODES:
        return "rolebinding.created"

    if verb == "create" and resource == "clusterrolebinding" and code in SUCCESS_CODES:
        return "clusterrolebinding.created"

    if is_access_attempt(ev):
        return "access.attempt"
        
    if verb == "delete" and resource == "namespaces" and code in SUCCESS_CODES:
        return "ns.deleted"

    if verb == "delete" and resource == "clusterroles" and code in SUCCESS_CODES:
        return "clusterrole.deleted"

    if verb == "delete" and resource == "rolebindings" and code in SUCCESS_CODES:
        return "rolebinding.deleted"

    if verb == "delete" and resource == "clusterrolebindings" and code in SUCCESS_CODES:
        return "clusterrolebinding.deleted"

    return None

def classify_permission(ev: dict) -> str | None:
    verb = ev.get("verb")
    obj = ev.get("objectRef") or {}
    resource = obj.get("resource")

    type = ev.get("tlaType")

    if type != "access.attempt":
        return None
    
    return NAMESPACE_RESOURCE_PERMISSION_MAP.get((resource, verb), "no-permission")
    

# compact json, no extra spaces
# prepare to send as bytestring
def encode_compact_json(obj) -> bytes:
    return json.dumps(obj, separators=(",", ":")).encode("utf-8")

async def main() -> None:
    liveness_task = asyncio.create_task(keep_alive())

    nc = await connect_nats()

    readiness_task = asyncio.create_task(monitor_readiness(nc))

    js = nc.jetstream()

    sub = None

    try:
        await ensure_stream(
            js,
            stream_name=MT_STREAM,
            subjects=[DEST_SUBJ],
            duplicate_window=MT_DUPLICATE_WINDOW,
            max_age=MT_MAX_AGE
        )

        await ensure_consumer(
            js,
            stream_name=RAW_STREAM,
            durable_name=DURABLE,
            filter_subject=SOURCE_SUBJ,
            deliver_policy=DeliverPolicy.ALL,
            ack_wait_s=ACK_WAIT_S,
            max_deliver=MAX_DELIVER
        )

        info = await js.consumer_info(RAW_STREAM, DURABLE)
        log.info("Consumer state: delivered=%s ack_floor=%s num_pending=%s",
            info.delivered.stream_seq, info.ack_floor.stream_seq, info.num_pending)

        # subscribe to consumer(DURABLE) bound to a stream
        sub = await js.pull_subscribe(
            SOURCE_SUBJ, 
            durable=DURABLE, 
            stream=RAW_STREAM
        )

        log.info(
            "READY server=%s raw_stream=%s source=%s mt_stream=%s dest=%s durable=%s mt_age=%s",
            NATS_SERVER,
            RAW_STREAM,
            SOURCE_SUBJ,
            MT_STREAM,
            DEST_SUBJ,
            DURABLE,
            MT_MAX_AGE,
        )

        while True:
            try:
                # advance the acked sequence, sub object sends the request
                msgs = await sub.fetch(BATCH_SIZE, timeout=FETCH_TIMEOUT_S)
            except NatsTimeoutError:
                await asyncio.sleep(IDLE_SLEEP_S)
                continue
            except Exception:
                log.exception("Fetch failed (connection/server issue?)")
                await asyncio.sleep(1.0)
                continue

            for msg in msgs:
                while True:
                    try:
                        # from msg.data == b'{"verb": "create", "objectRef": {"resource": "pods"}}'
                        # to ev == {"verb": "create", "objectRef": {"resource": "pods"}}
                        ev = json.loads(msg.data.decode("utf-8"))
                    except json.JSONDecodeError:
                        log.warning("Bad JSON, acking to skip: %r", msg.data[:200])
                        await msg.ack()
                        break
                    
                    try:
                        ev_type = classify_event(ev)
                        if ev_type is not None:
                            # create shallow copy so we do not modify actual log
                            out_ev = dict(ev)
                            out_ev["tlaType"] = ev_type

                            permission = classify_permission(out_ev)
                            if permission is not None:
                                out_ev["permission"] = permission

                            audit_id = out_ev.get("auditID")
                            headers = {"Nats-Msg-Id": audit_id} if audit_id else None
                            # filter by tlaType in spec instead of classifying there
                            await js.publish(DEST_SUBJ, encode_compact_json(out_ev), headers=headers)

                        await msg.ack()
                        break

                    except Exception:
                        log.exception("Failed to process message (NAK for retry): %r", msg.data)
                        await asyncio.sleep(0.5)
    # handle shutdown
    except asyncio.CancelledError:
        log.info("Shutdown requested (cancelled).")
        raise
    finally:
        try:
            await nc.drain()
        except Exception:
            await nc.close()
        log.info("NATS connection closed.")

if __name__ == "__main__":
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s %(levelname)s %(name)s %(message)s",
    )

    Path('/tmp/livez').touch()
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        pass
