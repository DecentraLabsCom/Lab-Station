# FMU Executor

The shared FMU Executor source now lives in the
[DecentraLabsCom/FMU-Executor repository](https://github.com/DecentraLabsCom/FMU-Executor).
Lab Station keeps a version-pinned release snapshot in `fmu-executor/`; Station
packages do not fetch executable code from that repository at runtime.

The Windows `Lab-Station.zip` package includes the optional sidecar, its private
Python runtime, and its dependencies. No system Python installation or
`pip install` step is required. FMU model files are provisioned separately.

To use the sidecar, configure `FMU_BACKEND_MODE=station` in Lab Gateway, set a
machine-level `FMU_INTERNAL_TOKEN` on the station and the matching
`FMU_STATION_INTERNAL_TOKEN` in the Gateway, then start the sidecar with
`LabStation.exe fmu-executor start` or the background task.

See the [Lab Station runtime guide](fmu-executor-runtime.md) for Windows
installation, service, firewall, and model-provisioning details. See the
[shared repository README](https://github.com/DecentraLabsCom/FMU-Executor)
for source development, API documentation, and container packaging.
