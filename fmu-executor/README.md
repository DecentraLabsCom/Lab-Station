# FMU Executor

Python/FastAPI sidecar that provides the FMU execution plane on Lab Station.  
Consumed by Lab Gateway's `fmu-runner` in `station` backend mode.

## Quick start

```bash
cd fmu-executor
pip install -r requirements.txt
python -m app
```

The service listens on `http://0.0.0.0:8091` by default.

## Configuration (env vars)

| Variable | Default | Description |
|---|---|---|
| `FMU_EXECUTOR_HOST` | `0.0.0.0` | Bind address |
| `FMU_EXECUTOR_PORT` | `8091` | Bind port |
| `FMU_ROOT` | `./fmu-data` | Directory with provisioned `.fmu` files |
| `FMU_INTERNAL_TOKEN` | *(none)* | Shared secret for `X-Internal-Session-Token` |
| `FMU_MAX_SESSIONS` | `4` | Max concurrent realtime sessions |
| `FMU_SESSION_IDLE_TIMEOUT` | `300` | Idle timeout in seconds |
| `FMU_EXECUTOR_TEMP` | `<FMU_ROOT>/.tmp` | Temp dir for FMU extraction |
| `FMU_LOG_LEVEL` | `INFO` | Log level |

## Internal API

All endpoints require `X-Internal-Session-Token` header (except `/internal/health`).

| Method | Path | Description |
|---|---|---|
| GET | `/internal/health` | Health & diagnostics |
| GET | `/internal/fmu/catalog?accessKey=...` | FMU inventory for an access key |
| GET | `/internal/fmu/describe?accessKey=...` | Model description (variables, types, defaults) |
| POST | `/internal/fmu/simulations/run` | One-shot simulation run; JSON body contains `accessKey` |
| POST | `/internal/fmu/simulations/stream` | Streaming NDJSON simulation; JSON body contains `accessKey` |
| WS | `/internal/fmu/sessions` | Realtime session (step, setInputs, getOutputs) |

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
