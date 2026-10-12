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

The bundle does not contain lab FMU models. Provision model files under
`fmu-executor/fmu-data/` on the station. That directory is created when the
sidecar starts and remains outside the private runtime files, so releases can
be upgraded without replacing the provisioned models.

Job history and results are stored separately under
`%ProgramData%\DecentraLabs\Lab Station\fmu-executor-state`. The service
creates the directory and restricts access to `SYSTEM` and local
Administrators. It persists across Station upgrades and is not part of the
release ZIP.

For source development and API details, see the [FMU Executor project guide](../fmu-executor/README.md).
