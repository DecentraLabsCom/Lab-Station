# FMU Executor runtime

`Lab-Station.zip` includes the optional FMU Executor as a standalone Windows
runtime under `fmu-executor/runtime/`. It contains a private Python interpreter
and the Python packages required by the service. The station does not need
Python installed separately and does not need a `pip install` step.

The FMU Executor starts when Lab Station's background task or
`LabStation.exe fmu-executor start` launches it. It listens on port `8091` by
default and exposes its internal API to the configured Lab Gateway. Set the
same non-empty `FMU_INTERNAL_TOKEN` in the Lab Station machine environment and
the Gateway's `FMU_STATION_INTERNAL_TOKEN` before starting the service. The
supervisor configures an inbound Windows Firewall rule for the selected port
on Domain and Private network profiles.

Each simulation worker is placed in a private temporary directory and attached
to a Windows Job Object with CPU-time, memory, and active-process limits. The
Job Object terminates descendants when the worker is stopped. A Windows worker
also receives its own verified copy of the content-addressed FMU, so changes to
that worker's copy cannot change later cases in the same batch.

On Windows, each worker is launched in its own AppContainer with no network
capabilities. Its package identity receives read/execute access to the bundled
runtime and modify access to that worker's private directory; writes to the
AppContainer's per-worker profile storage are isolated from other workers. The
service's account SID is still the underlying account (normally `SYSTEM`), but
the AppContainer token and ACL checks constrain the worker's effective access.
The Job Object limits continue to apply. If AppContainer setup or ACL changes
fail, that worker is not released to load the FMU. Abandoned worker profiles are
removed during the next sidecar startup.

The runtime directory is granted read/execute access to the Windows
`ALL_APPLICATION_PACKAGES` principal so AppContainer workers can import Python
and the packaged FMI runtime; it contains application code, not provisioned
models or service state. Windows still has no per-file temporary-size limit or
aggregate temporary-disk quota. The Executor's
`/internal/fmu/validate/{accessKey}` response reports the effective
`workerIsolation` capabilities for the Station. On Windows,
`writesLimitedToWorkDirectory` stays false because AppContainer profile storage
is another private write location; `writesLimitedToPrivateLocations` reports
that both locations are isolated.

On Linux workers, Landlock also limits reads to the Python/system runtime, the
pinned FMU archive and the private work directory. The service token, job
database and other provisioned FMUs are outside that read allowlist.

Worker resource limits can be set in the machine environment before the
Executor starts: `FMU_WORKER_CPU_SECONDS` (default 300),
`FMU_WORKER_MEMORY_MIB` (default 1024), and `FMU_WORKER_FILE_MIB` (default 128;
Linux per-file limit). Archive checks are bounded by `FMU_MAX_ARCHIVE_BYTES`
(default 512 MiB), `FMU_MAX_EXPANDED_BYTES` (default 2 GiB), and
`FMU_MAX_ARCHIVE_ENTRIES` (default 20,000), plus
`FMU_MAX_MODEL_DESCRIPTION_BYTES` (default 8 MiB). The validation endpoint's
`?probe=true` option performs an isolated load and initialization before
publication.

The release includes the public Smart Factory Cell demo at
`fmu-executor/fmu-data/SmartFactoryCell.fmu`, with its companion
`SmartFactoryCell.glb` and license alongside. Its access key is
`SmartFactoryCell.fmu`. It is ready for provider registration after installing
the Station package. Release packaging copies these files from the canonical
FMU-Executor example source. The demo assets are separate package files, not
part of the private Executor runtime. Other provider FMU models remain separately
provisioned under `fmu-executor/fmu-data/`; the release package contains no
other models. The FMU runs on the Windows x64 Station execution backend. When
the AAS is synchronized, the Gateway requests the matching GLB from Station's
internal endpoint, stores it in the Gateway's public immutable asset volume,
and records that Gateway path in the AAS. Station never serves the scene as a
public asset.

Station serves `GET /internal/fmu/companion-scene` only with the configured
`X-Internal-Session-Token` and an `X-FMU-Access-Key`. It derives the `.glb`
filename from the validated `.fmu` and returns it only when the sibling file
is inside the configured FMU root. Lab Gateway uses this endpoint during its
authenticated Lab Manager import; the route is not a public asset URL.

The data directory remains outside the private runtime files, so releases can
be upgraded without replacing provider-owned models.

Job history and results are stored separately under
`%ProgramData%\DecentraLabs\Lab Station\fmu-executor-state`. The service
creates the directory and restricts access to `SYSTEM` and local
Administrators. It persists across Station upgrades and is not part of the
release ZIP.

The shared source, release history, container packaging, and API documentation
live in the [DecentraLabsCom/FMU-Executor repository](https://github.com/DecentraLabsCom/FMU-Executor).
The Station snapshot records the pinned source revision in
[`fmu-executor/SOURCE.lock.json`](../fmu-executor/SOURCE.lock.json).
