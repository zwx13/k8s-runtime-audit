import os
from datetime import timedelta

# -----------------------------------------------------------------------------
# Config helpers
# -----------------------------------------------------------------------------

def env_str(name: str, default: str) -> str:
    v = os.environ.get(name, default).strip()
    return v

def env_int(name: str, default: int) -> int:
    v = os.environ.get(name)
    if v is None:
        return default
    try:
        return int(v)
    except ValueError as e:
        raise RuntimeError(f"Invalid int for {name}={v!r}") from e
    
def env_float(name: str, default: float) -> float:
    v = os.environ.get(name)
    if v is None:
        return default
    try:
        return float(v)
    except ValueError as e:
        raise RuntimeError(f"Invalid float for {name}={v!r}") from e

def env_duration_sec(name: str, default_seconds: int) -> timedelta:
    """Parse duratiopn from env var as seconds
       Example: RETENTION_SECONDS=86400 (1 day)"""
    seconds = env_int(name, default_seconds)
    if seconds < 0:
        raise RuntimeError(f"{name} must be >= 0")
    return timedelta(seconds=seconds)