"""FMU storage: catalog, discovery and parsing of provisioned .fmu files."""

from __future__ import annotations

import logging
from pathlib import Path
from typing import Any

import fmpy

from . import config

logger = logging.getLogger(__name__)


def _resolve_fmu_path(access_key: str) -> Path | None:
    """Return the absolute path to the .fmu file for *access_key*, or None."""
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
