# AppControl module reference

The user-facing AppControl guide is [`remote-app/README.md`](../README.md).
This page documents the source modules and their dependency order for
contributors maintaining the AutoHotkey controller.

## Source layout

```text
remote-app/
├── AppControl.ahk          # Entry point and argument parser
└── lib/
    ├── Config.ahk          # Constants, timing, browser flags, data paths
    ├── Utils.ahk           # Logging, polling, sizing and window discovery
    ├── WindowClosing.ahk   # Cooperative and fallback close strategies
    ├── CloseRequest.ahk    # Lab Station close-handshake protocol
    ├── RdpMonitoring.ahk   # WTS notifications and event-log fallback
    ├── SingleAppMode.ahk   # Single application lifecycle
    └── DualAppMode.ahk     # Two-application tabbed container
```

`AppControl.ahk` includes the modules in dependency order. The modules share
the controller's global state; changing an include order can break callback or
configuration initialization.

## Responsibilities

| Module | Responsibility |
| --- | --- |
| `Config.ahk` | Defaults for polling, startup, activation, browser enhancement, RDP events, and the cooperative close files. |
| `Utils.ahk` | Common logging, wait loops, executable parsing, window discovery, sizing, and browser command enhancement. |
| `WindowClosing.ahk` | Standard close cascade plus custom ClassNN and client-coordinate strategies. |
| `CloseRequest.ahk` | Presence marker and request/result handshake used by `release-session` and `prepare-session`. |
| `RdpMonitoring.ahk` | WTS session notifications first; event-log polling as fallback. |
| `SingleAppMode.ahk` | Launches, activates, hardens, and closes one application. |
| `DualAppMode.ahk` | Embeds two applications in a tabbed container and closes them together. |

## Development notes

- AppControl options use the `@` prefix so application arguments such as
  `--app` or `--private-window` pass through unchanged.
- Do not use `@close-button` and `@close-coords` together.
- Client coordinates are relative to the target window's client area; use
  `WindowSpy.exe` when configuring a custom close action.
- The browser kiosk enhancement is enabled by default for single mode and is
  disabled for dual mode. The implementation and defaults live in
  `Config.ahk`; keep this page descriptive rather than duplicating the full
  command reference.

Run the controller tests from the repository root with:

```powershell
.\scripts\run-ahk-test.ps1 remote-app\tests\ArgumentParsingTests.ahk
.\scripts\run-ahk-test.ps1 remote-app\tests\SmokeTest_DualAppMode.ahk
```
