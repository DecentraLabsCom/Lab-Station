"""FMU storage: catalog, discovery, validation and quarantine of provisioned .fmu files."""

from __future__ import annotations

import logging
import shutil
import time as _time
from pathlib import Path
from typing import Any

import fmpy

from . import config

logger = logging.getLogger(__name__)

# ── quarantine state ─────────────────────────────────────────────

# In-memory quarantine index: accessKey → {reason, timestamp}.
# Written to disk as `<FMU_ROOT>/.quarantine/<accessKey>.reason`.
_quarantine_cache: dict[str, dict[str, Any]] = {}


def _quarantine_dir() -> Path:
    return config.FMU_ROOT / ".quarantine"


def _load_quarantine_cache() -> None:
    """Load quarantine entries from disk into memory (idempotent)."""
    q = _quarantine_dir()
    if not q.is_dir():
        return
    for entry in q.iterdir():
        key = entry.stem  # e.g. "Model.fmu" from "Model.fmu.reason"
        if entry.suffix == ".reason" and key not in _quarantine_cache:
            try:
                reason = entry.read_text(encoding="utf-8").strip()
            except OSError:
                reason = "unknown"
            _quarantine_cache[key] = {
                "reason": reason,
                "timestamp": entry.stat().st_mtime,
            }


def quarantine(access_key: str, reason: str) -> None:
    """Move an FMU to quarantine so it is excluded from the active catalog."""
    q = _quarantine_dir()
    q.mkdir(parents=True, exist_ok=True)

    # Persist reason to disk
    reason_file = q / f"{access_key}.reason"
    reason_file.write_text(reason, encoding="utf-8")

    # Move the actual FMU aside if it exists
    root = config.FMU_ROOT
    candidate = root / access_key
    quarantined_target = q / access_key
    if candidate.exists() and not quarantined_target.exists():
        shutil.move(str(candidate), str(quarantined_target))

    _quarantine_cache[access_key] = {
        "reason": reason,
        "timestamp": _time.time(),
    }
    logger.warning("Quarantined FMU %s: %s", access_key, reason)


def unquarantine(access_key: str) -> bool:
    """Restore a quarantined FMU back to the active catalog.  Returns True on success."""
    q = _quarantine_dir()
    quarantined = q / access_key
    reason_file = q / f"{access_key}.reason"
    target = config.FMU_ROOT / access_key

    restored = False
    if quarantined.exists() and not target.exists():
        shutil.move(str(quarantined), str(target))
        restored = True
    if reason_file.exists():
        reason_file.unlink()
    _quarantine_cache.pop(access_key, None)
    if restored:
        logger.info("Restored FMU %s from quarantine", access_key)
    return restored


def is_quarantined(access_key: str) -> bool:
    _load_quarantine_cache()
    return access_key in _quarantine_cache


def quarantine_info(access_key: str) -> dict[str, Any] | None:
    _load_quarantine_cache()
    return _quarantine_cache.get(access_key)


def list_quarantined() -> list[dict[str, Any]]:
    _load_quarantine_cache()
    return [
        {"accessKey": k, **v}
        for k, v in sorted(_quarantine_cache.items())
    ]


# ── validation ───────────────────────────────────────────────────

def validate_fmu(access_key: str) -> tuple[bool, str]:
    """Validate an FMU is a parseable Co-Simulation archive.

    Returns ``(True, "")`` on success or ``(False, reason)`` on failure.
    Does NOT auto-quarantine — the caller decides.
    """
    path = _resolve_fmu_path(access_key)
    if path is None:
        return False, "FMU file not found"
    try:
        md = fmpy.read_model_description(str(path))
    except Exception as exc:
        return False, f"Cannot parse model description: {exc}"
    if md.coSimulation is None:
        return False, "FMU does not support Co-Simulation"
    if not md.guid:
        return False, "FMU has no GUID"
    return True, ""


def _resolve_fmu_path(access_key: str) -> Path | None:
    """Return the absolute path to the .fmu file for *access_key*, or None.

    Quarantined FMUs are excluded.
    """
    if is_quarantined(access_key):
        return None
    root = config.FMU_ROOT
    # Direct file: <root>/<accessKey>  (already ends with .fmu)
    candidate = root / access_key
    if candidate.is_file() and candidate.suffix == ".fmu":
        # Ensure the resolved path stays inside root to prevent path traversal.
        try:
            candidate.resolve().relative_to(root.resolve())
        except ValueError:
            logger.warning("Path traversal attempt blocked: %s", access_key)
            return None
        return candidate
    # Sub-folder containing a single .fmu
    if candidate.is_dir():
        fmus = list(candidate.glob("*.fmu"))
        if len(fmus) == 1:
            return fmus[0]
    return None


def list_fmus() -> list[str]:
    """Return all available access keys."""
    root = config.FMU_ROOT
    if not root.is_dir():
        return []
    keys: list[str] = []
    for child in sorted(root.iterdir()):
        if child.name.startswith("."):
            continue
        if child.is_file() and child.suffix == ".fmu":
            keys.append(child.name)
        elif child.is_dir():
            if any(child.glob("*.fmu")):
                keys.append(child.name)
    return keys


def fmu_exists(access_key: str) -> bool:
    return _resolve_fmu_path(access_key) is not None


def get_fmu_path(access_key: str) -> Path:
    """Return the path or raise FileNotFoundError."""
    path = _resolve_fmu_path(access_key)
    if path is None:
        raise FileNotFoundError(f"FMU not found for accessKey={access_key!r}")
    return path


def describe(access_key: str) -> dict[str, Any]:
    """Parse the model description and return a normalised dict compatible with the Gateway contract."""
    fmu_path = str(get_fmu_path(access_key))
    md = fmpy.read_model_description(fmu_path)

    variables: list[dict[str, Any]] = []
    for var in md.modelVariables:
        entry: dict[str, Any] = {
            "name": var.name,
            "valueReference": var.valueReference,
            "causality": var.causality,
            "variability": var.variability,
        }
        if var.type:
            entry["type"] = var.type
        if var.start is not None:
            entry["start"] = var.start
        if var.unit:
            entry["unit"] = var.unit
        if var.min is not None:
            entry["min"] = var.min
        if var.max is not None:
            entry["max"] = var.max
        variables.append(entry)

    cs = md.coSimulation
    me = md.modelExchange

    result: dict[str, Any] = {
        "modelName": md.modelName,
        "guid": md.guid,
        "fmiVersion": md.fmiVersion,
        "supportsCoSimulation": cs is not None,
        "supportsModelExchange": me is not None,
        "modelVariables": variables,
    }

    if cs is not None:
        result["fmiType"] = "CoSimulation"
        result["simulationKind"] = "coSimulation"
        result["simulationType"] = "CoSimulation"
    elif me is not None:
        result["fmiType"] = "ModelExchange"
        result["simulationKind"] = "modelExchange"
        result["simulationType"] = "ModelExchange"

    exp = md.defaultExperiment
    if exp:
        if exp.startTime is not None:
            result["defaultStartTime"] = float(exp.startTime)
        if exp.stopTime is not None:
            result["defaultStopTime"] = float(exp.stopTime)
        if exp.stepSize is not None:
            result["defaultStepSize"] = float(exp.stepSize)

    return result
