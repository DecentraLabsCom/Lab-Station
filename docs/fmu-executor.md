# FMU Executor on Windows Lab Station

This page covers the Windows Lab Station package and its connection to Lab
Gateway. FMU execution behavior, FMI support, worker isolation, API contracts,
and runtime configuration are owned by the shared
[FMU Executor repository](https://github.com/DecentraLabsCom/FMU-Executor).

## What the Windows package includes

The Windows release builds FMU Executor from a clean checkout of the canonical
repository at the commit recorded in
[`fmu-executor/SOURCE.lock.json`](../fmu-executor/SOURCE.lock.json). The
checkout is a build and CI input; Lab Station does not track a second copy of
the Executor's `app/` or tests. The release contains the frozen runtime and its
private Python dependencies, so an installed station does not need system
Python or download executable source at runtime.

The package keeps the runtime and model data separate. It includes six
reference FMUs and the Smart Warehouse Cell example under
`fmu-executor/fmu-data/`; the example includes the Windows x64 FMU, GLB, and
self-contained Three.js app. Provider-specific FMUs are provisioned separately.
Release packaging takes these assets from the canonical FMU Executor examples.

When a provider links a companion visualization during AAS synchronization,
Lab Gateway imports the asset from the Station through the protected Executor
connection. The pinned Executor prefers a local webapp ZIP declared by
FMI-LS-REF or available as a same-stem `.webapp.zip`, then a declared GLB, then
a same-stem `.glb`. Gateway retains the same-stem webapp-then-GLB lookup for
models whose Executor metadata does not expose a companion asset. The Gateway
documentation owns asset publication and the Marketplace viewer flow; see the
[AAS visual asset guide in Lab Gateway](https://github.com/DecentraLabsCom/Lab-Gateway/blob/main/docs/aas-fmu-visual-assets.md).

## Enable and start the sidecar

When Lab Gateway uses `FMU_BACKEND_MODE=station`, start or inspect the sidecar
with:

```powershell
.\LabStation.exe fmu-executor start
.\LabStation.exe fmu-executor status
```

The Lab Station background task can also start the sidecar. Its default
service lifecycle and packaged location are managed by Lab Station. The shared
FMU Executor guides own internal tokens, endpoint configuration, firewall
requirements, worker limits, and runtime behavior; use the
[FMU Executor documentation index](https://github.com/DecentraLabsCom/FMU-Executor).

For local source development, set `FMU_EXECUTOR_SOURCE_DIR` to a local
FMU-Executor checkout with its runtime dependencies installed. The station can
then launch `python -m app` from that directory when no bundled executable is
present. Normal releases use the frozen runtime instead.
