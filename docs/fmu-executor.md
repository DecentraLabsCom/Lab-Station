# FMU Executor

The shared FMU Executor source now lives in the
[DecentraLabsCom/FMU-Executor repository](https://github.com/DecentraLabsCom/FMU-Executor).
Lab Station keeps a version-pinned release snapshot in `fmu-executor/`; Station
packages do not fetch executable code from that repository at runtime.

The Windows `Lab-Station.zip` package includes the optional sidecar, its private
Python runtime, its dependencies, and the public Smart Factory Cell demo FMU at
`fmu-executor/fmu-data/SmartFactoryCell.fmu`. No system Python installation or
`pip install` step is required. Provider-owned FMU models are still provisioned
separately. Its prepared companion `SmartFactoryCell.glb` and MIT license are
included alongside the FMU. Release packaging copies these assets from the
canonical `FMU-Executor/examples/smart-factory-cell` source. The provider
Gateway retrieves that scene from Station through the protected internal FMU
endpoint during AAS synchronization; Station does not publish the GLB directly.

To use the sidecar, configure `FMU_BACKEND_MODE=station` in Lab Gateway, set a
machine-level `FMU_INTERNAL_TOKEN` on the station and the matching
`FMU_STATION_INTERNAL_TOKEN` in the Gateway, then start the sidecar with
`LabStation.exe fmu-executor start` or the background task.

See the [Lab Station runtime guide](fmu-executor-runtime.md) for Windows
installation, service, firewall, and model-provisioning details. See the
[shared repository README](https://github.com/DecentraLabsCom/FMU-Executor)
for source development, API documentation, and container packaging.
