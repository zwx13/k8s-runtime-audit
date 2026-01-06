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

import logging
import asyncio, json, nats

NATS_SERVER   = "nats://localhost:4222"
STREAM        = "AUDIT"
SOURCE_SUBJ   = "audit.full"
DEST_SUBJ     = "audit.node.per.tenant"
DURABLE       = "audit-nodeiso-src"


log = logging.getLogger(__name__)


def is_created_pod(ev: dict) -> bool:
    try:
        return (
            ev["objectRef"]["resource"] == "pods" and
            ev["verb"] == "create" and
            ev["responseStatus"]["code"] == 201 and
            ev["requestObject"]["spec"]["nodeSelector"]["kubernetes.io/hostname"] != ""
        )
    except KeyError:
        return False

# compact json, no extra spaces
# prepare to send as bytestring
def encode_compact_json(onj) -> bytes:
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

                    if is_created_pod(ev):
                        await js.publish(DEST_SUBJ, encode_compact_json(ev))


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
