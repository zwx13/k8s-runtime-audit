import logging
import asyncio, json, nats

from stream_functions import ensure_stream

NATS_SERVER   = "nats://localhost:4222"
STREAM        = "AUDIT"
SOURCE_SUBJ   = "audit.full"
DEST_SUBJ     = "audit.node.per.tenant"
DURABLE       = "audit-nodeiso"


logging.basicConfig(level=logging.INFO)

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

async def main():
    # raw nats connection and jetstream connect
    nc = await nats.connect(servers=[NATS_SERVER])
    js = nc.jetstream()

    # durable pull subscription on audit.full so that we resume
    # we get a PullSubscription obj on which we can call fetch()
    sub = await js.pull_subscribe(SOURCE_SUBJ, durable=DURABLE, stream=STREAM)

    try:
        while True:
            # attempt to fetch up to 50 messages,
            # if none available, raise except
            try:
                msgs = await sub.fetch(50, timeout=1.0)
            # if no messages available or error, sleep and try again
            except Exception:
                await asyncio.sleep(0.2)
                continue

            for msg in msgs:
                try:
                    # from msg.data == b'{"verb": "create", "objectRef": {"resource": "pods"}}'
                    # to ev == {"verb": "create", "objectRef": {"resource": "pods"}}
                    # parsing JSON in Python makes it a Python object,a s in dict here
                    ev = json.loads(msg.data.decode("utf-8"))
                    if is_created_pod(ev):
                        # compact json, no extra spaces
                        # prepare to send as bytestring
                        payload = json.dumps(ev, separators=(",", ":")).encode("utf-8")

                        # publish back to the same stream but different subject
                        await js.publish(DEST_SUBJ, payload)
                    # prevent message from staying in stream, tell server it can move forward
                    # serevr replies with PubAck but we do not do anything with it
                    await msg.ack()
                except Exception as e:
                    logging.exception(f"Failed to process message: {msg.data}")
                    # tell js it failed
                    await msg.nak()
    except asyncio.CancelledError:
        # on Ctrl C
        pass
    # always execute after except
    finally:
        # clean exit
        await nc.drain()

if __name__ == "__main__":
    # we are dealing with coroutine objects that end up scheduled in an event loop
    # await is used inside coroutines to pause execution until async operation is done
    # await allows a coroutine to yield control back to the event loop (which is a scheduler for coroutines)
    asyncio.run(main())
