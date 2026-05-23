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
from utils import connect_nats
from stream_functions import ensure_kv



log = logging.getLogger(__name__)

# -----------------------------------------------------------------------------
# Configuration
# -----------------------------------------------------------------------------

NATS_SERVER: Final[str] = env_str("NATS_URL", "nats://127.0.0.1:4222")
MT_STATE_STORE_KV: Final[str] = env_str("STATE_KV", "MT_STATE_STORE")
STORE_SUBJ: Final[str] = env_str("STORE_SUBJ", "audit.mt.state.store")
MT_MAX_AGE: Final[timedelta] = env_duration_sec("MT_RETENTION_SECONDS", 30 * 24 * 60 * 60)


# -----------------------------------------------------------------------------
# Logic
# -----------------------------------------------------------------------------

async def main() -> None:
    nc = await connect_nats()

    js = nc.jetstream()

    try:
        await ensure_kv(
            js,
            bucket_name = MT_STATE_STORE_KV
        )
        log.info("Ensured kv for storing state %s, for subject %s", MT_STATE_STORE_KV, [STORE_SUBJ])


    finally:
        try:
            await nc.drain()
        except Exception:
            log.error("Drain failed, forcing close.")
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
