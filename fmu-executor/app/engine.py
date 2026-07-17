"""FMU execution engine – wraps FMPy for Co-Simulation execution."""

from __future__ import annotations

import logging
import shutil
import tempfile
import time as _time
import uuid
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Generator, Optional

from fmpy import extract as fmpy_extract, read_model_description
from fmpy.fmi2 import FMU2Slave

from . import config

logger = logging.getLogger(__name__)


# ── subscription model ───────────────────────────────────────────

@dataclass
class OutputSubscription:
    """Tracks a sim.subscribeOutputs request."""
    variables: Optional[list[str]] = None
    period_ms: int = 100
    max_batch_size: int = 64
    max_hz: Optional[float] = None
    last_emit_monotonic: float = 0.0
    rate_dropped: int = 0

    def min_interval_seconds(self) -> float:
        period_interval = max(1, self.period_ms) / 1000.0
        hz_interval = 0.0
        if self.max_hz is not None and self.max_hz > 0:
            hz_interval = 1.0 / self.max_hz
        return max(period_interval, hz_interval)


class FmuSession:
    """Manages one loaded FMI 2 Co-Simulation session."""

    def __init__(self, session_id: str, fmu_path: Path):
        self.session_id = session_id
        self.fmu_path = fmu_path
        self._extract_dir: Path | None = None
        self._slave: FMU2Slave | None = None
        self._md = None
        self._time: float = 0.0
        self._step_size: float = 0.001
        self._initialised: bool = False
        self._terminated: bool = False
        # Subscription state
        self.subscription: OutputSubscription | None = None
        self.seq: int = 0
        self._pending_samples: list[dict[str, Any]] = []
        self._pending_queue_drops: int = 0

    # ── lifecycle ────────────────────────────────────────────────

    def load(self) -> dict[str, Any]:
        """Extract and read model description. Returns describe dict."""
        self._extract_dir = Path(tempfile.mkdtemp(
            prefix=f"fmu_{self.session_id}_",
            dir=str(config.TEMP_DIR),
        ))
        fmpy_extract(str(self.fmu_path), unzipdir=str(self._extract_dir))
        self._md = read_model_description(str(self.fmu_path))
        return self._describe()

    def initialize(
        self,
        start_time: float = 0.0,
        stop_time: float = 1.0,
        step_size: float | None = None,
        parameters: dict[str, Any] | None = None,
    ) -> dict[str, Any]:
        if self._initialised:
            raise RuntimeError("Session already initialised")
        if self._md is None:
            raise RuntimeError("FMU not loaded – call load() first")
        if self._md.coSimulation is None:
            raise RuntimeError("FMU does not support Co-Simulation")

        self._step_size = step_size or (
            float(self._md.defaultExperiment.stepSize)
            if self._md.defaultExperiment and self._md.defaultExperiment.stepSize
            else 0.001
        )
        self._time = start_time

        model_id = self._md.coSimulation.modelIdentifier
        fmu_path_in_extract = str(self._extract_dir)

        self._slave = FMU2Slave(
            guid=self._md.guid,
            unzipDirectory=fmu_path_in_extract,
            modelIdentifier=model_id,
        )
        self._slave.instantiate()
        self._slave.setupExperiment(startTime=start_time, stopTime=stop_time)

        if parameters:
            self._apply_parameters(parameters)

        self._slave.enterInitializationMode()
        self._slave.exitInitializationMode()
        self._initialised = True

        return {"sessionId": self.session_id, "time": self._time, "state": "initialized"}

    def step(self, step_size: float | None = None) -> dict[str, Any]:
        self._ensure_live()
        h = step_size or self._step_size
        self._slave.doStep(currentCommunicationPoint=self._time, communicationStepSize=h)
        self._time += h
        return {"time": self._time, "state": "running"}

    def run_until(self, target_time: float, step_size: float | None = None) -> dict[str, Any]:
        self._ensure_live()
        h = step_size or self._step_size
        while self._time < target_time - 1e-12:
            remaining = target_time - self._time
            actual_h = min(h, remaining)
            self._slave.doStep(currentCommunicationPoint=self._time, communicationStepSize=actual_h)
            self._time += actual_h
        return {"time": self._time, "state": "running"}

    def run_until_streaming(
        self,
        target_time: float,
        step_size: float | None = None,
        output_refs: list[int] | None = None,
    ) -> Generator[dict[str, Any], None, None]:
        """Step until *target_time*, yielding output snapshots at each step."""
        self._ensure_live()
        h = step_size or self._step_size
        seq = 0
        while self._time < target_time - 1e-12:
            remaining = target_time - self._time
            actual_h = min(h, remaining)
            self._slave.doStep(currentCommunicationPoint=self._time, communicationStepSize=actual_h)
            self._time += actual_h
            outputs = self._read_outputs(output_refs)
            yield {"type": "sim.step", "seq": seq, "time": self._time, "outputs": outputs}
            seq += 1

    def set_inputs(self, values: dict[str, Any]) -> None:
        self._ensure_live()
        self._apply_parameters(values)

    def get_outputs(self, refs: list[int] | None = None) -> dict[str, Any]:
        self._ensure_live()
        return {"time": self._time, "outputs": self._read_outputs(refs)}

    def sample_subscription(self) -> dict[str, Any] | None:
        """Collect a subscription sample.  Returns an output-event dict ready
        to send, or ``None`` if the subscription rate-limit has not elapsed."""
        if not self.subscription:
            return None

        # Resolve variable name filter → valueReference filter
        var_refs: list[int] | None = None
        if self.subscription.variables is not None and self._md:
            name_set = set(self.subscription.variables)
            var_refs = [
                v.valueReference
                for v in self._md.modelVariables
                if v.name in name_set and v.causality == "output"
            ]

        sample = self._read_outputs(var_refs)
        self._pending_samples.append(sample)

        # Enforce max batch size
        if len(self._pending_samples) > self.subscription.max_batch_size:
            excess = len(self._pending_samples) - self.subscription.max_batch_size
            self._pending_samples = self._pending_samples[excess:]
            self.subscription.rate_dropped += excess

        now = _time.monotonic()
        min_interval = self.subscription.min_interval_seconds()
        if (now - self.subscription.last_emit_monotonic) < min_interval:
            self.subscription.rate_dropped += 1
            return None

        self.subscription.last_emit_monotonic = now
        values = self._pending_samples[-1]
        batch_size = len(self._pending_samples)
        self._pending_samples.clear()
        dropped = self.subscription.rate_dropped + self._pending_queue_drops
        self.subscription.rate_dropped = 0
        self._pending_queue_drops = 0

        payload = {
            "type": "sim.outputs",
            "sessionId": self.session_id,
            "seq": self.seq,
            "dropped": dropped,
            "batchSize": batch_size,
            "simTime": self._time,
            "values": values,
        }
        self.seq += 1
        return payload

    def terminate(self) -> None:
        if self._terminated:
            return
        self._terminated = True
        if self._slave and self._initialised:
            try:
                self._slave.terminate()
                self._slave.freeInstance()
            except Exception:
                logger.warning("Error terminating FMU slave for session %s", self.session_id, exc_info=True)
        self._cleanup_temp()

    # ── private ──────────────────────────────────────────────────

    def _ensure_live(self) -> None:
        if self._terminated:
            raise RuntimeError("Session already terminated")
        if not self._initialised:
            raise RuntimeError("Session not initialised")

    def _describe(self) -> dict[str, Any]:
        from . import fmu_storage
        # Re-use the same normalised describe logic
        return fmu_storage.describe(self.fmu_path.name)

    def _apply_parameters(self, params: dict[str, Any]) -> None:
        """Set variable values by name."""
        if not self._md or not self._slave:
            return
        var_map = {v.name: v for v in self._md.modelVariables}
        for name, value in params.items():
            var = var_map.get(name)
            if var is None:
                logger.warning("Unknown variable %r – skipped", name)
                continue
            vr = [var.valueReference]
            vtype = (var.type or "").lower()
            if vtype == "real":
                self._slave.setReal(vr, [float(value)])
            elif vtype == "integer":
                self._slave.setInteger(vr, [int(value)])
            elif vtype == "boolean":
                self._slave.setBoolean(vr, [bool(value)])
            elif vtype == "string":
                self._slave.setString(vr, [str(value)])

    def _read_outputs(self, refs: list[int] | None = None) -> dict[str, Any]:
        """Read output variables. If *refs* is None, read all outputs."""
        if not self._md or not self._slave:
            return {}
        outputs: dict[str, Any] = {}
        for var in self._md.modelVariables:
            if var.causality != "output":
                continue
            if refs is not None and var.valueReference not in refs:
                continue
            vr = [var.valueReference]
            vtype = (var.type or "").lower()
            try:
                if vtype == "real":
                    outputs[var.name] = self._slave.getReal(vr)[0]
                elif vtype == "integer":
                    outputs[var.name] = self._slave.getInteger(vr)[0]
                elif vtype == "boolean":
                    outputs[var.name] = self._slave.getBoolean(vr)[0]
                elif vtype == "string":
                    outputs[var.name] = self._slave.getString(vr)[0]
            except Exception:
                logger.debug("Could not read %s (vr=%d)", var.name, var.valueReference)
        return outputs

    def _cleanup_temp(self) -> None:
        extract_dir = getattr(self, "_extract_dir", None)
        if extract_dir and extract_dir.exists():
            try:
                shutil.rmtree(extract_dir, ignore_errors=True)
            except Exception:
                logger.debug(
                    "Could not remove FMU temporary directory %s",
                    extract_dir,
                    exc_info=True,
                )

    def __del__(self) -> None:
        self.terminate()


# ── session registry ─────────────────────────────────────────────

_sessions: dict[str, FmuSession] = {}


def create_session(fmu_path: Path) -> FmuSession:
    if len(_sessions) >= config.MAX_CONCURRENT_SESSIONS:
        raise RuntimeError(
            f"Max concurrent sessions ({config.MAX_CONCURRENT_SESSIONS}) reached"
        )
    session_id = f"sess_{uuid.uuid4().hex[:12]}"
    session = FmuSession(session_id, fmu_path)
    _sessions[session_id] = session
    return session


def get_session(session_id: str) -> FmuSession | None:
    return _sessions.get(session_id)


def remove_session(session_id: str) -> None:
    session = _sessions.pop(session_id, None)
    if session:
        session.terminate()


def active_session_count() -> int:
    return len(_sessions)


def terminate_all() -> None:
    for sid in list(_sessions):
        remove_session(sid)
