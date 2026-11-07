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


def _register_appcontainer_pipe_reducer() -> None:
    """Duplicate multiprocessing pipes into workers before AppContainer launch."""
    if os.name != "nt":
        return

    from multiprocessing import connection as mp_connection
    from multiprocessing.context import get_spawning_popen

    original_reducer = mp_connection.reduce_pipe_connection
    reduction = mp_connection.reduction

    def reduce_pipe_connection_for_worker(pipe):
        popen = get_spawning_popen()
        if popen is None or popen.pid is None:
            return original_reducer(pipe)

        access = (
            (mp_connection._winapi.FILE_GENERIC_READ if pipe.readable else 0)
            | (mp_connection._winapi.FILE_GENERIC_WRITE if pipe.writable else 0)
        )
        duplicated_handle = reduction.DupHandle(pipe.fileno(), access, pid=popen.pid)
        return mp_connection.rebuild_pipe_connection, (
            duplicated_handle,
            pipe.readable,
            pipe.writable,
        )

    reduction.register(mp_connection.PipeConnection, reduce_pipe_connection_for_worker)


_register_appcontainer_pipe_reducer()

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
