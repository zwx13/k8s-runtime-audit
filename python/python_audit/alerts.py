"""
NATS JetStream Stream: MT_ALERTS

This is where encountered violations by TLC processes get written to.
Then, we can inspect them manually.
"""

import asyncio
import os
from pathlib import Path
import logging
from typing import Final
from datetime import timedelta

import nats

from config_helpers import env_str, env_duration_sec, env_int
from utils import connect_nats
from stream_functions import ensure_stream

log = logging.getLogger(__name__)


# -----------------------------------------------------------------------------
# Configuration
# -----------------------------------------------------------------------------
NATS_SERVER: Final[str] = env_str("NATS_URL", "nats://127.0.0.1:4222")
ALERTS_STREAM: Final[str] = env_str("ALERTS_STREAM", "MT_ALERTS")
ALERTS_SUBJ: Final[str] = env_str("ALERTS_SUBJ", "audit.mt.alerts")
ALERTS_MAX_AGE: Final[timedelta] = env_duration_sec("ALERTS_RETENTION_SECONDS", 30 * 24 * 60 * 60)
ALERTS_DUPLICATE_WINDOW: Final[int] = env_int("ALERTS_DUPLICATE_WINDOW", 180)

# -----------------------------------------------------------------------------
# Stream Verification & Creation if missing
# -----------------------------------------------------------------------------

async def main() -> None:
    nc = await connect_nats()

    js = nc.jetstream()

    try:

        await ensure_stream(
            js,
            stream_name=ALERTS_STREAM,
            subjects=[ALERTS_SUBJ],
            duplicate_window= ALERTS_DUPLICATE_WINDOW,
            max_age=ALERTS_MAX_AGE
        )

        log.info("Ensured alerts stream %s for subjects=%s", ALERTS_STREAM, [ALERTS_SUBJ])

    finally:
        try:
            await nc.drain()
        except Exception:
            log.exception("Drain failed, forcing close.")
            await nc.close()

if __name__ == "__main__":
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s %(levelname)s %(name)s %(message)s",
    )

    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        pass
