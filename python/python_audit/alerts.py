"""
NATS JetStream kv: MT_ALERTS, subject: "audit.mt.alerts"

This is where encountered violations by TLC processes get written
Then, we can inspect them manually.
"""

import asyncio
import logging
from typing import Final
from datetime import timedelta

import nats

from config_helpers import env_str, env_duration_sec, env_int
from stream_functions import ensure_stream



log = logging.getLogger(__name__)

# -----------------------------------------------------------------------------
# Configuration
# -----------------------------------------------------------------------------

NATS_SERVER: Final[str] = env_str("NATS_URL","nats://localhost:4222")
ALERTS_STREAM: Final[str] = env_str("ALERTS_STREAM", "MT_ALERTS")
ALERTS_SUBJ: Final[str] = env_str("ALERTS_SUBJ", "audit.mt.alerts")
ALERTS_MAX_AGE: Final[timedelta] = env_duration_sec("ALERTS_RETENTION_SECONDS", 30 * 24 * 60 * 60)
# have to consider how we avoid dupes
ALERTS_DUPLICATE_WINDOW: Final[int] = env_int("ALERTS_DUPLICATE_WINDOW", 180)


# -----------------------------------------------------------------------------
# Logic
# -----------------------------------------------------------------------------

async def main() -> None:
    nc = await nats.connect(servers=[NATS_SERVER])
    js = nc.jetstream()

    try:

        await ensure_stream(
            js,
            stream_name=ALERTS_STREAM,
            subjects=[ALERTS_SUBJ],
            duplicate_window= ALERTS_DUPLICATE_WINDOW,
            max_age=ALERTS_MAX_AGE
        )

        print("READY", flush=True)

        # run till cancelled
        await asyncio.Future()

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
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        pass
