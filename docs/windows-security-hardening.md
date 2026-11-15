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

## AutoAdminLogon remains disabled

Neither the `dedicated` profile nor the shared `hybrid` profile enables
automatic sign-in. Account setup explicitly disables AutoAdminLogon and removes
both the Winlogon `DefaultPassword` value and the `DefaultPassword` LSA secret,
including credentials left by an older installation. Diagnostics report a
station issue if automatic sign-in or either stored credential remains.

LABUSER is still available for Gateway-managed RDP sessions; it is not signed
into the physical console automatically.

## Dedicated-profile RemoteApp restrictions

The `dedicated` profile writes these settings to the `LABUSER` user
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

## Switching from dedicated to hybrid

The dedicated profile also assigns `SeDenyInteractiveLogonRight` to the SID of
each local account except LABUSER and built-in exemptions. When the setup
wizard switches to hybrid, it removes explicit denial entries for current local
account SIDs so local users can sign in at the console. The policy does not
record which account entries came from the dedicated profile, so this also
removes a separately configured denial for one of those local accounts. It
preserves group and unrecognized entries, LABUSER, and the Lab Gateway WinRM
account (identified by its configured name or its Lab Station description), so
an existing interactive-logon denial on the WinRM account remains in place.

The policy update must succeed before the wizard saves the hybrid profile. If
the update fails, the profile is left unchanged; if saving the profile fails,
the wizard rolls the profile back and reapplies the dedicated account denials
when the previous profile was dedicated.
Selecting hybrid again also runs this cleanup, which repairs stations where an
older setup saved `hybrid` before clearing the dedicated account denials.

This cleanup only removes entries for known local account SIDs. A remaining
group denial can still prevent a user who belongs to that group from signing in;
Windows applies a deny right even when an allow right also applies. Review
machine or domain policy if a local user account remains blocked. See
Microsoft's [Deny log on locally policy](https://learn.microsoft.com/en-us/windows/security/threat-protection/security-policy-settings/deny-log-on-locally).

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
