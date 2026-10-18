# Heartbeat JSON schema (v2)

This page presents the Windows heartbeat contract in a format GitBook can
render. The current `main` branch schema version is `2.0.0`.

The machine-readable artifact is `docs/heartbeat-schema.json` and is available
as a [raw v2 schema download](https://raw.githubusercontent.com/DecentraLabsCom/Lab-Station/main/docs/heartbeat-schema.json).
Its required envelope fields are `timestamp`, `schemaVersion`, `host`,
`version`, `remoteAppEnabled`, `legacyAppControlAutostart`, `wake`,
`readiness`, `summary`, `operations`, and `status`. The `schemaVersion` must
match `2.x`; the nested `status` object is validated by `status-schema.json`.

The heartbeat adds the station `host` and application `version` to the status
document and carries a complete nested `status` copy. The envelope also keeps
the latest operation summary at the top level for file-drop consumers.

For the full field descriptions, see the [status and heartbeat
contract](status-and-heartbeat.md). For the raw JSON file, use the
[machine-readable v2 schema](https://raw.githubusercontent.com/DecentraLabsCom/Lab-Station/main/docs/heartbeat-schema.json).
