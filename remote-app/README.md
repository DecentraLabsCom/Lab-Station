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
      "windowExecutable": "C:\\LabApps\\ResultsViewer\\Viewer.exe",
      "windowClass": "ResultsViewerWindow",
      "windowTitleContains": "Results"
    }
  ]
}
```

`executable` is the program AppControl launches. If that launcher starts a
different executable that owns the real application window, set
`windowExecutable` to that executable's full path. It defaults to `executable`.
AppControl waits for a visible primary window from `windowExecutable` before it
starts the workspace monitor. Startup splashes, owned popups, standard Windows
dialogs, and tool windows cannot satisfy that wait. When several main-like
windows appear, set `windowTitleContains` or `windowClass` to select the intended
one. `startupTimeoutSeconds` defaults to 60 seconds when omitted. This is a
maximum: AppControl continues as soon as the matching window appears. After the
main window attaches, its owned popups and tool windows are
tracked as auxiliary windows even when their class or title differs. They keep
their native size and owner relationship, and are shown or hidden with their
application's tab. They are not re-parented or stretched across the workspace.
If a main window starts minimized, AppControl uses its restored bounds to detect
it and restores it to the workspace size when its tab is selected.
Executables and working directories must exist. Use trusted,
administrator-managed application directories. The workspace host supports
regular Win32 desktop windows; UWP windows are rejected. Applications with
incompatible DPI-awareness settings or main windows that cannot be re-parented
fail startup and AppControl closes the applications it already launched.

### Workspace close coordinates

An app entry can optionally define `"closeCoordinates": [X, Y]` for a custom
close button on that app's primary window. For example, add
`"closeCoordinates": [394, 395]` to the first app entry if only the primary
workspace app needs a controlled close. Coordinates are specific to that app;
leave the field out of entries that should use the standard workspace close.

Capture the client-area coordinates after AppControl has embedded and resized
the application in its workspace tab, using the same RDP resolution and display
scaling as the real session. On shutdown, AppControl attempts a physical
coordinate click only when that app's tab is selected and its primary window is
visible and enabled. Otherwise it skips the physical click and sends the
coordinate `PostMessage` attempt directly to the primary window. AppControl
advances each application through `WinClose`, `SC_CLOSE`, `WM_CLOSE`, and
process-tree cleanup independently, so workspace apps close in parallel while
each keeps that fallback order. All apps share a 10-second shutdown deadline.
The coordinate attempt targets only the primary window; auxiliary windows
continue through the standard close path.

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

## Capture and test close coordinates

Capture coordinates after AppControl has prepared the application window. In
single-application mode AppControl activates the target and attempts to maximize
it, then removes its minimize button and system menu (including the window
close button). Maximization is best-effort: fixed-size dialogs or applications
that reject the maximize request can remain windowed. Removing the buttons does
not mean the window was maximized. Measuring the application before this setup
can produce different coordinates.

1. Start the application through AppControl without `@close-coords` or `@test`.
   Wait until AppControl has finished its maximize attempt and style changes and
   the application's final layout is visible.
2. Open `WindowSpy.exe` in the same interactive Windows session and hover over
   the center of the application's intended close control. In **Mouse
   Position**, record the **Client** X and Y values. Also record the target
   window's `ahk_class` value for AppControl's first argument. With the standard
   release extracted to `C:\LabStation`, Window Spy is at
   `C:\LabStation\WindowSpy.exe`, beside `LabStation.exe`.
3. Keep the application's size, RDP resolution and display scaling the same as
   the session you will test. The coordinates are relative to the target
   window's client area, not the screen. AutoHotkey v2 `Click` uses the active
   window's client area by default, and AppControl activates the target first;
   see the [CoordMode reference](https://www.autohotkey.com/docs/v2/lib/CoordMode.htm).
4. Append `@close-coords="X,Y"` to the single-application Parameters value.
   To exercise the custom close while connected, append `@test` as well:

   ```text
   InstrumentWindow "C:\LabApps\Instrument.exe" @close-coords="414,823" @test
   ```

`@test` runs the custom close attempt five seconds after launch. If the target
window closes, AppControl exits; if it stays open, AppControl logs the failed
attempt and remains active. The coordinate method first calls `Click(X,Y)`; if
the window remains, it sends mouse-button messages to that same point. Check
`remote-app\AppControl.log` for `First click may not have worked - trying
PostMessage click` to tell when that fallback ran. A successful `@test` can
therefore mean either attempt closed the window. The `@close-button` and
`@close-coords` command-line options apply only to single-application mode;
workspace coordinates are configured per app in its manifest as described
above.

`@test` checks the custom close while the session is connected; it does not
simulate an RDP disconnect. Remove it for a disconnect trial, or the five-second
timer may close the application first.

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
- **Working directory:** `C:\LabStation\remote-app`
- **Parameters:**
  `Chrome_WidgetWin_1 "C:\Program Files\Google\Chrome\Application\chrome.exe" --app=http://lab.example`

These paths assume the release ZIP was extracted to `C:\LabStation` as shown
in the [Lab Station installation guide](../README.md#install-and-operate). Use
the actual `remote-app` directory if the package was installed elsewhere.

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
