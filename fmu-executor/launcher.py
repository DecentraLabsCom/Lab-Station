"""Frozen Windows entry point for the FMU Executor sidecar."""

from __future__ import annotations

import multiprocessing


if __name__ == "__main__":
    # PyInstaller reuses this executable for spawned worker processes.
    multiprocessing.freeze_support()

import os
import sys
from pathlib import Path


if getattr(sys, "frozen", False):
    # The executable is in fmu-executor/runtime; keep mutable FMU files beside
    # that runtime, outside PyInstaller's _internal directory.
    runtime_directory = Path(sys.executable).resolve().parent
    executor_root = Path(sys.executable).resolve().parent.parent
else:
    runtime_directory = Path(__file__).resolve().parent
    executor_root = Path(__file__).resolve().parent

# Multiprocessing workers inherit this directory in their spawn preparation
# data. The isolated worker can read the runtime directory, but not an
# arbitrary caller directory such as the service account's TEMP folder.
os.chdir(runtime_directory)

os.environ.setdefault("FMU_ROOT", str(executor_root / "fmu-data"))
os.environ.setdefault("FMU_EXECUTOR_TEMP", str(executor_root / "fmu-data" / ".tmp"))

from app import config  # noqa: E402
import uvicorn  # noqa: E402


def main() -> None:
    uvicorn.run(
        "app.main:app",
        host=config.bind_host(),
        port=config.bind_port(),
        log_level=config.log_level().lower(),
    )


if __name__ == "__main__":
    main()
