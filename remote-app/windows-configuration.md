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
