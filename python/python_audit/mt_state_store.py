"""
NATS JetStream kv: MT_STATE_STORE_KV, subject: "audit.mt.state.store"

This is where encountered violations by TLC processes get written
Then, we can inspect them manually.
"""

import asyncio
import os
from pathlib import Path
import logging
from typing import Final
from datetime import timedelta

import nats

from config_helpers import env_str, env_duration_sec
from stream_functions import ensure_kv



log = logging.getLogger(__name__)

# -----------------------------------------------------------------------------
# Configuration
# -----------------------------------------------------------------------------

NATS_SERVER: Final[str] = env_str("NATS_URL","nats://nats:4222")
MT_STATE_STORE_KV: Final[str] = env_str("STATE_KV", "MT_STATE_STORE")
STORE_SUBJ: Final[str] = env_str("STORE_SUBJ", "audit.mt.state.store")
MT_MAX_AGE: Final[timedelta] = env_duration_sec("MT_RETENTION_SECONDS", 30 * 24 * 60 * 60)


# -----------------------------------------------------------------------------
# Logic
# -----------------------------------------------------------------------------

async def main() -> None:
    nc = await nats.connect(servers=[NATS_SERVER])
    js = nc.jetstream()

    try:

        await ensure_kv(
            js,
            bucket_name = MT_STATE_STORE_KV
        )

        print(f"{os.path.basename(__file__)} is READY", flush=True)
        Path('/tmp/readyz').touch()

        # run till cancelled
        await asyncio.Event().wait()

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
