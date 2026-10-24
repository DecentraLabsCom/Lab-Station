# Heartbeat JSON schema

This page summarizes the machine-readable heartbeat schemas in a format that
GitBook can render. New station releases emit Station Contract v3; the local
`heartbeat-schema.json` file is retained for older Windows v2 payloads.

## Current contract: Station v3

The current heartbeat schema is maintained in Lab Gateway. The Lab Station
contract bundle includes a pinned copy for public documentation and validation:

- [V3 heartbeat schema in the pinned Station bundle](../contracts/station/gateway-contracts/v3/heartbeat.schema.json)
- The pinned contract revision is recorded in [`schema-bundle.lock.json`](../contracts/station/schema-bundle.lock.json).

The v3 envelope requires `schemaVersion: "3.0.0"`, timestamp, host and
application version, platform, profile, management and remote-access status,
summary, capability readiness, sessions, operations, and `localModeEnabled`.
Station implementations may also include a nested `status` copy and
platform-specific fields.

## Legacy Windows contract: v2

The local `docs/heartbeat-schema.json` validates the legacy Windows v2
envelope. Its `schemaVersion` matches `2.x`; it is not the schema to use for
new v3 payloads. [Download the legacy v2 schema](https://raw.githubusercontent.com/DecentraLabsCom/Lab-Station/main/docs/heartbeat-schema.json).

For the status and heartbeat lifecycle, see the [status and heartbeat
contract](status-and-heartbeat.md) and [WinRM command
contract](winrm-command-contract.md).
