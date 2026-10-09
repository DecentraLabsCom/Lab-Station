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
