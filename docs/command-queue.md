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
The setup wizard installs and starts the background task. It checks lease
expiry on each service-loop iteration; the loop sleeps five seconds between
iterations, so a long-running queued command can delay the next check. Keep the
task running while reservation leases are active. The expiry watchdog records
each Release attempt under its own operation ID. Partial cleanup failures and
interrupted operations with unknown outcomes keep the station closed in
`recovery-required`; after expiry, a separate lease-bound Release reconciliation
runs every 60 seconds until cleanup succeeds. A lease-bound Release failure
can start this loop before expiry; a failed Prepare waits for reservation
expiry before Release. A scheduled Gateway retry also uses a fresh lease-bound
Release ID and protects local sessions before FMU cleanup. Neither reconciler
replays the uncertain operation ID. Recovery waits for valid lease data, local
mode off, and a known session inventory.
Hybrid waits while any local user session is active; both profiles wait for
active non-LABUSER sessions. Dedicated may continue past a local LABUSER
session. Invalid lease identity or journal state requires operator repair.

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
| `power-shutdown` | `delay`, `reason`, `force=yes\|no`, `skip-wake-check=yes\|no`, `repair-wake=yes\|no`, `require-wake=yes\|no`, `require-idle=yes\|no` |
| `power-hibernate` | Same options except `require-idle`, which is shutdown-only |

Boolean values may be `yes`/`no`, `true`/`false`, `on`/`off`, `1`/`0`.
Numeric values must be non-negative integers. Unknown command names produce a
hard-failure result and are still archived.
For hybrid Prepare, `guard=no` is an explicit administrative bypass: it skips
the graphical acknowledgement and grace period, then immediately evicts an
eligible local console session when eviction is enabled. Without that bypass,
each local session that remains active must affirmatively acknowledge its
dialog. A session that signs out during the prompt is already released; a
declined, timed-out, suppressed, or unavailable prompt for an active session
makes Prepare fail before logoff or cleanup. The bypass does not override the
profile or local-session policy.

Queued Prepare and Release use the same administrative lease admission as the
direct operator commands. They refuse while a reservation or demo lease is
active; lease-bound work must use its matching reservation flow.

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
| `1` | Completed with a nonfatal operational warning, such as a standalone session-guard notice failure or a deferred Release reboot. |
| `2` | Invalid, unsupported, refused, or incomplete command. Failed Prepare cleanup and Release session termination require recovery. |

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
