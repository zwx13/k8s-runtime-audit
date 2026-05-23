import asyncio
from typing import Final
from pathlib import Path

import nats

from config_helpers import env_str

NATS_SERVER: Final[str] = env_str("NATS_URL", "nats://127.0.0.1:4222")

async def keep_alive():
    try:
        while True:
            Path('/tmp/livez').touch()
            # give control back to main loop
            await asyncio.sleep(5)
    except asyncio.CancelledError:
        pass

async def monitor_readiness(nc):
    while True:
        if nc.is_connected:
            Path('/tmp/readyz').touch()
        else:
            if Path('/tmp/readyz').exists():
                Path('/tmp/readyz').unlink()
        await asyncio.sleep(5)


async def connect_nats():
    while True:
        try:
            nc = await nats.connect(
                servers=[NATS_SERVER],
                reconnect_time_wait=2
            )
            print ("!!!!!!!!!!!!!!!!!!!Connected to NATS!!!!!!!!!!!!!!!!!!!")
            return nc
        except Exception as e:
            print (f"Nats NOT ready: {e}")
            await asyncio.sleep(2)