# Status and heartbeat contract

Lab Station exposes a persisted status document and a heartbeat envelope. New
Windows releases emit Station Contract v3 (`schemaVersion: 3.0.0`) in both
documents. The Gateway retains the documented Windows v2 compatibility
normalizer for older installations.

| Document | Location or command | Behavior |
| --- | --- | --- |
| Status | `LabStation.exe status-json [path]` | Collects a fresh status document. With no path it writes JSON to stdout; with a path it persists the document there. |
| Diagnostics export | `LabStation.exe diagnostics [path]` | Collects and persists the same status shape to `labstation/data/status.json` by default, or to the supplied path. |
| Heartbeat | `labstation/data/telemetry/heartbeat.json` | The background service refreshes it every 60 seconds and includes a top-level dashboard view plus a complete `status` copy. |

The v3 status document contains platform, profile, RemoteApp and WinRM state,
legacy AppControl-autostart detection, Wake-on-LAN and power compliance, sessions, FMU Executor health,
the complete `summary.ready` verdict, capability-specific `readiness`,
operation timestamps, `localModeEnabled`, and the latest `lastForcedLogoff`.
The heartbeat keeps the same contract fields at its top level, as well as a
complete nested `status` copy for existing file-drop consumers. It also keeps the latest operation summary at the top level so a dashboard can
read `operations.lastPrepareSession`, `lastReleaseSession`,
`lastSafeguardReboot`, `lastForcedLogoff`, and `lastPowerAction` without
descending into `status`.

The service loop also polls the command queue every five seconds. Queue
processing is independent of the one-minute status/heartbeat refresh; see the
[background command queue](command-queue.md).

`readiness.physicalLab` describes whether the station can serve a physical
laboratory, while `readiness.wake` describes whether its local WoL and power
configuration is usable. `readiness.fmu` describes whether the optional FMU
Executor is available and healthy. A wake or FMU issue can therefore leave the
physical-lab capability ready while keeping the affected capability unready;
consumers should select the capability that matches the decision they are
making.

The v2 files in this repository document the legacy Windows payload only. The
canonical v3 schemas and cross-platform fixtures live in Lab Gateway at
`contracts/station/v3/`; use them when validating current ingestion:

- [`Status JSON schema`](status-json-schema.md)
- [`status-schema.json`](status-schema.json)
- [`heartbeat-schema.json`](heartbeat-schema.json)
- [`WinRM command contract`](winrm-command-contract.md)

Consumers should treat a higher major schema version as incompatible. Unknown
fields may be added within a major version, so integrations should read only
the fields they need and tolerate additional properties. Compiled releases may
also mirror status and heartbeat files under the legacy executable-root `data`
directory during migration; the canonical paths remain under
`labstation/data`.
