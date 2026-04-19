# Lab Station ↔ Lab Gateway WinRM Command Contract

## 1. Purpose and scope
- Establish a minimal, script-friendly surface so Lab Gateway can orchestrate Lab Station hosts without deploying another agent.
- Cover the commands required for a single reservation lifecycle: `session guard`, `prepare-session`, `release-session`, `status-json`, and the safeguard `recovery reboot-if-needed` fallback when the host refuses to clean up.
- Document connectivity profile, credentials, command arguments, exit codes, and example payloads so both teams can automate confidently.
- **ops-worker implementation**: Lab Gateway includes `ops-worker` (Python/Flask) that wraps these WinRM commands as REST APIs (`/api/wol`, `/api/winrm`, `/api/heartbeat/poll`).

## 2. Connectivity profile
| Item | Value |
| --- | --- |
| Transport | WinRM over HTTP (`http://<hostname>:5985/wsman`) inside the lab VLAN. HTTPS upgrade planned once certificates are available. |
| Listener config | `Enable-PSRemoting -Force` plus `Set-Item WSMan:\localhost\Service\AllowUnencrypted $true` during pilot. Firewall rule `WINRM-HTTP-In-TCP` must stay enabled. |
| Client trust | Each Lab Gateway node must add the workstation to `TrustedHosts` (`Set-Item WSMan:\localhost\Client\TrustedHosts`). Limit list to managed hosts. |
| Rate limits | Default WinRM quotas (150 concurrent operations) are sufficient; stick to a max of 2 parallel commands per host. |
| Logging | All Lab Station actions continue to log to `C:\LabStation\labstation.log`; WinRM transcripts stay on the gateway. |

## 3. Credentials and authorization
- Use a dedicated local administrator, e.g., `LABSTATION\LabGatewaySvc`, whose password is stored in the Lab Gateway secret store.
- The account must be a member of `Administrators` because Lab Station touches HKLM and scheduled tasks.
- Disable interactive logon for this account (`SeDenyInteractiveLogonRight`) so it is only used via WinRM.
- Rotate the password at least every 90 days and update the Lab Gateway secret simultaneously.

## 4. Command contract
All remote executions call the bundled binary: `C:\LabStation\LabStation.exe <command> [options]`.

### Exit codes (applies to every command)
| Code | Meaning | Typical remediation |
| --- | --- | --- |
| `0` | Success. Logs contain only informational entries. | None. |
| `1` | Completed with warnings (handled condition, e.g., profile folder missing). | Inspect `labstation.log`, decide if retry is needed. |
| `>=2` | Hard failure (command not run, privileges missing, PowerShell error). | Alert + manual investigation. |

**Telemetry contract:** `status-json` and the `heartbeat.json` produced by the service include `schemaVersion` (current: **1.0.0**). Treat major bumps as breaking; fail fast or warn if `schemaVersion` is higher than the backend understands.

### Command surface
| Command | Arguments | What it does | Artifacts |
| --- | --- | --- | --- |
| `session guard` | `--grace=<seconds>`, `--user=<LABUSER>` (default), `--message="text"`, `--silent` | Detects local/console users, notifies them, waits the grace period, and forces logoff so remote reservations can take over. | `labstation.log` entries, audit line in `data/telemetry/session-guard-events.jsonl`, plus warnings surfaced via `status.json` (`localSessionActive`, `lastForcedLogoff`). |
| `prepare-session` | `--user=<LABUSER>` (optional), `--guard-grace=<seconds>` (default 90), `--no-guard` to skip eviction, `--guard-message="text"` | Invokes `session guard` automatically (unless disabled), closes controller processes, purges LABUSER temp/cache folders, resets controller log. Run immediately before a reservation is assigned. | Cleans directories inside the selected profile, emits audit entries if someone is expelled, and logs to `labstation.log`. |
| `release-session` | Same switches as `prepare-session`. `--reboot` triggers `shutdown /r /t <timeout> /f`. | Closes controller, logs off LABUSER, optionally schedules reboot. Run after reservation completes. | Forces logoff, optional reboot. |
| `recovery reboot-if-needed` | `--force` bypasses health heuristics, `--timeout=<seconds>` overrides default 20s, `--reason=<text>` tags the order. | Evaluates `status.json` issues (RemoteApp/WoL/autostart/policy drift, lingering sessions) and only triggers a forced reboot when needed; `--force` handles manual overrides. | Writes a safeguard entry to `service-state.ini`, updates `telemetry/heartbeat.json`, and schedules `shutdown /r`. |
| `power shutdown` / `power hibernate` | `--delay=<seconds>` (default 0), `--reason=<text>`, `--no-force`, `--skip-wake-check`, `--repair-wake=no`, `--require-wake`. | Re-validates Wake-on-LAN compliance (optionally reapplying adapter settings) and schedules a graceful shutdown or hibernate so the host can be powered off between reservations without breaking WoL. | Records `lastPowerAction` inside `service-state.ini`/telemetry and logs result to `labstation.log`. |
| `status-json` | `status-json <absolute-path>` | Refreshes diagnostics (RemoteApp, WoL, autostart, account/lockdown, sessions) and writes JSON to the provided path. | JSON file including `localSessionActive`, `localModeEnabled`, `lastForcedLogoff`, and the `operations` block; stdout carries the summary text. |
| `service start|stop|status|install|uninstall` | subcommand only | Manages the Lab Station background scheduled task when automation needs it (rare). | Task Scheduler entry `LabStationService`. |

> Note: `release-session --reboot --reboot-timeout=15` remains the default end-of-reservation reboot. Use `recovery reboot-if-needed` only when the host is stuck in a degraded state or the backend wants a one-off safeguard reboot.

## 5. Recommended WinRM invocation patterns
### PowerShell (Lab Gateway)
```powershell
function Invoke-LabStationCommand {
    param(
        [string]$ComputerName,
        [pscredential]$Credential,
        [string]$Command,
        [string[]]$Arguments = @()
    )

    $exe = "C:\\LabStation\\LabStation.exe"
    $argLine = @($Command) + $Arguments

    Invoke-Command -ComputerName $ComputerName -Credential $Credential -ScriptBlock {
        param($Exe, $ArgLine)
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $Exe
        $psi.ArgumentList.AddRange($ArgLine)
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.CreateNoWindow = $true
        $psi.UseShellExecute = $false

        $process = New-Object System.Diagnostics.Process
        $process.StartInfo = $psi
        $null = $process.Start()
        $stdout = $process.StandardOutput.ReadToEnd()
        $stderr = $process.StandardError.ReadToEnd()
        $process.WaitForExit()

        [pscustomobject]@{
            ExitCode = $process.ExitCode
            StdOut   = $stdout.Trim()
            StdErr   = $stderr.Trim()
        }
    } -ArgumentList @($Exe, $argLine)
}

# Example: prepare session for LABUSER before reservation
test = Invoke-LabStationCommand -ComputerName "LAB-WS-07" -Credential $cred -Command "prepare-session" -Arguments "--user=LABUSER"
if ($test.ExitCode -ne 0) { throw "Prepare-session failed: $($test.StdErr)" }
```

### pywinrm example
```python
import json
import winrm

session = winrm.Session(
    'http://lab-ws-07:5985/wsman',
    auth=('LABSTATION\\LabGatewaySvc', '***'),
    transport='ntlm'
)

ps = r'''
$exe = 'C:\LabStation\LabStation.exe'
$psi = New-Object Diagnostics.ProcessStartInfo
$psi.FileName = $exe
$psi.ArgumentList.Add('status-json', 'C:\LabStation\data\status.json')
$psi.RedirectStandardOutput = $true
$psi.RedirectStandardError = $true
$psi.UseShellExecute = $false
$psi.CreateNoWindow = $true
$proc = [Diagnostics.Process]::Start($psi)
$stdout = $proc.StandardOutput.ReadToEnd()
$stderr = $proc.StandardError.ReadToEnd()
$proc.WaitForExit()
Get-Content -Raw 'C:\LabStation\data\status.json'
exit $proc.ExitCode
'''

result = session.run_ps(ps)
print('Exit:', result.status_code)
status = json.loads(result.std_out)
print(status['summary']['state'])
```

## 6. Operational flow per reservation
1. **Wake host** (WoL handled elsewhere) and wait for WinRM to respond.
2. **`prepare-session`** to ensure LABUSER is clean. This automatically runs `session guard` (unless you pass `--no-guard`) to evict local users before cleaning; abort if exit code >=2.
3. **Assign reservation** via Guacamole/RemoteApp.
4. **`release-session --reboot`** when Lab Gateway marks reservation complete. Reboot timeout default 15 seconds so the next wake cycle starts from a clean slate.
5. **Optional:** `power shutdown --delay=60 --reason="Reservation completed"` (or `power hibernate`) if the host must remain fully off until WoL wakes it up again.
6. **`status-json`** every 5 minutes (or on demand) to copy health data back to the gateway for dashboards; alternatively poll `C:\LabStation\data\telemetry\heartbeat.json` if SMB access is already available.

## 7. Open items / future enhancements
- **HTTPS listener + cert pinning:** still pending; during pilot stay on HTTP with TrustedHosts constrained to managed hosts and keep firewall scopes tight. Plan: document `New-SelfSignedCertificate` + listener binding once CA strategy is chosen.
- **`status-json --stdout`:** not yet implemented. Current workaround: write to a temp path via `status-json <path>` and fetch the file in the same WinRM session.
- **Proactive alerts:** notifications on `ready=false` or stale heartbeat remain roadmap items; rely on ops-worker polling + dashboards until built-in alerts land.
- **Completed**: ops-worker REST API simplifies integration vs raw WinRM (see `ops-worker/README.md`).
