# Testing `LabStation.exe power` (shutdown/hibernate)

This document outlines how to verify the new shutdown/hibernate commands controlled by Lab Station, both manually via CLI and through the command queue and telemetry.

## 1. Prerequisites

- Windows host with NIC drivers configured for Wake-on-LAN (confirmed via `LabStation.exe wol`).
- Lab Station service installed or the binary executed manually from `C:\LabStation`.
- Administrative account to invoke the commands.

## 2. Quick CLI validation

1. **Update base diagnostics**
   ```powershell
   .\LabStation.exe status-json
   Get-Content .\labstation\data\status.json | ConvertFrom-Json | Select-Object -ExpandProperty operations | Select-Object lastPowerAction
   ```
   - Ensure `operations.lastPowerAction` is empty or contains the last known record.

2. **Schedule controlled shutdown**
   ```powershell
   .\LabStation.exe power shutdown --delay=60 --reason="Reservation completed"
   ```
   - The log (`labstation.log`) should include: `Power action requested: mode=shutdown, delay=60, ...` followed by `Schedule shutdown`.
   - `service-state.ini` adds a `[power-action]` section with `mode=shutdown`, `delay=60`, `wakeReady=1` (if WoL is compliant), and the UTC `timestamp`.

3. **Validate telemetry before shutdown**
   - Open `labstation/data/telemetry/heartbeat.json` and confirm:
     ```json
     "operations": {
       "lastPowerAction": {
         "timestamp": "2025-11-21T17:32:05Z",
         "mode": "shutdown",
         "wakeReady": true,
         "reason": "Reservation completed"
       }
     }
     ```
   - If `wakeReady=false`, inspect `wakeIssues` to determine which NIC or pattern must be corrected.

4. **Confirm WoL after shutdown**
   - Once the host powers off, send a WoL packet from the backend and verify it returns online. This proves the command left the NIC powered.

## 3. Queue-driven test (`data/commands/inbox`)

1. Create `labstation/data/commands/inbox/power-test.ini`:
   ```ini
   [Command]
   id=power-shutdown-demo
   name=power-shutdown
   delay=45
   reason=Remote shutdown
   force=yes
   ```
2. Wait for the service to process the file (max 60s). Review `data/commands/results/power-shutdown-demo.json`:
   ```json
   {
     "command": "power-shutdown",
     "success": true,
     "message": "Shutdown scheduled",
     "options": {
       "delay": 45,
       "force": true
     }
   }
   ```
3. Confirm `service-state.ini` and `telemetry/heartbeat.json` update just like the CLI test.

## 4. Validate hibernate

- Swap the subcommand for `power hibernate`, e.g.:
  ```powershell
  .\LabStation.exe power hibernate --delay=30 --reason="Night window"
  ```
- Confirm the host enters S4 and that WoL wakes it successfully. The `delay` is applied via `timeout`, so telemetry remains idle until the command executes.

## 5. Alerts and failures

| Indicator | Suggested action |
| --- | --- |
| `wakeReady=false` with a non-empty `wakeIssues` list | Run `LabStation.exe wol`, check `wake.nicPower`, and rerun the power command. |
| `success=false` result in the queue | Read `labstation.log` and the `message` property in the result to determine the `shutdown`/`hibernate` exit code. |
| `lastPowerAction` missing from heartbeat after ordering shutdown | Make sure the service was running; if the command was manual (CLI without the service loop), start the service with `LabStation.exe service start` or run `status-json` to refresh the heartbeat. |

This covers the entire flow: command → WoL validation → scheduling shutdown/hibernate → telemetry feeding dashboards → WoL verification after power-off.
