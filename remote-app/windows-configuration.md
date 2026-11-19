# Windows RemoteApp configuration

This page covers the Windows policy required to launch a lab application
through an Apache Guacamole RemoteApp connection. It does not configure the
Guacamole connection itself; use the [AppControl guide](README.md) for the
Program and Parameters fields.

The recommended method is to run `LabStation.exe remoteapp` as Administrator.
The command configures the policy and related HKLM values used by the Lab
Station connector. It does not register AppControl in Windows Run or create a
global autostart entry.
If the registry must be configured manually, use `reg.exe` (also from an
elevated PowerShell or Command Prompt):

## Disconnected-session reconnection window

AppControl keeps its managed application or workspace open for 120 seconds
after an RDP disconnect; a reconnect cancels that timer. When the grace expires,
AppControl closes the managed applications and publishes a reservation-bound
completion record for the Gateway. Windows' disconnected-session hard limit is
180 seconds (`180000` milliseconds), leaving time for that orderly close to
finish before Windows can terminate the session as a fallback. The Gateway
waits for the completion record before running reservation end energy phases.

The wizard uses Windows' `Win32_TSSessionSetting.TimeLimit` interface, then
reads the effective `DisconnectedSessionLimit` back to confirm the result. If a
Group Policy controls a different value, setup leaves it unchanged and stops.
Have the policy administrator set `MaxDisconnectionTime` to `180000` ms in the
controlling policy, then run Setup again. The standard policy editor's list may
not include a two-minute choice, so a centrally managed policy may need an
exact registry policy value instead. Microsoft documents the effective limit
in milliseconds in the
[`Win32_TSSessionSetting` reference](https://learn.microsoft.com/en-us/windows/win32/termserv/win32-tssessionsetting)
and the policy registry path and units in its
[RDS session-timeout troubleshooting guide](https://learn.microsoft.com/en-us/troubleshoot/windows-server/remote/troubleshoot-unexpected-rds-session-locks-or-disconnections).

Run `LabStation.exe status-json` to inspect `policy.rdpDisconnectedSession`;
`ready` is true only when Windows reports exactly `180000` ms. The report
includes the setting source but no credentials. `reservationDisconnectClose`
contains the latest non-secret close result, bound to its reservation and
Station lease generation.

This is the disconnected-session timeout. It does not change active-session or
idle-session limits.

The Lab Station Connectors panel reports Remote App as **Available** only when
the launcher is present in `remote-app\` and this registry value is `1`. It
reports **Needs attention** when the launcher exists but the policy is missing.

```powershell
reg.exe ADD "HKLM\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services" /v fAllowUnlistedRemotePrograms /t REG_DWORD /d 1 /f
reg.exe QUERY "HKLM\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services" /v fAllowUnlistedRemotePrograms
```

The expected value is `0x1`. If Remote Desktop Services does not pick up the
policy, restart the service or reboot the station, then run
`LabStation.exe status-json` and inspect `remoteAppEnabled`. The Connectors
panel reports **Available** only when both the launcher and policy are
present; **Needs attention** means the launcher exists but the policy is
missing.

Or, through the UI, open Registry Editor as Administrator, navigate to
`HKEY_LOCAL_MACHINE\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services`,
create or edit the `fAllowUnlistedRemotePrograms` DWORD (32-bit) value, set it
to `1`, and restart the Remote Desktop service if the change is not picked up.
