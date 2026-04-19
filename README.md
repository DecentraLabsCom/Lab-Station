---
description: Windows Lab Station assistant (RemoteApp, WOL, diagnostics) with bundled lab app controller.
---

# Lab Station

[![Tests](https://github.com/DecentraLabsCom/Lab-App-Control/actions/workflows/tests.yml/badge.svg)](https://github.com/DecentraLabsCom/Lab-App-Control/actions/workflows/tests.yml)
[![Security Scan](https://github.com/DecentraLabsCom/Lab-App-Control/actions/workflows/codeql.yml/badge.svg)](https://github.com/DecentraLabsCom/Lab-App-Control/actions/workflows/codeql.yml)
[![Release](https://github.com/DecentraLabsCom/Lab-App-Control/actions/workflows/release.yml/badge.svg)](https://github.com/DecentraLabsCom/Lab-App-Control/actions/workflows/release.yml)

The project is split into two first-class components:

- **Lab Station** (`labstation/`): Windows hardening assistant that configures RemoteApp policies, Wake-on-LAN, autostart, diagnostics export, tray UI, and a background monitoring service.
- **AppControl** (`controller/`): The single-instance AutoHotkey controller that launches lab apps, keeps them foregrounded, and closes them automatically on session changes.

Lab Station is the default entrypoint and bundles AppControl. Use AppControl directly only when you need the raw controller.

>
> **Lab Station Quick Start:**
> ```powershell
> # Run the interactive wizard (admin)
> .\labstation\LabStation.ahk setup
>
> # Fire individual tasks
> .\labstation\LabStation.ahk remoteapp
> .\labstation\LabStation.ahk wol
> .\labstation\LabStation.ahk autostart "C:\Tools\AppControl.exe"
> .\labstation\LabStation.ahk status-json "C:\Logs\labstation-status.json"
> .\labstation\LabStation.ahk tray
> .\labstation\LabStation.ahk service install
> .\labstation\LabStation.ahk service start
> ````
>
> **AppControl at a glance:**
> ```text
> Single mode:
>   AppControl.exe "Chrome_WidgetWin_1" "C:\Program Files\Google\Chrome\Application\chrome.exe"
> Dual mode:
>   AppControl.exe @dual "Class1" "app1.exe" "Class2" "app2.exe" @tab1="Camera" @tab2="Viewer"
> Custom close / test:
>   AppControl.exe "LVWindow" "myVI.exe" @close-coords="330,484" @test
> ```

***

### 🚀 Lab Station highlights

- **Guided setup wizard**: Applies RemoteApp policy (`fAllowUnlistedRemotePrograms`), Wake-on-LAN tweaks, autostart entries, and verifies admin privileges.
- **One-off commands**: Run `remoteapp`, `wol`, `autostart`, `launch-app-control`, or `diagnostics` individually from the CLI without stepping through the wizard.
- **Diagnostics export**: `status`/`status-json` produce both a human summary and a JSON blob (`labstation/data/status.json`) with RemoteApp/WoL/autostart health, NIC power compliance (`wake.nicPower`), power-plan timeouts (`power.sleep`/`power.hibernate`), plus hybrid fields (`localSessionActive`, `localModeEnabled`, `lastForcedLogoff`).
- **Tray UI**: Optional background tray icon showing live status, shortcuts to logs, wizard, and manual export.
- **Background service**: `service install|start|stop|status` provisions a Windows Scheduled Task that keeps diagnostics fresh even when nobody is logged on.
- **Continuous telemetry**: The service now publishes a heartbeat at `labstation/data/telemetry/heartbeat.json` containing RemoteApp/WoL/autostart checks plus the timestamp of the latest cleanups so Lab Gateway can poll without a live WinRM hop.
- **Controlled power-down**: `power shutdown|hibernate` re-checks NIC/WoL readiness (and can reapply settings) before scheduling the OS power action, recording the order in `service-state.ini` and telemetry for auditing.
- **Logging & data dir**: All operations log to `labstation/labstation.log` and persist data to `labstation/data/`.

### 🕹️ AppControl highlights

- **Single & dual modes**: Launch one app or embed two apps inside a tabbed container with custom tab titles.
- **Session-aware lifecycle**: Uses WTS session notifications first, with event-log polling fallback, to close apps on disconnect/logoff.
- **Command-line flexibility**: Accepts plain executable paths or full commands with arguments, automatically adding kiosk flags for major browsers.
- **Custom close automation**: Supports ClassNN-based buttons, client coordinates, and a `@test` mode to validate custom close routines.
- **Window hardening**: Maximizes, foregrounds, strips minimize/close controls, and retries activation to guard against Groupy/overlay quirks.
- **Verbose logging**: Emits actionable telemetry (`controller/tests/AppControl.log` or alongside the EXE) for smoke tests and production troubleshooting.

### 🧰 Lab Station CLI reference

| Command | Description |
| --- | --- |
| `setup` | Guided wizard that chains RemoteApp policy, Wake-on-LAN tweaks, autostart registration, diagnostics export, and service prompt. |
| `remoteapp` | Sets `fAllowUnlistedRemotePrograms` and related HKLM keys for RemoteApp. |
| `wol` | Configures adapters and power plan settings required for Wake-on-LAN. |
| `autostart [path]` | Registers AppControl (EXE or AHK) under HKLM\Run; optional custom path overrides bundle location. |
| `launch-app-control [...]` | Pass-through launcher that proxies CLI args to the bundled controller. |
| `account [create|autologon|lockdown|setup] [user] [password]` | Creates the lab account, refreshes autologon (DefaultUserName/Password), and `lockdown` now enforces `SeDenyInteractiveLogonRight` for every other local user. |
| `status` / `status-json [dest]` | Generates the latest health summary; JSON defaults to `labstation/data/status.json`. |
| `diagnostics [dest]` | Convenience alias of `status-json` for explicit exports. |
| `session guard [--grace=120] [--user=LABUSER]` | Warns local/console sessions, waits the grace period, forces logoff, and appends an audit entry to `data/telemetry/session-guard-events.jsonl`. |
| `prepare-session [--user=LABUSER] [--guard-grace=90] [--no-guard]` | Runs `session guard` automatically (unless `--no-guard`), captures expulsions, and then wipes LABUSER temps/logs so a remote reservation can start pristine. |
| `release-session [--user=LABUSER] [--reboot] [--reboot-timeout=15]` | Closes controller processes, logs off LABUSER, and optionally schedules a reboot when a reservation finishes. |
| `recovery reboot-if-needed [--force] [--timeout=20]` | Evaluates RemoteApp/WoL/autostart + policy drift and only schedules a forced reboot when the host is unhealthy (or when `--force` is passed). |
| `power shutdown [--delay=0] [--reason=text] [--no-force] [--skip-wake-check]`<br>`power hibernate [...]` | Validates WoL readiness (optionally reapplying NIC settings) and schedules a graceful shutdown or hibernate so Lab Gateway can power off hosts at the end of a reservation without breaking WoL. Véase `labstation/docs/power-control.md` para el checklist de pruebas. |
| `tray` | Starts the tray UI with shortcuts to logs, wizard, and manual exports. |
| `energy audit [--json=path]` | Collects power plan, sleep/hibernate timers, NIC wake settings, and WoL readiness; optionally exports JSON for compliance. |
| `service install|start|stop|status|uninstall` | Manages the Scheduled Task (`LabStationService`) that runs the `service-loop`. |
| `service-loop` | Internal command invoked by the service to refresh diagnostics every minute. |

> For hybrid (local + remote) classrooms see `labstation/docs/hybrid-operations.md`, which outlines the professor-facing notices and grace windows enforced by `session guard`. Complement it with `labstation/docs/gateway-ui-guidelines.md` to mirror those rules in the Lab Gateway UI. Lab Gateway can toggle `labstation/data/local-mode.flag` to mark "local-use only" windows before launching remote reservations.

#### Background command queue

When the background service is running, you can drop plain INI files into `labstation/data/commands/inbox` to let the agent execute actions without interactive WinRM sessions. Every file must contain a `[Command]` section:

```ini
[Command]
id=job-20251121-01
name=prepare-session
user=LABUSER
reboot=true
reboot-timeout=20
```

- Supported `name` values today: `prepare-session`, `release-session`, `session-guard`, `status-json`, `reboot-if-needed`.
- Optional keys: `user`, `reboot`, `reboot-timeout`, `path` (for `status-json`), guard-related switches (`guard=yes|no`, `guard-grace`, `guard-message`, `guard-notify`), plus `reason`, `force`, or `timeout` when scheduling `reboot-if-needed`.
- Power commands: enqueue `name=power-shutdown` or `name=power-hibernate` with optional `delay`, `reason`, `force=yes|no`, `skip-wake-check=yes|no`, `repair-wake=yes|no`.
- Results are written to `labstation/data/commands/results/<id>.json` together with the captured options and timestamps. Exit codes mirror the CLI: `0` success, `1` completed with warnings (prepare/release/guard reported something non-fatal), `2` hard failure (missing command, exceptions, or non-compliant power checks).
- Result payload shape:
  ```json
  {
    "id": "job-20251121-01",
    "command": "prepare-session",
    "completedAt": "2025-11-22T23:05:12Z",
    "success": true,
    "exitCode": 0,
    "message": "Prepare-session completed",
    "options": {"user": "LABUSER", "reboot": true},
    "metadata": {"name": "prepare-session", "user": "LABUSER", "reboot": "true"},
    "sourceFile": "C:\\LabStation\\labstation\\data\\commands\\inbox\\job-20251121-01.ini"
  }
  ```
- Processed instructions are archived to `labstation/data/commands/processed/` so the backend can audit what happened; results stay in `.../results/` for collection.

This queue gives Lab Gateway two integration choices: fire `LabStation.exe ...` directly over WinRM for synchronous operations, or drop a command file (via SMB/WinRM copy) and let the service pick it up asynchronously.

For hardware-specific BIOS guidance and WoL validation steps, see `labstation/docs/bios-wol-playbook.md`.

#### Telemetry drop for dashboards

The same service loop now emits `labstation/data/telemetry/heartbeat.json` every minute. The payload mirrors `status.json`, adds the `operations` block (timestamps of the latest `prepare-session`, `release-session`, safeguard reboot, and forced logoff), and lives inside a folder that the backend can poll or collect via file share. See `labstation/docs/telemetry-consumption.md` for an end-to-end ingestion blueprint. Key fields now include:

- `localSessionActive`: true when another local/console user is still connected.
- `localModeEnabled`: reflects the presence of `data/local-mode.flag` so the backend knows the lab is intentionally reserved for in-person use.
- `lastForcedLogoff`: metadata (timestamp, user, sessionId) for the most recent `session guard` eviction, sourced from `service-state.ini`.
- `lastPowerAction`: records the last shutdown/hibernate order (mode, delay, wake readiness) so dashboards can prove who powered the host down.
- `wake.nicPower`: per-adapter verdict showing `wakeOnMagicPacket`, `allowTurnOff`, and `wolReady` so NIC misconfigurations surface in dashboards.
- `power.sleepCompliant` / `power.hibernateCompliant`: boolean flags derived from `powercfg /q` (`STANDBYIDLE`/`HIBERNATEIDLE`) to prove sleep/hibernate remain disabled.
- `schemaVersion`: contract version for the JSON shape (`heartbeat.json` and `status.json` share the same schema version).

This means Lab Gateway can build dashboards or alerting off a simple file drop without invoking WinRM.

##### Session guard audit log

Every forced logoff appends a JSON line to `labstation/data/telemetry/session-guard-events.jsonl` with the expelled user, session id, grace window, and timestamp. Ship or tail this file from the backend to maintain an audit trail of who was removed before each remote reservation.

***

### 📥 Release downloads

- **`LabStation.exe`** – compiled Lab Station CLI/tray/wizard. Drop it in any folder together with `AppControl.exe` and run it directly (no AutoHotkey runtime required).
- **`AppControl.exe`** – standalone controller binary for setups that only need the RDP-aware launcher (also used by Lab Station under the hood).
- **`WindowSpy.exe`** – helper from the AutoHotkey project, included for convenience to discover window classes, controls, and coordinates.

***

### 🔧 Installation and Use

#### **Option 1: Download the executables**

1. Create a folder (e.g., `C:\LabStation`).
2. Download `LabStation.exe`, `AppControl.exe` **and** `WindowSpy.exe` from the latest release and place both files inside that folder.
3. Run Lab Station directly:

  ```powershell
  .\LabStation.exe setup
  .\LabStation.exe status-json "C:\Logs\labstation-status.json"
  .\LabStation.exe service install
  .\LabStation.exe tray
  ```

4. Lab Station will call the `AppControl.exe` that lives in the same folder whenever it needs to launch/configure the controller.

#### **Option 2: Run the scripts (AutoHotkey required)**

1. Install AutoHotkey v2.
2. Clone or download this repository (or copy the `labstation/` and `controller/` folders).
3. From that folder, run the scripts directly:

  ```powershell
  "C:\Program Files\AutoHotkey\v2\AutoHotkey.exe" labstation\LabStation.ahk setup
  "C:\Program Files\AutoHotkey\v2\AutoHotkey.exe" labstation\LabStation.ahk status

  # Controller only
  "C:\Program Files\AutoHotkey\v2\AutoHotkey.exe" controller\AppControl.ahk "Chrome_WidgetWin_1" "C:\Path\To\App.exe"
  ```

4. (Optional) Compile your own binaries with Ahk2Exe following the same steps as the release workflow.

#### **AppControl invocation examples**

1. Download `AppControl.exe` from the release assets.
2.  Run with:

  ```batch
  REM Single app - Basic usage
  AppControl.exe "YourWindowClass" "C:\Path\To\LabControl.exe"

  REM Single app - Browser (auto-kiosk)
  AppControl.exe "Chrome_WidgetWin_1" "\"C:\Program Files\Google\Chrome\Application\chrome.exe\" --app=http://127.0.0.1:8000"
  REM (Automatically adds --kiosk --incognito)

  REM Single app - With custom close button (ClassNN)
  AppControl.exe "Notepad" "C:\Windows\System32\notepad.exe" @close-button="Button2"

  REM Single app - With custom close coordinates (LabVIEW/custom apps)
  AppControl.exe "LVWindow" "C:\Path\To\myVI.exe" @close-coords="330,484"
    
  REM Dual app - Two apps in tabbed container
  AppControl.exe @dual "Class1" "C:\Path\To\app1.exe" "Class2" "C:\Path\To\app2.exe"
    
  REM Dual app - With parameters and custom tab titles
  AppControl.exe @dual "Chrome_WidgetWin_1" "\"C:\Program Files\Google\Chrome\Application\chrome.exe\" --app=http://127.0.0.1:8000" "MozillaWindowClass" "\"C:\Program Files\Mozilla Firefox\firefox.exe\" --private-window" @tab1="Web App" @tab2="Private Browser"
  ```

#### **Command-Line Options**

| Option | Description | Required | Example |
|--------|-------------|----------|---------|
| `@dual` | Enable dual app mode (tabbed container) | **Yes** (for dual mode) | `@dual` |
| `@tab1="Title"` | Custom title for first tab (dual mode only) | No | `@tab1="Camera"` |
| `@tab2="Title"` | Custom title for second tab (dual mode only) | No | `@tab2="Viewer"` |
| `@close-button="ClassNN"` | Custom close button control (single mode only) | No | `@close-button="Button2"` |
| `@close-coords="X,Y"` | Custom close coordinates in CLIENT space (single mode only) | No | `@close-coords="330,484"` |
| `@test` | Test custom close method after 5 seconds (single mode only) | No | `@test` |

**Notes:**
- Cannot use both `@close-button` and `@close-coords` at the same time
- Custom close options only apply to single application mode
- Use `@` prefix to distinguish AppControl options from application parameters

#### **Command-Line Parameter Support**

The script automatically detects whether you're providing a simple executable path or a full command with parameters.

**Simple Path (paths with spaces MUST be quoted):**
```batch
REM Path without spaces - quotes optional but recommended
AppControl.exe "Notepad" "C:\Windows\System32\notepad.exe"

REM Path WITH spaces - quotes REQUIRED
AppControl.exe "Chrome_WidgetWin_1" "C:\Program Files\Google\Chrome\Application\chrome.exe"
```

**Full Command with Parameters:**
```batch
REM CMD/Batch syntax - use backslash to escape inner quotes
AppControl.exe "Chrome_WidgetWin_1" "\"C:\Program Files\Google\Chrome\Application\chrome.exe\" --app=http://127.0.0.1:8000 --incognito"

REM Firefox with private window
AppControl.exe "MozillaWindowClass" "\"C:\Program Files\Mozilla Firefox\firefox.exe\" --private-window"
```

**Automatic Browser Kiosk Mode:**

AppControl automatically detects when you're launching a browser (Chrome, Edge, Firefox) and adds kiosk and private browsing flags **if they're not already present**. This simplifies deployment - you don't need to manually specify these flags in most cases.

**Supported Browsers:**
- **Chrome** (`chrome.exe`): Automatically adds `--kiosk --incognito`
- **Edge** (`msedge.exe`): Automatically adds `--kiosk --inprivate`
- **Firefox** (`firefox.exe`): Automatically adds `-kiosk -private-window`

**Examples:**
```batch
REM This simple command...
AppControl.exe "Chrome_WidgetWin_1" "C:\Program Files\Google\Chrome\Application\chrome.exe"

REM ...automatically becomes:
REM AppControl.exe "Chrome_WidgetWin_1" "C:\Program Files\Google\Chrome\Application\chrome.exe --kiosk --incognito"

REM If you specify custom parameters, kiosk flags are still added (unless already present):
AppControl.exe "Chrome_WidgetWin_1" "\"C:\Program Files\Google\Chrome\Application\chrome.exe\" http://127.0.0.1:8000"
REM Becomes: chrome.exe --kiosk --incognito http://127.0.0.1:8000

REM If you already have kiosk flags, they won't be duplicated:
AppControl.exe "Chrome_WidgetWin_1" "\"C:\Program Files\Google\Chrome\Application\chrome.exe\" --kiosk http://127.0.0.1:8000"
REM Stays unchanged (--kiosk already present)
```

**To disable automatic browser enhancement:**
Edit `controller\lib\Config.ahk` and set:
```ahk
global AUTO_BROWSER_KIOSK := false
```

**How it works:**
- **Detection**: The script checks if the argument contains spaces and quotes to determine if it's a full command
- **Browser Enhancement**: If enabled, browsers are detected by executable name and kiosk flags are automatically added
- **Validation**: Only the executable path is validated for existence; parameters are passed through unchanged
- **Execution**: The full command string is passed to AutoHotkey's `Run()` function
- **Compatibility**: Simple paths work exactly as before - no breaking changes

**Important Rules:**
1. **Paths with spaces MUST be quoted** - Windows will split unquoted paths at spaces
2. **Commands with parameters need inner quotes** around the executable path
3. **CMD/Batch**: Use `\"` (backslash-quote) to escape inner quotes
4. **Guacamole Remote App**: Use regular quotes, no escaping needed
   - Example: `Chrome_WidgetWin_1 "C:\Program Files\Google\Chrome\Application\chrome.exe" --app=http://127.0.0.1:8000 --incognito`

***

### ⚙️ Configuration

The script includes several configuration constants that can be modified in `controller\lib\Config.ahk`:

#### **Core Settings**

* **`POLL_INTERVAL_MS`**: Fallback monitoring interval in milliseconds (default: **5000** = 5 seconds)
* **`STARTUP_TIMEOUT`**: How long to wait for app window to appear (default: **6** seconds)
* **`ACTIVATION_RETRIES`**: Number of retries for window activation when Groupy temporarily hides window (default: **5**)
* **`CloseOnEventIds`**: RDP event IDs that trigger app closure (default: `[23, 24, 39, 40]`)
  * `23`: Logoff, `24`: Disconnect, `39`: Session disconnect, `40`: Reconnect

#### **Browser Auto-Configuration**

* **`AUTO_BROWSER_KIOSK`**: Automatically add kiosk and incognito flags to browsers (default: `true`)
* **`BROWSER_KIOSK_FLAGS`**: Map of browser executables to their default kiosk flags
  * Chrome: `--kiosk --incognito`
  * Edge: `--kiosk --inprivate`
  * Firefox: `-kiosk -private-window`

#### **Debugging & Testing**

* **`VERBOSE_LOGGING`**: Enable detailed polling logs (default: `true` for debugging, `false` for production)
* **`SILENT_ERRORS`**: Suppress error MsgBox popups - log only (default: `false`)
* **`TEST_MODE`**: Activated via command-line parameter `@test` - test custom close after 5 seconds

#### **Custom Close Methods**

The script supports three ways to close applications gracefully:

1. **Standard cascade**: `WinClose` → `WM_SYSCOMMAND` → `WM_CLOSE` → `ProcessClose`
2.  **ClassNN control**: For Win32 apps with accessible controls

    ```powershell
    AppControl.exe "Notepad" "notepad.exe" @close-button="Button2"
    ```
3.  **Client coordinates**: For LabVIEW/custom apps (use WindowSpy CLIENT coordinates)

    ```powershell
    AppControl.exe "LVWindow" "myVI.exe" @close-coords="330,484"
    ```

**Important:** Cannot use both `@close-button` and `@close-coords` at the same time.

#### **Dual Application Mode**

Run two applications side-by-side in a tabbed container window. **Requires** the `@dual` flag to be explicitly specified.

**Features:**
- 📊 **Tabbed interface**: Switch between apps with modern flat tabs
- 🎯 **Custom titles**: Name tabs meaningfully (e.g., "Camera", "Control Panel")
- 🔄 **Synchronized lifecycle**: Both apps close together when session ends
- 🪟 **Single window**: Container maximizes to full screen, apps embedded inside
- 🚫 **Protected apps**: Alt+F4 blocked on embedded applications

**Use Cases:**
- Camera control + Live viewer
- Instrument control + Data visualization
- Configuration tool + Monitoring dashboard
- Any two related lab applications

**Example:**
```batch
REM Basic dual mode (@dual flag required)
AppControl.exe @dual "CameraClass" "camera.exe" "ViewerClass" "viewer.exe"

REM With custom tab titles
AppControl.exe @dual "DobotLab" "DobotLab.exe" "MozillaWindowClass" "firefox.exe" @tab1="Robot Control" @tab2="Web Interface"
```

#### **TEST MODE Usage**

Test your custom close coordinates/controls before deployment:

```batch
REM Test coordinate-based close
AppControl.exe "LVWindow" "myVI.exe" @close-coords="330,484" @test

REM Test control-based close  
AppControl.exe "Notepad" "notepad.exe" @close-button="Button2" @test
```

When `@test` flag is used:
- ✅ App launches normally
- ⏱️ After 5 seconds, custom close method is tested
- ✅ Success: App closes gracefully (check log for confirmation)
- ❌ Failure: App remains open (check log and adjust coordinates/control)

#### **Finding Window Information**

Use the included **WindowSpy.exe** tool to identify:

* **Window Class** (`ahk_class`): Used as first parameter
* **ClassNN** controls: For control-based closing
* **CLIENT coordinates**: Most reliable for custom apps (not Screen or Window coordinates)

> **Note**: WindowSpy is a utility from the [AutoHotkey project](https://github.com/AutoHotkey/AutoHotkey). The executable is included here for convenience only.

#### **Log Files**

* Location: Same directory as script/exe (`AppControl.log`)
* Contains: Startup info, activation retries, coordinate calculations, event detection, close attempts
* Enable `VERBOSE_LOGGING` for detailed polling information

***

### 🌐 Integration with DecentraLabs

Run this script **when a user session starts** (e.g., on Guacamole/RDP connect).\
It will keep the lab app active and **will close it on the next RDP session event** (typically the disconnect at the end of the session).

#### **Recommended Setup: Guacamole + Windows Remote App**

For optimal security and user experience, use this script in combination with:

* **Apache Guacamole** for web-based remote access
* **Windows Remote App connections** to expose individual applications
* **Controlled lab environment** where users access only specific tools

This setup provides:

* ✅ **Application isolation**: Users see only the lab app, not the full desktop
* ✅ **Automatic lifecycle management**: Apps start/stop with user sessions
* ✅ **Enhanced security**: No access to underlying Windows system
* ✅ **Seamless integration**: Works transparently with Guacamole's session management

#### **Guacamole Remote App Configuration**

When configuring AppControl in Guacamole Remote App connections, use this syntax:

**Remote Application Program:**
```
C:\Path\To\AppControl.exe
```

**Remote Application Parameters (simple path):**
```
Chrome_WidgetWin_1 "C:\Program Files\Google\Chrome\Application\chrome.exe"
```

**Remote Application Parameters (with command-line arguments):**
```
Chrome_WidgetWin_1 "C:\Program Files\Google\Chrome\Application\chrome.exe" --app=http://127.0.0.1:8000 --incognito
```

**Important Notes for Guacamole:**
- ✅ **Quote paths with spaces** - use regular double quotes
- ❌ **Do NOT escape inner quotes** - Guacamole passes arguments directly without shell interpretation
- ✅ **Parameters are space-separated** - each argument naturally separated
- ✅ **Works with both single and dual mode** - use `@dual` flag as first parameter for dual mode

**Example Guacamole Configurations:**

*Single App - Chrome (auto-kiosk):*
- **Program**: `C:\LabApps\AppControl.exe`
- **Parameters**: `Chrome_WidgetWin_1 "C:\Program Files\Google\Chrome\Application\chrome.exe" --app=http://lab.example.com`
- (Automatically adds `--kiosk --incognito` in single mode)

*Dual App - Camera + Viewer:*
- **Program**: `C:\LabApps\AppControl.exe`
- **Parameters**: `@dual CameraClass "C:\LabApps\camera.exe" ViewerClass "C:\LabApps\viewer.exe" @tab1="Camera Control" @tab2="Live View"`

***

### 📦 Architecture

Lab Station is now the primary artifact and the legacy controller lives inside `controller/`:

```
Lab App Control/
├── labstation/                     # Lab Station CLI, services, diagnostics
├── controller/
│   ├── AppControl.ahk          # Controller entry point
│   ├── lib/                        # Controller modules
│   └── tests/                      # Controller-only smoke/regression tests
└── remote-app/                     # Windows RemoteApp hardening notes
```

Inside `controller/lib/` the modules remain the same:

```
controller/lib/
├── Config.ahk                  # Configuration and constants
├── Utils.ahk                   # Utility functions
├── WindowClosing.ahk           # Window closing logic
├── RdpMonitoring.ahk           # RDP event monitoring
├── SingleAppMode.ahk           # Single app implementation
├── DualAppMode.ahk             # Dual app container
└── README.md                   # Module documentation
```

See `controller/lib/README.md` for detailed module documentation.

### ✅ Smoke Tests

The `controller/tests/` folder contains a lightweight smoke test that launches **DualAppMode** with two simulated applications and verifies key log markers. Run it with AutoHotkey v2 (64-bit recommended):

```powershell
"C:\Program Files\AutoHotkey\v2\AutoHotkey64.exe" controller\tests\SmokeTest_DualAppMode.ahk
```

The harness:

- Launches two `FakeApp.ahk` instances with predictable window classes.
- Starts `CreateDualAppContainer` with those apps and waits ~8 seconds.
- Checks `controller\tests\AppControl.log` for the expected lifecycle messages.
- Returns exit code **0** on success (non-zero otherwise) so you can wire it into CI or scripted regression checks.
