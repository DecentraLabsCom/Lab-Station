---
description: Human-readable documentation for the Lab Station status JSON schema.
---

# Status JSON schema

This page documents the machine-readable contract produced by Lab Station. The
canonical JSON Schema remains available as [`status-schema.json`](status-schema.json)
for validators and automated consumers.

## Where the schema applies

The schema validates both:

- the document emitted by `LabStation.exe status-json [path]`;
- the `status` member inside `labstation/data/telemetry/heartbeat.json`.

The `diagnostics` command writes the same status shape to
`labstation/data/status.json` by default.

## Versioning

Every status document includes `schemaVersion`. The current version is
`1.0.0`, and the JSON Schema accepts the `1.x` major version.

Consumers should reject or warn on a higher major version. New fields may be
added within a major version, so consumers should ignore fields they do not
need and tolerate additional properties.

## Required top-level fields

| Field | Type | Description |
| --- | --- | --- |
| `schemaVersion` | string | Telemetry contract version, currently `1.0.0`. |
| `timestamp` | date-time string | UTC timestamp for the status collection. |
| `stationProfile` | `server` or `hybrid` | Operating profile selected for the station. |
| `remoteAppEnabled` | boolean | Whether the RemoteApp policy is enabled. |
| `winrm` | object | WinRM readiness and diagnostic details. |
| `autoStartConfigured` | boolean | Whether AppControl is configured to start automatically. |
| `wake` | object | Wake-on-LAN device and NIC diagnostics. |
| `power` | object | Active power plan and sleep/hibernate compliance. |
| `summary` | object | Aggregated readiness result and issue list. |
| `operations` | object | Recent service operations and their outcomes. |
| `localSessionActive` | boolean | Whether a local or console user other than the lab user is active. |
| `localModeEnabled` | boolean | Whether the station is marked for local-only use. |

## Optional diagnostic fields

The status document can also include the following diagnostic blocks:

| Field | Description |
| --- | --- |
| `identity` | Lab account and local profile information. |
| `biosChecklist` | BIOS/UEFI Wake-on-LAN checks shown to the operator. |
| `policy` | Autologon, Remote Desktop Users and interactive-logon policy state. |
| `sessions` | Current sessions and lab-user state. |
| `fmuExecutor` | FMU Executor availability, health and configured port. Secrets are represented only by boolean state. |
| `lastForcedLogoff` | The latest forced-logoff record, when one exists. |

Unknown fields are allowed so that diagnostics can grow without invalidating
consumers that only use the stable fields above.

## Stable nested fields

The `summary` object always contains:

| Field | Type | Description |
| --- | --- | --- |
| `state` | string | Usually `ready` or `needs-action`. |
| `ready` | boolean | `true` only when the station passes its readiness checks. |
| `issues` | string array | Human-readable reasons why the station needs attention. |

The `wake` object exposes `armedCount` and a `nicPower` array when available.
Each NIC entry includes the interface description, operational state, the
driver-neutral registry values when exposed, and `wolReady`. Disconnected
physical adapters remain visible for diagnostics but do not fail station
readiness; active adapters that are configured but absent from
`powercfg /devicequery wake_armed` are listed in `nicNotArmed`.
The `power` object exposes `sleepCompliant` and `hibernateCompliant` so the
Gateway can determine whether the station remains safe to power down and wake.

## Example

```json
{
  "schemaVersion": "1.0.0",
  "timestamp": "2026-09-02T12:00:00Z",
  "stationProfile": "server",
  "remoteAppEnabled": true,
  "winrm": { "ready": true },
  "autoStartConfigured": true,
  "wake": { "armedCount": 1, "nicPower": [] },
  "power": {
    "activePlan": "Balanced",
    "sleepCompliant": true,
    "hibernateCompliant": true
  },
  "summary": { "state": "ready", "ready": true, "issues": [] },
  "operations": {},
  "localSessionActive": false,
  "localModeEnabled": false
}
```

For the complete draft-07 definition, use
[`status-schema.json`](status-schema.json). The enclosing heartbeat contract is
described in [Status and heartbeat contract](status-and-heartbeat.md).
