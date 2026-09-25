# Status and heartbeat contract

Lab Station exposes two related JSON documents with the same
`schemaVersion` (`2.0.0`):

| Document | Location or command | Behavior |
| --- | --- | --- |
| Status | `LabStation.exe status-json [path]` | Writes a fresh status document to stdout when `path` is omitted, or to the supplied path. |
| Diagnostics export | `LabStation.exe diagnostics [path]` | Writes a fresh status document to `labstation/data/status.json` by default, or to the supplied path. |
| Heartbeat | `labstation/data/telemetry/heartbeat.json` | The background service refreshes it once per service-loop interval and includes a top-level `status` copy plus `operations`. |

The status document contains the station profile, RemoteApp and WinRM state,
legacy AppControl-autostart detection, Wake-on-LAN and power compliance, sessions, FMU Executor health,
the complete `summary.ready` verdict, capability-specific `readiness`,
operation timestamps, `localModeEnabled`, and the latest `lastForcedLogoff`.
The heartbeat adds `host` and application `version` for file-drop consumers.

`readiness.physicalLab` describes whether the station can serve a physical
laboratory. `readiness.fmu` describes whether the optional FMU Executor is
available and healthy. A missing or unhealthy FMU Executor can therefore leave
the physical-lab capability ready while keeping the FMU capability unready;
consumers should select the capability that matches their resource type.

Use the Markdown schema guide for the field contract and the machine-readable
schemas when validating ingestion:

- [`Status JSON schema`](status-json-schema.md)
- [`status-schema.json`](status-schema.json)
- [`heartbeat-schema.json`](heartbeat-schema.json)
- [`WinRM command contract`](winrm-command-contract.md)

Consumers should treat a higher major schema version as incompatible. Unknown
fields may be added within a major version, so integrations should read only
the fields they need and tolerate additional properties.
