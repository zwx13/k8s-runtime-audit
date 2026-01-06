"""
NATS JetStream forwarder (durable pull consumer)

What this script does
- Connects to NATS and JetStream;
- Pulls messages from SOURCE_SUBJ using a durable consumer (so it resumes from last acked message);
- Parses each message as JSON, filters for events of interest, and republishes them to DEST_SUBJ;
- Acks processed messages; NAKs messages that fail processing.

Asyncio notes
- asyncio.run(main()) creates and runs an event loop and drives the main coroutine until it finishes;
- Inside coroutines, `await` yields control to the event loop while waiting on network IO / timers;
  This keeps the program responsive (including to Ctrl+C).

Shutdown
- On Ctrl+C, the main task is cancelled;
- The `finally` block drains the NATS connection for a clean exit.
"""

import asyncio
import json
import logging

import nats

NATS_SERVER   = "nats://localhost:4222"
STREAM        = "AUDIT"
SOURCE_SUBJ   = "audit.full"
DEST_SUBJ     = "audit.multitenancy"
DURABLE       = "audit-multitenancy-durable"


log = logging.getLogger(__name__)


def classify(ev: dict) -> str | None:
    verb = ev.get("verb")
    obj = ev.get("objectRef") or {}
    resp = ev.get("responseStatus") or {}

    resource = obj.get("resource")
    code = resp.get("code")

    if verb == "create" and resource == "namespaces" and code in {200, 201}:
        return "ns.created"

    if verb == "create" and resource == "roles" and code in {200, 201}:
        return "role.created"

    if verb == "create" and resource == "rolebindings" and code in {200, 201}:
        return "rolebinding.created"
    
    if verb in {"create", "get", "list", "delete"} and resource == "pods":
        imp = ev.get("impersonatedUser") or {}
        user = imp.get("username")
        if isinstance(user, str) and user != "kubernetes-admin":
            return "access.attempt"
    
    return None


# compact json, no extra spaces
# prepare to send as bytestring
def encode_compact_json(obj) -> bytes:
    json.dumps(obj, separators=(",", ":")).encode("utf-8")


async def main() -> None:
    nc = await nats.connect(servers=[NATS_SERVER])
    js = nc.jetstream()

    sub = await js.pull_subscribe(
        SOURCE_SUBJ, 
        durable=DURABLE, 
        stream=STREAM
    )

    # debug durable for audit.full
    info = await js.consumer_info(STREAM, DURABLE)
    log.info("consumer filter_subject=%s", info.config.filter_subject)
    log.info("consumer deliver_policy=%s", info.config.deliver_policy)

    print("READY", flush=True)

    try:
        while True:
            try:
                msgs = await sub.fetch(50, timeout=1.0)
            # treat fetch errors/timeout as "nothing to do" and retry soon
            except Exception:
                await asyncio.sleep(0.2)
                continue

            for msg in msgs:
                try:
                    # from msg.data == b'{"verb": "create", "objectRef": {"resource": "pods"}}'
                    # to ev == {"verb": "create", "objectRef": {"resource": "pods"}}
                    ev = json.loads(msg.data.decode("utf-8"))

                    ev_type = classify(ev)
                    if ev_type is not None:
                        out_ev = dict(ev)
                        out_ev["tlaType"] = ev_type
                        await js.publish(DEST_SUBJ, encode_compact_json(out_ev))

                    await msg.ack()

                except Exception:
                    log.exception("Failed to process message: %r", msg.data)
                    await msg.nak()
    # always execute a clean exit
    finally:
        await nc.drain()

if __name__ == "__main__":
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s %(levelname)s %(name)s %(message)s",
    )
    asyncio.run(main())
