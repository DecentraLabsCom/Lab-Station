# AppControl

AppControl is the RemoteApp launcher bundled with Lab Station. It starts one
lab application or a manifest-configured workspace of two to five applications,
keeps their windows usable, and closes them when the RDP session ends or Lab
Station requests a cooperative close.

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

### Workspace of multiple applications

```powershell
.\remote-app\AppControl.exe @workspace=lab-control-room
```

The workspace opens two to five applications in tabs and closes them together
with the RemoteApp session. `@workspace` selects an administrator-managed JSON
manifest under `%ProgramData%\DecentraLabs\Lab Station\RemoteApp\workspaces`.
Run `LabStation.exe remoteapp` or the station setup wizard as an administrator
to create and protect that directory. `LABUSER` can read the manifests but
cannot change them.

Administrators can create and edit these manifests from **Lab Station →
Connectors → Remote App → Workspace editor**. The editor creates the JSON
structure, checks the application paths and parameters, and saves into the
protected folder. It runs only in an elevated Lab Station session. In most
cases, leave window matching on **Automatic**; use the advanced class or title
filter only when an application opens multiple top-level windows.

**Launch / test** saves the current editor contents and starts a local workspace
test. The test host has a normal title bar; close its window to stop all test
applications and return to the editor. The regular RemoteApp workspace remains
borderless.

Example `lab-control-room.json`:

```json
{
  "schemaVersion": 1,
  "workspaceId": "lab-control-room",
  "apps": [
    {
      "id": "instrument",
      "title": "Instrument",
      "executable": "C:\\LabApps\\Instrument\\Instrument.exe",
      "arguments": [],
      "workingDirectory": "C:\\LabApps\\Instrument",
      "windowClass": "InstrumentMainWindow",
      "startupTimeoutSeconds": 60
    },
    {
      "id": "viewer",
      "title": "Results",
      "executable": "C:\\LabApps\\ResultsViewer.exe",
      "windowClass": "ResultsViewerWindow",
      "windowTitleContains": "Results"
    }
  ]
}
```

Each application must create a visible top-level window in the launched process
before its startup timeout. AppControl selects the main window automatically
when there is one candidate. If startup creates multiple top-level windows,
set `windowTitleContains` or `windowClass` to select the main one. Executables
and working directories must exist. Use trusted,
administrator-managed application directories. The workspace host supports
regular Win32 desktop windows; UWP windows are rejected. Applications with
incompatible DPI-awareness settings or windows that cannot be re-parented fail
startup and AppControl closes the applications it already launched.

## Options

| Option | Meaning |
| --- | --- |
| `@workspace=<id>` | Open a protected manifest with two to five applications in tabs. |
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

For workspace mode, set **Parameters** to `@workspace=lab-control-room` using
the manifest ID. The single-application parameter form above is unchanged.
Guacamole passes parameters directly, so use normal double quotes around
Windows paths. The backslash-escaped form shown in `AppControl.ahk` is for
CMD/PowerShell command lines, not for the Guacamole form field. The removed
`@dual` option is no longer supported.

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
