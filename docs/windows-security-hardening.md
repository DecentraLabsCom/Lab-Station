# Windows station security hardening

This guide describes the Windows controls configured by the Lab Station setup
wizard for a station accessed through Lab Gateway and Guacamole RemoteApp.

## Gateway firewall scopes

The setup wizard requires two separate source lists before it continues:

| Traffic | Destination on the station | Source to enter |
| --- | --- | --- |
| Guacamole RemoteApp | RDP over TCP `3389` | The address or CIDR that the station sees for Guacamole/`guacd` connections. This may be a Gateway or Docker host address after routing or NAT; it is not the browser user's public address. |
| Lab Gateway operations | WinRM over HTTPS/TCP `5986` | The address or CIDR that the station sees for the Gateway operations worker. |

Enter comma-separated IPv4 or IPv6 addresses and CIDR prefixes. The wizard
rejects an empty list, `Any`, and a `/0` prefix. Use the source as observed at
the station, including any address translation between Gateway and station.
If the route or Gateway address changes, run the setup wizard again and update
the values.

Lab Station enables Windows Firewall on Domain, Private, and Public profiles,
sets inbound traffic to Block by default, disables matching generic RDP and
WinRM allow rules, creates service-specific allow rules for the configured
source lists, and blocks WinRM over HTTP/TCP `5985`. The station's status report
checks that those active rules still match the stored addresses. A firewall
policy managed by Group Policy can
prevent local changes; setup reports failure in that case, and the conflicting
policy must be corrected by the Windows administrator.

The source lists are stored as non-secret values under
`HKLM\SOFTWARE\DecentraLabs\Lab Station\NetworkAccess`.

## LABUSER autologon

The dedicated `server` profile stores the autologon credential as the Windows
LSA private secret named `DefaultPassword`, using `LsaStorePrivateData`. The
Winlogon registry key keeps the username and computer name but does not keep a
`DefaultPassword` value. If storing or verifying the secret fails, Lab Station
leaves AutoAdminLogon disabled and removes the partial secret and plaintext
value. Microsoft notes that a plaintext `DefaultPassword` registry value can
be read by users with registry access in its [automatic logon guidance](https://learn.microsoft.com/en-us/troubleshoot/windows-server/user-profiles-and-logon/turn-on-automatic-logon).
Lab Station uses the Windows
[LsaStorePrivateData API](https://learn.microsoft.com/en-us/windows/win32/api/ntsecapi/nf-ntsecapi-lsastoreprivatedata)
for that secret name; this is the autologon secret mechanism used by Windows.

This is the Windows secret store used for this autologon flow. Local
administrators and the operating system retain administrative access to the
machine; the setting is not intended to protect a station from a local
administrator.

## Dedicated-profile RemoteApp restrictions

The dedicated `server` profile writes these settings to the `LABUSER` user
profile only:

- Hide Run, Control Panel, and drive letters in Explorer.
- Disable Task Manager and Registry Editor through the user's Windows policy.
- Add CMD, Windows PowerShell, PowerShell ISE, PowerShell 7, Windows Terminal,
  `reg.exe`, MMC, Task Manager, and `taskkill.exe` to Explorer's `DisallowRun`
  list.

These Explorer policies reduce accidental access when a desktop surface is
shown. Microsoft's
[application policy documentation](https://learn.microsoft.com/en-us/windows/client-management/mdm/policy-csp-admx-shellcommandpromptregedittools)
describes the limits of these Explorer restrictions. `DisallowRun` is enforced
when Explorer launches a listed executable; it
does not prevent other launch paths and is not an application-control boundary.
Hiding drive letters does not replace NTFS permissions. Use AppLocker for
stronger per-user application control or evaluate App Control for Windows
(WDAC) when a machine-wide policy is appropriate. See Microsoft's [App Control
and AppLocker overview](https://learn.microsoft.com/en-us/windows/security/application-security/application-control/windows-defender-application-control/wdac-and-applocker-overview).
Those policies need separate planning and validation for the Windows edition
and the applications installed on the station.

Lab Station does not disable CMD globally because AppControl uses `cmd.exe`
for process cleanup. The hybrid profile leaves these LABUSER shell policies
unchanged because it shares the workstation with local users.

The Guacamole RemoteApp connection should continue to launch the configured
AppControl entry. The Windows RemoteApp policy
`fAllowUnlistedRemotePrograms=1` remains required for that launcher; Guacamole's
connection configuration determines which RemoteApp command is started.

## Guacamole file transfer and local file permissions

DecentraLabs RDP connections use Guacamole's `enable-drive` option to provide
the user with file upload and download. Guacamole exposes this as a virtual RDP
drive, typically through the `\\tsclient\<drive-name>` network location. Its
`drive-path` is a directory in the filesystem visible to `guacd`, not a
directory on the Windows station. Keep that path limited to the intended
transfer area and review its host-side permissions. See the [Guacamole RDP
connection parameters](https://guacamole.apache.org/doc/gug/configuring-guacamole.html).

This transfer drive is the intended route between the browser and the station;
it does not confine desktop applications to that location. The
`NoDrives` and `NoViewOnDrive` values above affect Explorer-style views of
lettered drives. They do not set file-system permissions for applications.
Verify that the `\\tsclient\<drive-name>` share remains visible and usable in
the deployed RemoteApp session, because its presentation can depend on the RDP
connection and Windows configuration.

Do not deny write access across an entire volume or the `LABUSER` profile.
Windows applications use per-user application-data and temporary directories;
installed applications may also need specific working or configuration folders.
Keep Windows' default ACLs and leave the required user-specific app-state and
temporary folders writable. Inventory any additional paths used by the deployed
applications. Scope restrictions to lab-data directories intended to be
read-only, and grant `LABUSER` write or delete rights only in the identified
working/output folders. The current Lab Station setup does not enforce exclusive
writes through the Guacamole drive.
