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
    executor_root = Path(sys.executable).resolve().parent.parent
else:
    executor_root = Path(__file__).resolve().parent

os.environ.setdefault("FMU_ROOT", str(executor_root / "fmu-data"))
os.environ.setdefault("FMU_EXECUTOR_TEMP", str(executor_root / "fmu-data" / ".tmp"))

from app import config  # noqa: E402
from app import fmu_storage  # noqa: E402
from app import main as executor_main  # noqa: E402
from fastapi import Depends, Header, HTTPException  # noqa: E402
from fastapi.responses import FileResponse  # noqa: E402
import uvicorn  # noqa: E402


# This Station-owned endpoint exposes only the same-stem GLB companion of an
# FMU to the authenticated provider Gateway. Keep it in this wrapper so the
# pinned, shared FMU Executor source remains unchanged.
@executor_main.app.get(
    "/internal/fmu/companion-scene",
    dependencies=[Depends(executor_main._check_token)],
)
async def companion_scene(access_key: str = Header(..., alias="X-FMU-Access-Key")):
    access_key = executor_main._validated_access_key(access_key)
    try:
        fmu_path = fmu_storage.get_fmu_path(access_key).resolve(strict=True)
    except FileNotFoundError as exc:
        raise HTTPException(status_code=404, detail="FMU_NOT_FOUND") from exc

    root = config.FMU_ROOT.resolve()
    scene_path = fmu_path.with_suffix(".glb")
    try:
        scene_path = scene_path.resolve(strict=True)
        fmu_path.relative_to(root)
        scene_path.relative_to(root)
    except (FileNotFoundError, ValueError) as exc:
        raise HTTPException(status_code=404, detail="COMPANION_GLB_NOT_FOUND") from exc

    if not scene_path.is_file():
        raise HTTPException(status_code=404, detail="COMPANION_GLB_NOT_FOUND")
    try:
        if scene_path.stat().st_size > 50 * 1024 * 1024:
            raise HTTPException(status_code=413, detail="GLB exceeds the 50 MiB limit")
    except OSError as exc:
        raise HTTPException(status_code=404, detail="COMPANION_GLB_NOT_FOUND") from exc

    return FileResponse(scene_path, media_type="model/gltf-binary", filename=scene_path.name)


def main() -> None:
    uvicorn.run(
        "app.main:app",
        host=config.bind_host(),
        port=config.bind_port(),
        log_level=config.log_level().lower(),
    )


if __name__ == "__main__":
    main()
