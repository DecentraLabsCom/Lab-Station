"""FMU Executor configuration loaded from environment variables."""

from __future__ import annotations

import os
from pathlib import Path


def _env(key: str, default: str | None = None, *, required: bool = False) -> str | None:
    value = os.environ.get(key, default)
    if required and not value:
        raise RuntimeError(f"Required env var {key} is not set")
    return value


# Network
BIND_HOST: str = _env("FMU_EXECUTOR_HOST", "0.0.0.0")
BIND_PORT: int = int(_env("FMU_EXECUTOR_PORT", "8091"))

# FMU storage root – each sub-folder or .fmu file is keyed by accessKey
FMU_ROOT: Path = Path(_env("FMU_ROOT", str(Path(__file__).resolve().parent.parent / "fmu-data")))

# Internal auth token shared with Gateway's fmu-runner
INTERNAL_TOKEN: str | None = _env("FMU_INTERNAL_TOKEN")

# Temp directory for FMU extraction during execution
TEMP_DIR: Path = Path(_env("FMU_EXECUTOR_TEMP", str(FMU_ROOT / ".tmp")))

# Session limits
MAX_CONCURRENT_SESSIONS: int = int(_env("FMU_MAX_SESSIONS", "4"))
SESSION_IDLE_TIMEOUT_S: int = int(_env("FMU_SESSION_IDLE_TIMEOUT", "300"))

# Logging
LOG_LEVEL: str = _env("FMU_LOG_LEVEL", "INFO")
