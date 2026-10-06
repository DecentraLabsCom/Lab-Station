# AppControl

AppControl is the RemoteApp launcher bundled with Lab Station. It starts one
or two lab applications, keeps their windows usable, and closes them when the
RDP session ends or Lab Station requests a cooperative close.

Use this component directly when configuring an Apache Guacamole Remote App.
For station setup, diagnostics, WinRM, Wake-on-LAN, and the background service,
start with the [Lab Station README](../README.md).

## Modes

### Single application

```powershell
.\remote-app\AppControl.exe "Chrome_WidgetWin_1" "C:\Program Files\Google\Chrome\Application\chrome.exe"
```

The first argument is the target window class and the second is the executable
or command. Single mode automatically adds the configured kiosk/private flags
for Chrome, Edge, or Firefox unless they are already present.

### Dual application

```powershell
.\remote-app\AppControl.exe @dual "CameraClass" "C:\LabApps\camera.exe" "ViewerClass" "C:\LabApps\viewer.exe" @tab1="Camera" @tab2="Viewer"
```

Both applications appear in a tabbed container and share the same session
lifecycle. Browser kiosk enhancement is disabled in dual mode.

## Options

| Option | Meaning |
| --- | --- |
| `@dual` | Use the two-application tabbed container. Requires four positional values: class, command, class, command. |
| `@tab1="Title"`, `@tab2="Title"` | Set tab titles in dual mode. |
| `@close-button="ClassNN"` | Use a Win32 control for a custom graceful close in single mode. |
| `@close-coords="X,Y"` | Click client-area coordinates for a custom close in single mode. |
| `@test` | Launch normally and exercise the custom close method after five seconds. |
| `@dump-args="path"` | Write the received argument list for Guacamole quoting diagnostics. |

`@close-button` and `@close-coords` are mutually exclusive. Application
parameters do not need the `@` prefix and are passed through to the launched
application.

## Configuration defaults

Source defaults are in `remote-app\lib\Config.ahk`:

| Setting | Default | Effect |
| --- | ---: | --- |
| `POLL_INTERVAL_MS` | `5000` | Event-log polling fallback interval. |
| `STARTUP_TIMEOUT` | `20` seconds | Maximum wait for an application window. |
| `ACTIVATION_RETRIES` | `3` | Window activation retries. |
| `AUTO_BROWSER_KIOSK` | `true` | Adds browser kiosk/private flags in single mode. |
| `VERBOSE_LOGGING` | `false` | Adds detailed polling entries to the log. |
| `SILENT_ERRORS` | `true` | Logs errors without opening error dialogs. |

RDP session events use WTS notifications first and event IDs `23`, `24`, `39`,
and `40` as the polling fallback. Change these defaults only when the target
lab application or Windows image requires it.

## Guacamole configuration

For a single Remote App connection:

- **Program:** `C:\LabStation\remote-app\AppControl.exe`
- **Parameters:**
  `Chrome_WidgetWin_1 "C:\Program Files\Google\Chrome\Application\chrome.exe" --app=http://lab.example`

For dual mode, put `@dual` first in the parameters followed by the two
class/command pairs. Guacamole passes parameters directly, so use normal
double quotes around Windows paths. The backslash-escaped form shown in
`AppControl.ahk` is for CMD/PowerShell command lines, not for the Guacamole
form field.

The launcher is normally at `remote-app\AppControl.exe` in a release package.
When running from source, invoke `remote-app\AppControl.ahk` with AutoHotkey v2.
The companion [Windows configuration guide](windows-configuration.md) explains
the RemoteApp policy required by the station.

## Troubleshooting

- Use `WindowSpy.exe` to find the window class, ClassNN control, and client
  coordinates.
- Check `remote-app\AppControl.log` when using the compiled launcher. Source
  and test runs write the log beside the active script/test harness.
- Use `@dump-args` to verify how a Gateway or Guacamole connection split its
  arguments.
- AppControl exposes a cooperative close marker under
  `labstation\data\controller-presence.txt`; Lab Station uses that marker
  before falling back to a failed cleanup result.

The module-level source reference is in [`lib/README.md`](lib/README.md).
