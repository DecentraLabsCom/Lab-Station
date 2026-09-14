# Status and heartbeat contract

Lab Station exposes two related JSON documents with the same
`schemaVersion` (`1.0.0`):

| Document | Location or command | Behavior |
| --- | --- | --- |
| Status | `LabStation.exe status-json [path]` | Writes a fresh status document to stdout when `path` is omitted, or to the supplied path. |
| Diagnostics export | `LabStation.exe diagnostics [path]` | Writes a fresh status document to `labstation/data/status.json` by default, or to the supplied path. |
| Heartbeat | `labstation/data/telemetry/heartbeat.json` | The background service refreshes it once per service-loop interval and includes a top-level `status` copy plus `operations`. |

The status document contains the station profile, RemoteApp and WinRM state,
autostart, Wake-on-LAN and power compliance, sessions, FMU Executor health,
the `summary.ready` verdict, operation timestamps, `localModeEnabled`, and the
latest `lastForcedLogoff`. The heartbeat adds `host` and application `version`
for file-drop consumers.

Use the Markdown schema guide for the field contract and the machine-readable
schemas when validating ingestion:

- [`Status JSON schema`](status-json-schema.md)
- [`status-schema.json`](status-schema.json)
- [`heartbeat-schema.json`](heartbeat-schema.json)
- [`WinRM command contract`](winrm-command-contract.md)

Consumers should treat a higher major schema version as incompatible. Unknown
fields may be added within a major version, so integrations should read only
the fields they need and tolerate additional properties.
