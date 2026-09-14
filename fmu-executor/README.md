# FMU Executor

Python/FastAPI sidecar that provides the FMU execution plane on Lab Station.  
Consumed by Lab Gateway's `fmu-runner` in `station` backend mode.

## Quick start

```bash
cd fmu-executor
pip install -r requirements.txt
python -m app
```

The service listens on `http://0.0.0.0:8091` by default. It is an internal
station service; expose the configured port only to the Lab Gateway network and
configure the same non-empty `FMU_INTERNAL_TOKEN` in the Station process
environment and Gateway's `FMU_STATION_INTERNAL_TOKEN`.

The same integration is visible from the Lab Station **Connectors** panel,
which reports the FMU endpoint, local model directory, port, token status, and
the Gateway environment expected for station mode:

![Lab Station FMI/FMU connector](../docs/images/labstation-connectors-fmi.png)

*FMI/FMU connector view from the Lab Station desktop UI.*

## Configuration (env vars)

| Variable | Default | Description |
|---|---|---|
| `FMU_EXECUTOR_HOST` | `0.0.0.0` | Bind address |
| `FMU_EXECUTOR_PORT` | `8091` | Bind port |
| `FMU_ROOT` | `./fmu-data` | Directory with provisioned `.fmu` files |
| `FMU_INTERNAL_TOKEN` | *(required)* | Shared secret for `X-Internal-Session-Token`; requests fail closed when it is absent |
| `FMU_MAX_SESSIONS` | `4` | Effective max concurrent FMU executions (one-shot, stream and realtime) |
| `FMU_ATTACH_GRACE_SECONDS` | `120` | How long a disconnected realtime session remains attachable before its FMU state is terminated |
| `FMU_EXECUTOR_TEMP` | `<FMU_ROOT>/.tmp` | Temp dir for FMU extraction |
| `FMU_LOG_LEVEL` | `INFO` | Log level |

For the Windows scheduled task, set the token as a machine-level environment
variable before starting the Station service:

```powershell
[Environment]::SetEnvironmentVariable('FMU_INTERNAL_TOKEN', '<random-shared-secret>', 'Machine')
```

Restart the `LabStation\BackgroundService` task after changing the
variable. The token value must be copied to Lab Gateway's
`FMU_STATION_INTERNAL_TOKEN`; do not put it in source control or in a
public connector URL. `FMU_EXECUTOR_PORT` must be a numeric TCP port from 1 to
65535. The Lab Station supervisor reads the same variable for its health checks
and creates the `LabStation-FMU-Executor` inbound rule for that port on Domain
and Private profiles. A manual `python -m app` launch does not create the
firewall rule.

## Internal API

All endpoints require `X-Internal-Session-Token` header (except `/internal/health`).

| Method | Path | Description |
|---|---|---|
| GET | `/internal/health` | Health & diagnostics |
| GET | `/internal/fmu/catalog` | FMU inventory; `X-FMU-Access-Key` header |
| GET | `/internal/fmu/describe` | Model description; `X-FMU-Access-Key` header |
| GET | `/internal/fmu/capacity` | Effective execution capacity; internal token required |
| POST | `/internal/fmu/validate/{access_key}?auto_quarantine=false` | Validates an FMU and optionally quarantines it when invalid |
| POST | `/internal/fmu/quarantine/{access_key}?reason=manual` | Explicitly quarantines an FMU |
| DELETE | `/internal/fmu/quarantine/{access_key}` | Removes an FMU from quarantine |
| GET | `/internal/fmu/quarantine` | Lists quarantined FMUs |
| POST | `/internal/fmu/simulations/run` | One-shot simulation run; JSON body contains `accessKey` |
| POST | `/internal/fmu/simulations/stream` | Streaming NDJSON simulation; JSON body contains `accessKey` |
| WS | `/internal/fmu/sessions` | Realtime session (step, setInputs, getOutputs, authenticated reconnect) |

`catalog` and `describe` also require the `X-FMU-Access-Key` header. The
`access_key` path segment is URL-encoded when it contains nested directories.

### HTTP simulation payloads

The one-shot and streaming endpoints accept this body shape:

```json
{
  "accessKey": "Heater.fmu",
  "parameters": {"ambient": 293.15},
  "options": {"startTime": 0, "stopTime": 10, "stepSize": 0.01},
  "claims": {},
  "labId": "lab-01",
  "reservationKey": "reservation-123"
}
```

`run` returns one `sim.result` object with `time`, `state: "terminated"`, and
`outputs`. `stream` returns newline-delimited JSON: `sim.step` snapshots with
`seq`, `time`, and `outputs`, followed by `sim.done`; capacity or execution
failures are emitted as an `error` object with a short `code` and, where
applicable, `retryable: true`.

### Realtime WebSocket protocol

Connect to `/internal/fmu/sessions` with the `X-Internal-Session-Token` header.
Every message is a JSON object; an optional `requestId` is echoed in the
response. `session.create` and `session.attach` require a `gatewayContext`
containing the FMU `accessKey` and the reservation bindings (`sub`, `labId`,
`reservationKey`, and active `claims`, including `exp` when supplied by the
Gateway).

```json
{
  "type": "session.create",
  "requestId": "req-1",
  "gatewayContext": {
    "accessKey": "Heater.fmu",
    "sub": "student-42",
    "labId": "lab-01",
    "reservationKey": "reservation-123",
    "claims": {"accessKey": "Heater.fmu", "exp": 1893456000}
  }
}
```

The main request/response types are:

| Request `type` | Response `type` | Required fields / effect |
|---|---|---|
| `session.create` | `session.created` | Creates and loads a session; returns `sessionId`, expiry, and capabilities |
| `session.attach` | `session.attached` | Reconnects a detached session during `FMU_ATTACH_GRACE_SECONDS` after validating the original context |
| `model.describe` | `model.description` | Returns normalized model metadata |
| `sim.initialize` | `sim.initialized` | Optional `options.startTime`, `stopTime`, `stepSize`, and `parameters` |
| `sim.step` | `sim.stepped` | Optional `stepSize` |
| `sim.runUntil` | `sim.stepped` | Required `targetTime`; optional `stepSize` |
| `sim.setInputs` | `sim.inputsSet` | `values` map keyed by model variable name |
| `sim.getOutputs` | `sim.outputs` | Optional `valueReferences` array |
| `sim.subscribeOutputs` | `sim.subscribed` | Optional `variables`, `periodMs`, `maxBatchSize`, `maxHz` |
| `sim.unsubscribeOutputs` | `sim.unsubscribed` | Stops background output events |
| `sim.getState` | `sim.state` | Returns current simulation state and time |
| `session.ping` / `ping` | `session.pong` | Liveness check |
| `session.terminate` | `session.closed` | Terminates the FMU session and temporary state |

Subscribed output events use `type: "sim.outputs"` and include `sessionId`,
monotonic `seq`, `simTime`, `values`, `batchSize`, and `dropped`. Errors use
`type: "error"`, a short `code`, a safe `message`, and `retryable`.

When the internal WebSocket closes unexpectedly, the executor detaches the
session instead of immediately terminating it. A new internal connection may
send `session.attach` with the original `sessionId` and validated
`gatewayContext` during `FMU_ATTACH_GRACE_SECONDS`. The original subject, lab,
FMU access key and reservation bindings must match; otherwise the attach is
rejected. Once the grace window expires, the FMU state and temporary files are
cleaned up.

## FMU provisioning

Place `.fmu` files directly in `fmu-data/`:

```
fmu-data/
  Heater.fmu          # accessKey = "Heater.fmu"
  my-model/
    model.fmu          # accessKey = "my-model"
```

## Tests

```bash
cd fmu-executor
pip install pytest httpx
python -m pytest tests/ -v
```
