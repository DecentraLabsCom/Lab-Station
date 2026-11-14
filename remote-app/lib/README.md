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
    ├── Utils.ahk           # Logging, polling, window dimensions and browser flags
    ├── WindowClosing.ahk   # Cooperative and fallback close strategies
    ├── CloseRequest.ahk    # Lab Station close-handshake protocol
    ├── RdpMonitoring.ahk   # WTS notifications and event-log fallback
    ├── SingleAppMode.ahk   # Single application lifecycle
    └── WorkspaceMode.ahk  # Manifest-driven 2-5 app tabbed workspace
```

`AppControl.ahk` includes the modules in dependency order. The modules share
the controller's global state; changing an include order can break callback or
configuration initialization.

## Responsibilities

| Module | Responsibility |
| --- | --- |
| `Config.ahk` | Defaults for polling, startup, activation, browser enhancement, RDP events, and the cooperative close files. |
| `WorkspaceConfig.ahk` | Maximum workspace app count and the protected ProgramData manifest root. |
| `Utils.ahk` | Common logging, wait loops, executable parsing, window dimensions, and browser command enhancement. |
| `WindowClosing.ahk` | Standard close cascade plus reusable custom ClassNN and client-coordinate strategies. |
| `CloseRequest.ahk` | Presence marker and request/result handshake used by `release-session` and `prepare-session`. |
| `RdpMonitoring.ahk` | WTS session notifications first; event-log polling as fallback. |
| `SingleAppMode.ahk` | Launches, activates, hardens, and closes one application. |
| `WorkspaceMode.ahk` | Loads an admin-managed manifest, launches up to five compatible Win32 apps, hosts them in tabs, and closes them concurrently. Per-app `closeCoordinates` can attempt a button close on the primary window before that app's `WinClose`, `SC_CLOSE`, `WM_CLOSE`, and process-tree fallbacks. All app close sequences share a 10-second workspace deadline. |

## Development notes

- AppControl options use the `@` prefix so application arguments such as
  `--app` or `--private-window` pass through unchanged.
- Do not use `@close-button` and `@close-coords` together.
- Client coordinates are relative to the target window's client area; use
  `WindowSpy.exe` when configuring a custom close action.
- Workspace `closeCoordinates` are stored on the app entry in its protected
  manifest. AppControl uses a physical click only when that app is the visible
  selected tab and the point resolves to that primary window; it otherwise
  skips the click and proceeds with the coordinate-message and standard close
  fallbacks. App close sequences progress independently in parallel, under a
  shared 10-second workspace deadline.
- The browser kiosk enhancement is enabled by default for single mode.
  Workspace applications use their manifest arguments without browser
  auto-enhancement. The implementation and defaults live in `Config.ahk` and
  `WorkspaceConfig.ahk`; keep this page descriptive rather than duplicating
  the full command reference.

Run the controller tests from the repository root with:

```powershell
.\scripts\run-ahk-test.ps1 remote-app\tests\ArgumentParsingTests.ahk
.\scripts\run-ahk-test.ps1 remote-app\tests\WorkspaceModeTests.ahk
```
