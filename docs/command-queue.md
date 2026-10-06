# Background command queue

The Lab Station background task can execute a small set of commands from an
INI file. This is an asynchronous alternative to invoking `LabStation.exe`
through WinRM. It is intended for a trusted local file drop managed by Lab
Gateway; it is not a public network API.

## Lifecycle

The queue is enabled by the `service-loop` started by
`LabStation.exe service install` and `service start`:

1. Write a complete `.ini` file to `labstation/data/commands/inbox/`.
2. The service reads the `[Command]` section and processes the file.
3. A JSON result is written to `commands/results/<id>.json`.
4. The input file is moved to `commands/processed/` with a timestamp and ID.

The service polls the inbox every five seconds. Status and heartbeat documents
are refreshed once per minute, independently of queue processing.

## Input format

Every file must contain a `[Command]` section. `id` is optional; when it is
omitted, the file name without `.ini` becomes the ID.

```ini
[Command]
id=job-20261006-01
name=prepare-session
user=LABUSER
guard-grace=90
guard-notify=yes
```

Supported `name` values and their options are:

| Name | Options |
| --- | --- |
| `prepare-session` | `user`, `guard=yes\|no`, `guard-grace`, `guard-message`, `guard-notify=yes\|no` |
| `release-session` | `user`, `reboot=yes\|no`, `reboot-timeout` |
| `session-guard` | `user`, `grace`, `message`, `notify=yes\|no` |
| `status-json` | `path` (defaults to `labstation/data/status.json`) |
| `reboot-if-needed` | `force=yes\|no`, `timeout`, `reason`, `user` |
| `power-shutdown` | `delay`, `reason`, `force=yes\|no`, `skip-wake-check=yes\|no`, `repair-wake=yes\|no`, `require-wake=yes\|no` |
| `power-hibernate` | Same options as `power-shutdown` |

Boolean values may be `yes`/`no`, `true`/`false`, `on`/`off`, `1`/`0`.
Numeric values must be non-negative integers. Unknown command names produce a
hard-failure result and are still archived.

## Result format

Results are written as JSON. The `options` object contains the normalized
values used by Lab Station; `metadata` preserves the original INI values.

```json
{
  "id": "job-20261006-01",
  "command": "prepare-session",
  "completedAt": "2026-10-06T12:00:00Z",
  "success": true,
  "exitCode": 0,
  "message": "Prepare-session completed",
  "options": {
    "user": "LABUSER",
    "guardGrace": 90,
    "guardNotify": true
  },
  "metadata": {
    "name": "prepare-session",
    "user": "LABUSER",
    "guard-grace": "90",
    "guard-notify": "yes"
  },
  "sourceFile": "C:\\LabStation\\labstation\\data\\commands\\inbox\\job-20261006-01.ini"
}
```

Queue results use these meanings:

| `exitCode` | Meaning |
| --- | --- |
| `0` | Completed successfully. |
| `1` | Completed with an operational warning, for example a session cleanup step did not fully succeed. |
| `2` | Invalid, unsupported, or failed command. |

The result file is the source of truth for the asynchronous operation. Do not
infer completion from the input file disappearing: the service archives input
files after writing the result, including failed results.

## Operational and security rules

- Restrict write access to `commands/inbox` to the Gateway/service account.
- Treat `path` as a privileged output path; only submit destinations that the
  station is expected to write.
- Do not put passwords, WinRM credentials, or FMU tokens in an INI file.
- Prefer direct WinRM for operations that need an immediate response. Use the
  queue when the caller can poll for the result.
- Processed input files and result files contain operational data. Retain or
  ship them according to the Gateway audit policy.

The command behavior itself is defined by the Lab Station CLI and the
[WinRM command contract](winrm-command-contract.md).
