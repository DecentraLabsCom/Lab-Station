---
description: Windows Lab Station assistant for RemoteApp, Wake-on-LAN, diagnostics, session cleanup, and FMU execution.
---

# Lab Station

[![Tests](https://github.com/DecentraLabsCom/Lab-Station/actions/workflows/tests.yml/badge.svg)](https://github.com/DecentraLabsCom/Lab-Station/actions/workflows/tests.yml)
[![Security Scan](https://github.com/DecentraLabsCom/Lab-Station/actions/workflows/codeql.yml/badge.svg)](https://github.com/DecentraLabsCom/Lab-Station/actions/workflows/codeql.yml)
[![Release](https://github.com/DecentraLabsCom/Lab-Station/actions/workflows/release.yml/badge.svg)](https://github.com/DecentraLabsCom/Lab-Station/actions/workflows/release.yml)

Lab Station is the Windows-side control application for DecentraLabs. It
prepares a workstation for RemoteApp access, keeps Wake-on-LAN and power
settings compliant, exposes diagnostics and telemetry, and coordinates the
session lifecycle used by Lab Gateway.

The repository contains two runtime components:

- **Lab Station** (`labstation/`): setup wizard, CLI, desktop/tray UI, WinRM,
  session cleanup, diagnostics, telemetry, power control, and the background
  task.
- **AppControl** (`remote-app/`): the RemoteApp launcher that starts one or
  two lab applications and closes them on RDP/session events.

The optional **FMU Executor** (`fmu-executor/`) runs as a Python sidecar,
separate from the Windows executables. `Lab-Station.zip` includes its runtime
source and requirements; the Python interpreter and installed dependencies
must be provisioned on the station. It is used when Lab Gateway is configured
with `FMU_BACKEND_MODE=station`.

## Choose the station profile

| Profile | Intended use | Important behavior |
| --- | --- | --- |
| `server` | Dedicated remote laboratory workstation | The wizard can configure LABUSER autologon and the locked-down station flow. |
| `hybrid` | Workstation shared by an instructor and remote users | Does not configure LABUSER autologon; local sessions are detected and can be evicted before a reservation. |

The `local-mode.flag` file is a policy signal for local-only use. Lab Station
reports it in status and heartbeat documents; Lab Gateway is responsible for
blocking or confirming remote reservations while the flag exists.

## Quick start

### From a release package

The recommended release is `Lab-Station.zip`. Extract it as one unit; the
archive contains `LabStation.exe`, `LabStationPanel.exe`, `WindowSpy.exe`, the
branding image, `remote-app/AppControl.exe`, and the optional `fmu-executor/`
runtime source with its requirements. It does not bundle Python or install
Python dependencies.

From an elevated PowerShell session:

```powershell
Expand-Archive .\Lab-Station.zip -DestinationPath C:\LabStation -Force
Set-Location 'C:\LabStation\Lab Station'

.\LabStation.exe setup
.\LabStation.exe status-json 'C:\LabStation\status.json'
.\LabStation.exe winrm status
.\LabStation.exe service install
.\LabStation.exe service start
```

The setup wizard applies the selected profile, RemoteApp policy, Wake-on-LAN
settings, WinRM HTTPS configuration, and diagnostics export. It can also offer
to install the background task. Review the [WinRM command contract](docs/winrm-command-contract.md)
before handing the generated account and public certificate to Lab Gateway.

### From source

Install AutoHotkey v2 and run the scripts from the repository root:

```powershell
& 'C:\Program Files\AutoHotkey\v2\AutoHotkey64.exe' .\labstation\LabStation.ahk setup
& 'C:\Program Files\AutoHotkey\v2\AutoHotkey64.exe' .\labstation\LabStation.ahk status
```

For a compiled local build, see [Development, build and verification](docs/development.md).

### Optional FMU Executor

The release package already contains the optional sidecar source under
`fmu-executor/`. When Lab Gateway uses `FMU_BACKEND_MODE=station`, install
Python 3.11 or newer and the packaged requirements in an environment readable
by the `SYSTEM` task, set a machine-level `FMU_INTERNAL_TOKEN`, and start the
sidecar through `LabStation.exe fmu-executor start` or the background task.
The complete installation, API, token, firewall, and provisioning contract is
in the [FMU Executor guide](fmu-executor/README.md).

## CLI reference

Run `LabStation.exe` with one of the commands below. Commands that change
registry, firewall, account, power, WinRM, or scheduled-task state require an
elevated administrator session.

| Command | Purpose |
| --- | --- |
| `setup` | Runs the profile-aware setup wizard. |
| `remoteapp` | Enables the Windows policy required for unlisted RemoteApp programs. |
| `wol` | Applies the station's Wake-on-LAN and power settings. |
| `winrm configure\|status` | Creates/inspects the WinRM HTTPS listener on port 5986 and exports its public certificate. |
| `status` | Shows a human-readable summary; it does not emit JSON. |
| `status-json [path]` | Collects diagnostics and writes JSON to stdout when `path` is omitted, or to `path` when supplied. |
| `diagnostics [path]` | Exports diagnostics to `labstation/data/status.json` by default, or to `path`. |
| `account create\|autologon\|lockdown\|setup ...` | Manages the lab account, autologon, and local-user lockdown. |
| `session guard ...` | Warns and logs off active users other than the selected lab user. |
| `prepare-session ...` | Runs session guard by default, closes AppControl cooperatively, cleans the selected lab profile, and resets controller logs. |
| `release-session ...` | Closes AppControl, logs off the lab user, and optionally schedules a reboot. |
| `recovery reboot-if-needed ...` | Reboots only when station health heuristics require recovery, unless `--force` is used. |
| `power shutdown\|hibernate ...` | Validates WoL and schedules a controlled power action. |
| `energy audit [--json=path]` | Reports power-plan, NIC, and WoL compliance. |
| `fmu-executor start\|stop\|restart\|status` | Controls or inspects the optional FMU sidecar. |
| `tray` / `gui` | Starts the tray icon or desktop control panel. |
| `service install\|start\|stop\|status\|uninstall` | Manages the `LabStation\BackgroundService` scheduled task. |

Useful reservation options include:

```text
prepare-session --user=LABUSER --guard-grace=90 --guard-message="Remote reservation confirmed"
release-session --user=LABUSER --reboot --reboot-timeout=15
session guard --grace=120 --user=LABUSER --silent
power shutdown --delay=60 --reason="Reservation completed" --require-wake
```

`session guard` uses `--grace`, `--message`, and `--silent`; the corresponding
`prepare-session` options are `--guard-grace`, `--guard-message`, and
`--guard-silent`/`--guard-notify=no`. This distinction matters when commands
are proxied by Lab Gateway.

## Files produced on the station

| Path | Purpose |
| --- | --- |
| `labstation/labstation.log` | Main Lab Station log. |
| `labstation/data/status.json` | Latest persisted status document. |
| `labstation/data/telemetry/heartbeat.json` | Status snapshot plus host/version and operation summary, refreshed by the background task. |
| `labstation/data/telemetry/session-guard-events.jsonl` | Append-only audit events for forced logoffs. |
| `labstation/data/service-state.ini` | Latest results for prepare, release, recovery, forced-logoff, and power operations. |
| `labstation/data/local-mode.flag` | Local-only policy signal. Presence means local mode is enabled. |
| `labstation/data/commands/inbox/` | Trusted asynchronous command input. |
| `labstation/data/commands/results/` | JSON results for queued commands. |
| `labstation/data/commands/processed/` | Archived queue input files. |

The `status-json` and `diagnostics` commands use the same status shape. The
machine-readable contract is versioned at `2.0.0`; see the [status and heartbeat
contract](docs/status-and-heartbeat.md), [human-readable schema guide](docs/status-json-schema.md),
and the canonical [status schema](docs/status-schema.json). The background
queue has a separate [queue contract](docs/command-queue.md).

## Lab Gateway integration

### WinRM

Lab Station owns the station-side HTTPS listener and exports the public
certificate. Lab Gateway owns the per-host trust decision. The supported flow
is:

1. Run `LabStation.exe winrm configure` as administrator.
2. Give Lab Gateway the generated account and
   `C:\ProgramData\DecentraLabs\Lab Station\winrm-server.cer`.
3. Store the certificate through the host's `WinRM TLS trust` control and
   verify the connection.
4. Use direct WinRM for synchronous commands or the background queue when the
   caller can poll a result.

Only WinRM HTTPS on port 5986 is part of the current contract. Do not copy a
private key, disable certificate validation, or use `TrustedHosts` as a
replacement for per-host trust. See the [full WinRM contract](docs/winrm-command-contract.md).

### RemoteApp and AppControl

Configure Guacamole to launch `remote-app\AppControl.exe`, passing the target
window class and application command. Use `@dual` for a two-application tabbed
container. The dedicated [AppControl guide](remote-app/README.md) covers
quoting, custom close actions, browser kiosk flags, and troubleshooting; its
[module reference](remote-app/lib/README.md) is for contributors.

### Status and heartbeat

The service refreshes the heartbeat approximately once per minute. The
heartbeat exposes both a top-level `summary`, `wake`, `readiness`, and
`operations` view for dashboards and a complete `status` document for detailed
diagnostics. Consumers should branch on capability-specific readiness rather
than treating an optional FMU or WoL failure as proof that every station
capability is unavailable.

## UI screenshots

The desktop panel is useful during setup and local troubleshooting. Values in
these screenshots are workstation-specific and should not be treated as
configuration defaults.

![Lab Station main control panel](docs/images/labstation-main-panel.png)

![FMI/FMU connector panel](docs/images/labstation-connectors-fmi.png)

![Setup profile selector](docs/images/labstation-setup-profile.png)

## Operations and development docs

- [BIOS and Wake-on-LAN playbook](docs/bios-wol-playbook.md) - firmware,
  Windows NIC, power-state, and validation checklist.
- [Hybrid operations](docs/hybrid-operations.md) - local/instructor use and
  reservation hand-off rules.
- [Status and heartbeat contract](docs/status-and-heartbeat.md) - file
  locations, refresh behavior, and compatibility rules.
- [WinRM command contract](docs/winrm-command-contract.md) - transport,
  trust, credentials, commands, and reservation sequencing.
- [Background command queue](docs/command-queue.md) - asynchronous INI input
  and JSON results.
- [Development, build and verification](docs/development.md) - toolchain,
  build, tests, and release layout.

## Security notes

- Do not pass passwords, WinRM credentials, or FMU tokens in public URLs,
  source files, queue files, or shell history.
- The `account` command accepts a password argument for automation, but process
  listings and shell history may expose it. Prefer the wizard or a protected
  secret mechanism.
- Restrict the command-queue inbox and FMU port to the intended Gateway/private
  network.
- Treat telemetry and session-guard audit files as operational records; they
  may contain host names, user names, session IDs, and operator messages.
