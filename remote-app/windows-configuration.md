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
AppControl closes the managed applications, publishes a reservation-bound
completion record, and logs off its own disconnected RDP desktop. If application
close, the initial result write, or the logoff request fails, AppControl keeps
the desktop and makes one retry 25 seconds after the first attempt began
(normally about 145 seconds after disconnect). If that also fails, the desktop
remains for the Gateway's `release-session` retry after 180 seconds. If Windows
accepts the logoff request but the final success record cannot be written,
Gateway still performs that retry and the desktop may already be closing.
Windows' disconnected-session hard limit is 240 seconds (`240000` milliseconds),
leaving time for the Gateway retry before Windows terminates the session as a
final fallback.

The wizard first uses Windows' `Win32_TSSessionSetting.TimeLimit` interface and
reads the effective `DisconnectedSessionLimit` back to confirm the result. If
that method does not apply the value and Group Policy is not already controlling
it, Setup writes the local `MaxDisconnectionTime` policy value and verifies the
effective setting again. If a Group Policy already controls a different value,
Setup leaves it unchanged and stops. Have the policy administrator set
`MaxDisconnectionTime` to `240000` ms in the controlling policy, then run Setup
again. The standard policy editor's list may not include a four-minute choice,
so a centrally managed policy may need an exact registry policy value instead.
Microsoft documents the effective limit in milliseconds in the
[`Win32_TSSessionSetting` reference](https://learn.microsoft.com/en-us/windows/win32/termserv/win32-tssessionsetting)
and the policy registry path and units in its
[RDS session-timeout troubleshooting guide](https://learn.microsoft.com/en-us/troubleshoot/windows-server/remote/troubleshoot-unexpected-rds-session-locks-or-disconnections).

Run `LabStation.exe status-json` to inspect `policy.rdpDisconnectedSession`;
`limitMs` is a JSON number, including when Windows reports `0` for unlimited,
and `ready` is true only when Windows reports exactly `240000` ms. The report
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
