"""FMU Executor – FastAPI application.

Internal-only service that runs on Lab Station, providing the FMU execution plane
consumed by Lab Gateway's fmu-runner in ``station`` backend mode.
"""

from __future__ import annotations

import asyncio
import json
import logging
import time
from typing import Any

from fastapi import (
    Depends,
    FastAPI,
    HTTPException,
    Query,
    Request,
    WebSocket,
    WebSocketDisconnect,
)
from fastapi.responses import JSONResponse, StreamingResponse
from pydantic import BaseModel, Field

from . import config, fmu_storage, engine, auth

logger = logging.getLogger(__name__)

app = FastAPI(title="FMU Executor", version="0.1.0", docs_url=None, redoc_url=None)


# ── Startup / shutdown ───────────────────────────────────────────

@app.on_event("startup")
async def _startup() -> None:
    logging.basicConfig(level=getattr(logging, config.LOG_LEVEL, logging.INFO))
    config.FMU_ROOT.mkdir(parents=True, exist_ok=True)
    config.TEMP_DIR.mkdir(parents=True, exist_ok=True)
    logger.info(
        "FMU Executor starting – root=%s, port=%s, max_sessions=%s",
        config.FMU_ROOT, config.BIND_PORT, config.MAX_CONCURRENT_SESSIONS,
    )


@app.on_event("shutdown")
async def _shutdown() -> None:
    logger.info("Shutting down – terminating all sessions")
    engine.terminate_all()


# ── Dependency ───────────────────────────────────────────────────

async def _check_token(request: Request) -> None:
    auth.validate_internal_token(request)


# ── Health ───────────────────────────────────────────────────────

@app.get("/internal/health")
async def health():
    fmu_count = len(fmu_storage.list_fmus())
    return {
        "status": "ok",
        "fmuCount": fmu_count,
        "activeSessions": engine.active_session_count(),
        "maxSessions": config.MAX_CONCURRENT_SESSIONS,
        "timestamp": time.time(),
    }


# ── Catalog ──────────────────────────────────────────────────────

@app.get("/internal/fmu/catalog/{access_key:path}", dependencies=[Depends(_check_token)])
async def catalog(access_key: str):
    if not fmu_storage.fmu_exists(access_key):
        raise HTTPException(404, "FMU_NOT_FOUND")
    desc = fmu_storage.describe(access_key)
    return {
        "accessKey": access_key,
        "files": [access_key],
        "describe": desc,
    }


# ── Describe ─────────────────────────────────────────────────────

@app.get("/internal/fmu/describe/{access_key:path}", dependencies=[Depends(_check_token)])
async def describe(access_key: str):
    if not fmu_storage.fmu_exists(access_key):
        raise HTTPException(404, "FMU_NOT_FOUND")
    return fmu_storage.describe(access_key)


# ── Simulation run ───────────────────────────────────────────────

class SimulationBody(BaseModel):
    accessKey: str | None = None
    claims: dict = Field(default_factory=dict)
    labId: str | None = None
    reservationKey: str | None = None
    parameters: dict = Field(default_factory=dict)
    options: dict = Field(default_factory=dict)


@app.post("/internal/fmu/simulations/run/{access_key:path}", dependencies=[Depends(_check_token)])
async def run_simulation(access_key: str, body: SimulationBody):
    if not fmu_storage.fmu_exists(access_key):
        raise HTTPException(404, "FMU_NOT_FOUND")

    fmu_path = fmu_storage.get_fmu_path(access_key)
    session = engine.create_session(fmu_path)
    try:
        session.load()
        start = body.options.get("startTime", 0.0)
        stop = body.options.get("stopTime", 1.0)
        step = body.options.get("stepSize")
        session.initialize(
            start_time=float(start),
            stop_time=float(stop),
            step_size=float(step) if step else None,
            parameters=body.parameters or None,
        )
        result = session.run_until(float(stop), step_size=float(step) if step else None)
        outputs = session.get_outputs()
        return {
            "type": "sim.result",
            "time": result["time"],
            "state": "terminated",
            "outputs": outputs.get("outputs", {}),
        }
    finally:
        engine.remove_session(session.session_id)


# ── Simulation stream (NDJSON) ───────────────────────────────────

@app.post("/internal/fmu/simulations/stream/{access_key:path}", dependencies=[Depends(_check_token)])
async def stream_simulation(access_key: str, body: SimulationBody):
    if not fmu_storage.fmu_exists(access_key):
        raise HTTPException(404, "FMU_NOT_FOUND")

    fmu_path = fmu_storage.get_fmu_path(access_key)

    def _generate():
        session = engine.create_session(fmu_path)
        try:
            session.load()
            start = body.options.get("startTime", 0.0)
            stop = body.options.get("stopTime", 1.0)
            step = body.options.get("stepSize")
            session.initialize(
                start_time=float(start),
                stop_time=float(stop),
                step_size=float(step) if step else None,
                parameters=body.parameters or None,
            )
            for snapshot in session.run_until_streaming(
                float(stop),
                step_size=float(step) if step else None,
            ):
                yield json.dumps(snapshot, default=str) + "\n"
            yield json.dumps({"type": "sim.done", "time": float(stop)}) + "\n"
        except Exception as exc:
            yield json.dumps({"type": "error", "message": str(exc)}) + "\n"
        finally:
            engine.remove_session(session.session_id)

    return StreamingResponse(_generate(), media_type="application/x-ndjson")


# ── Realtime WebSocket sessions ──────────────────────────────────

@app.websocket("/internal/fmu/sessions")
async def ws_sessions(ws: WebSocket):
    # Validate internal token from headers
    token = ws.headers.get("x-internal-session-token")
    if config.INTERNAL_TOKEN and token != config.INTERNAL_TOKEN:
        await ws.close(code=4001, reason="UNAUTHORIZED")
        return

    await ws.accept()
    session: engine.FmuSession | None = None
    _emitter_task: asyncio.Task | None = None

    async def _output_emitter():
        """Background task that streams subscribed outputs to the WS client."""
        try:
            while True:
                if session and session.subscription and session._initialised and not session._terminated:
                    payload = session.sample_subscription()
                    if payload:
                        await ws.send_text(json.dumps(payload, default=str))
                await asyncio.sleep(0.01)  # 10 ms polling resolution
        except (WebSocketDisconnect, asyncio.CancelledError):
            pass
        except Exception:
            logger.debug("Output emitter stopped", exc_info=True)

    try:
        while True:
            raw = await ws.receive_text()
            msg = json.loads(raw)
            msg_type = msg.get("type", "")
            request_id = msg.get("requestId")
            gateway_ctx = msg.get("gatewayContext")

            try:
                response = _handle_ws_message(msg_type, msg, gateway_ctx, session)
                if msg_type == "session.create":
                    session = response.pop("_session", None)
                    # Start emitter task on session creation
                    if _emitter_task is None:
                        _emitter_task = asyncio.create_task(_output_emitter())
                elif msg_type == "session.terminate":
                    if session:
                        engine.remove_session(session.session_id)
                    session = None

                if request_id:
                    response["requestId"] = request_id
                await ws.send_text(json.dumps(response, default=str))

            except HTTPException as exc:
                err = {"type": "error", "code": exc.detail}
                if request_id:
                    err["requestId"] = request_id
                await ws.send_text(json.dumps(err))
            except Exception as exc:
                err = {"type": "error", "code": "INTERNAL_ERROR", "message": str(exc)}
                if request_id:
                    err["requestId"] = request_id
                await ws.send_text(json.dumps(err))

    except WebSocketDisconnect:
        pass
    finally:
        if _emitter_task:
            _emitter_task.cancel()
            try:
                await _emitter_task
            except asyncio.CancelledError:
                pass
        if session:
            engine.remove_session(session.session_id)


def _handle_ws_message(
    msg_type: str,
    msg: dict,
    gateway_ctx: dict | None,
    session: engine.FmuSession | None,
) -> dict[str, Any]:
    """Dispatch a single WS message and return a response dict."""

    if msg_type == "session.create":
        if session is not None:
            raise HTTPException(400, "INVALID_COMMAND – session already created")
        if gateway_ctx is None:
            raise HTTPException(400, "Missing gatewayContext")

        access_key = auth.extract_access_key_from_context(gateway_ctx)
        if not access_key:
            raise HTTPException(400, "Missing accessKey in gatewayContext")
        auth.validate_gateway_context(gateway_ctx, access_key)

        if not fmu_storage.fmu_exists(access_key):
            raise HTTPException(404, "FMU_NOT_FOUND")

        fmu_path = fmu_storage.get_fmu_path(access_key)
        new_session = engine.create_session(fmu_path)
        new_session.load()

        claims = (gateway_ctx.get("claims") or {})
        exp = claims.get("exp")

        return {
            "type": "session.created",
            "sessionId": new_session.session_id,
            "serverTime": time.time(),
            "expiresAt": exp,
            "capabilities": {
                "modelDescribe": True,
                "getState": True,
                "pause": False,
                "reset": False,
                "step": True,
                "setInputs": True,
                "streamOutputs": True,
                "timeMode": ["simtime"],
            },
            "_session": new_session,
        }

    # All remaining commands require a live session
    if session is None:
        raise HTTPException(400, "INVALID_COMMAND – no active session")

    if msg_type == "session.attach":
        return {
            "type": "session.attached",
            "sessionId": session.session_id,
            "serverTime": time.time(),
        }

    if msg_type == "model.describe":
        desc = fmu_storage.describe(session.fmu_path.name)
        return {"type": "model.description", **desc}

    if msg_type == "sim.initialize":
        options = msg.get("options", {})
        params = msg.get("parameters", {})
        result = session.initialize(
            start_time=float(options.get("startTime", 0.0)),
            stop_time=float(options.get("stopTime", 1.0)),
            step_size=float(options.get("stepSize")) if options.get("stepSize") else None,
            parameters=params or None,
        )
        return {"type": "sim.initialized", **result}

    if msg_type == "sim.step":
        step_size = msg.get("stepSize")
        result = session.step(float(step_size) if step_size else None)
        return {"type": "sim.stepped", **result}

    if msg_type == "sim.runUntil":
        target = msg.get("targetTime")
        if target is None:
            raise HTTPException(400, "INVALID_COMMAND – missing targetTime")
        step_size = msg.get("stepSize")
        result = session.run_until(
            float(target),
            step_size=float(step_size) if step_size else None,
        )
        return {"type": "sim.stepped", **result}

    if msg_type == "sim.setInputs":
        values = msg.get("values", {})
        session.set_inputs(values)
        return {"type": "sim.inputsSet", "time": session._time}

    if msg_type == "sim.getOutputs":
        refs = msg.get("valueReferences")
        result = session.get_outputs(refs)
        return {"type": "sim.outputs", **result}

    if msg_type == "sim.subscribeOutputs":
        variables = msg.get("variables")
        if variables is not None and not isinstance(variables, list):
            raise HTTPException(400, "sim.subscribeOutputs requires 'variables' as array")
        subscription = engine.OutputSubscription(
            variables=variables,
            period_ms=max(1, int(msg.get("periodMs", 100))),
            max_batch_size=max(1, int(msg.get("maxBatchSize", 64))),
            max_hz=float(msg["maxHz"]) if msg.get("maxHz") is not None else None,
        )
        session.subscription = subscription
        return {
            "type": "sim.subscribed",
            "sessionId": session.session_id,
            "periodMs": subscription.period_ms,
            "maxBatchSize": subscription.max_batch_size,
            "maxHz": subscription.max_hz,
        }

    if msg_type == "sim.unsubscribeOutputs":
        session.subscription = None
        session._pending_samples.clear()
        return {
            "type": "sim.unsubscribed",
            "sessionId": session.session_id,
        }

    if msg_type == "sim.getState":
        return {
            "type": "sim.state",
            "time": session._time,
            "state": "terminated" if session._terminated else (
                "initialized" if session._initialised else "loaded"
            ),
        }

    if msg_type in ("session.ping", "ping"):
        return {"type": "session.pong", "serverTime": time.time()}

    if msg_type == "session.terminate":
        session.terminate()
        return {"type": "session.terminated", "sessionId": session.session_id}

    raise HTTPException(400, f"INVALID_COMMAND – unknown type {msg_type!r}")
