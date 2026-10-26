---
description: Windows implementation of DecentraLabs Lab Station, paired with the Linux station agent.
---

# Lab Station (Windows)

[![Tests](https://github.com/DecentraLabsCom/Lab-Station/actions/workflows/tests.yml/badge.svg)](https://github.com/DecentraLabsCom/Lab-Station/actions/workflows/tests.yml)
[![Security](https://github.com/DecentraLabsCom/Lab-Station/actions/workflows/codeql.yml/badge.svg)](https://github.com/DecentraLabsCom/Lab-Station/actions/workflows/codeql.yml)
[![Release](https://github.com/DecentraLabsCom/Lab-Station/actions/workflows/release.yml/badge.svg)](https://github.com/DecentraLabsCom/Lab-Station/actions/workflows/release.yml)

This is the Windows implementation of DecentraLabs **Lab Station**. It is the
Windows counterpart to [Lab Station (Linux)](https://github.com/DecentraLabsCom/Lab-Station-Linux).
Both implementations integrate with Lab Gateway and emit Station Contract v3;
the management transport and host-specific controls differ by platform.

The Windows application is built around the AutoHotkey-based station agent and
the separate [AppControl RemoteApp launcher](remote-app/README.md).

## Product and platform support

Lab Station prepares and operates a Windows workstation for remote laboratory
sessions. It provides setup and profile management, station status, power and
Wake-on-LAN controls, session preparation and recovery. Lab Gateway remains the
authority for remote reservations and the per-host trust decision.

## Deployment profiles

| Profile | Intended use |
|---|---|
| `server` | Dedicated remote laboratory workstation. The setup wizard can configure LABUSER autologon and the locked-down station flow. |
| `hybrid` | Workstation shared with an instructor. It does not configure LABUSER autologon and can protect local sessions during remote reservations. |

The optional FMU Executor can accompany either profile. See
[FMU execution](#optional-fmu-execution).

## Install and operate

The recommended installation is `Lab-Station.zip` from the
[Windows releases](https://github.com/DecentraLabsCom/Lab-Station/releases).
Extract it as one unit and run the setup wizard from an elevated PowerShell
session:

```powershell
Expand-Archive .\Lab-Station.zip -DestinationPath C:\LabStation -Force
Set-Location 'C:\LabStation\Lab Station'
.\LabStation.exe setup
```

The wizard guides profile selection and station configuration. For a source
checkout or compiled development build, use
[Development, build and verification](docs/development.md).

Useful status checks from the installed directory:

```powershell
.\LabStation.exe status-json
.\LabStation.exe winrm status
.\LabStation.exe service status
```

## Lab Gateway integration

Gateway manages Windows stations over authenticated WinRM HTTPS. Lab Station
configures the listener and exports its public certificate; Gateway stores and
checks trust separately for each host. Remote lab applications are launched
through AppControl. The station exposes the shared Contract v3 status and
operation model.

See [WinRM command contract](docs/winrm-command-contract.md),
[Status and heartbeat](docs/status-and-heartbeat.md), and the
[AppControl guide](remote-app/README.md) for the detailed contracts and setup.

## Optional FMU execution

The Windows release package includes the optional shared FMU Executor. Lab
Station manages its lifecycle when Gateway is configured for the Station FMU
backend. See [FMU Executor on Windows Lab Station](docs/fmu-executor.md) for
the package contents and station-specific integration; the shared Executor
repository owns runtime configuration and execution behavior.

## Development and releases

The station application is developed with AutoHotkey v2. Release builds package
the desktop application, AppControl, and optional FMU Executor runtime. Build,
test, and release instructions are in
[Development, build and verification](docs/development.md).

## Documentation

| Topic | Guide |
|---|---|
| Shared station navigation | [Documentation contents](SUMMARY.md) |
| WinRM, Gateway trust, and commands | [WinRM command contract](docs/winrm-command-contract.md) |
| Status, heartbeat, and schemas | [Status and heartbeat contract](docs/status-and-heartbeat.md), [status JSON schema](docs/status-json-schema.md), [heartbeat schema](docs/heartbeat-schema.md) |
| Shared instructor workstations | [Hybrid operations](docs/hybrid-operations.md) |
| RemoteApp launch behavior | [AppControl](remote-app/README.md) and [Windows configuration](remote-app/windows-configuration.md) |
| FMU Executor on Windows | [Station integration and package contents](docs/fmu-executor.md) |
| Build and verification | [Development guide](docs/development.md) |

For topics not covered by these guides, the
[Lab Station Linux README](https://github.com/DecentraLabsCom/Lab-Station-Linux/blob/main/README.md)
is the companion platform overview.
