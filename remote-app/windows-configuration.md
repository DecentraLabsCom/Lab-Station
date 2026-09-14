# Windows Configuration

This explains how to enable launching a lab desktop app in kiosk mode, so that Guacamole can better run it using the Remote App option (see the Lab Gateway documentation for more details on this).

The recommended method is to run `LabStation.exe remoteapp` as Administrator.
If the registry must be configured manually, use `reg.exe` (also from an
elevated PowerShell or Command Prompt):

```powershell
reg.exe ADD "HKLM\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services" /v fAllowUnlistedRemotePrograms /t REG_DWORD /d 1 /f
reg.exe QUERY "HKLM\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services" /v fAllowUnlistedRemotePrograms
```

Or, through the UI, open Registry Editor as Administrator, navigate to
`HKEY_LOCAL_MACHINE\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services`,
create or edit the `fAllowUnlistedRemotePrograms` DWORD (32-bit) value, set it
to `1`, and restart the Remote Desktop service if the change is not picked up.
