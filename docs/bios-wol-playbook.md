# BIOS & Wake-on-LAN Playbook

The goal is to guarantee that every Lab Station host can power on via Wake-on-LAN (WoL) and stay awake for the entire reservation. Follow the steps below for each supported hardware family.

## 1. Reference checklist (all models)

1. Update BIOS/UEFI to the latest vendor-approved version.
2. Enable WoL from S4/S5 (sometimes called "Wake from shutdown" or "Power On By PCI-E").
3. Force the onboard NIC as the primary wake device; disable wake on Wi-Fi.
4. Disable all automatic sleep/hibernate timers while the host is in lab mode.
5. In Windows, run `LabStation.exe wol` after BIOS changes to refresh OS-level power settings.
6. Validate with `LabStation.exe energy audit` (new command) and keep the JSON report in the compliance folder.

## 2. Dell OptiPlex / Precision (7000, 5000 series)

| BIOS Menu | Setting | Target Value |
| --- | --- | --- |
| *Power Management → Wake on LAN/WLAN* | **LAN Only** | Ensures only the wired NIC can wake the system. |
| *Power Management → Wake on LAN/WLAN → Block Sleep* | **Enabled** | Prevents Modern Standby from blocking WoL packets. |
| *Power Management → Deep Sleep Control* | **Disabled** | Keeps NIC powered while the system is off. |
| *Advanced → Integrated NIC* | **Enabled w/ PXE** | Required so the NIC stays initialized for WoL. |
| *Power Management → USB Wake Support* | **Disabled** | Avoids accidental wake events from keyboards. |

**Validation**
- Reboot, then from Windows run:
  ```powershell
  .\LabStation.exe wol
  .\LabStation.exe energy audit > C:\LabStation\logs\energy-dell-<host>.txt
  ```
- Confirm `Wake-capable devices` includes `Intel(R) Ethernet Connection I219-LM` and that the audit report flags no sleep/hibernate timers.

## 3. HP Z2/Z4 Workstations & EliteDesk 800

| BIOS Menu | Setting | Target Value |
| --- | --- | --- |
| *Advanced → Power-On Options → Wake on LAN* | **Boot to Hard Drive** | Allows WoL from S4/S5 straight into Windows. |
| *Advanced → Power-On Options → PCI Express Slot Power* | **Always On** | Keeps NIC powered. |
| *Advanced → Network (AMT) Options → AMT Power Control* | **On in S0, ME Wake in S3/4/5** | Lets AMT deliver WoL even when off. |
| *Power → Hardware Power Management → S4/S5 Maximum Power Savings* | **Disable** | Prevents NIC power loss. |
| *Security → Network Boot* | **Enabled** | Required on some revisions to keep NIC initialised. |

**Validation**
- Boot to Windows, open PowerShell as admin:
  ```powershell
  Get-NetAdapterPowerManagement -Name "Intel*" | Format-List
  .\LabStation.exe energy audit
  ```
- Review audit recommendations; all HP adapters should show `WakeOnMagicPacket = Enabled` and `AllowComputerToTurnOffDevice = Disabled`.

## 4. Lenovo ThinkStation/ThinkCentre (P340, M920)

| BIOS Menu | Setting | Target Value |
| --- | --- | --- |
| *Config → Network → Wake On LAN* | **Enabled** | Global WoL switch. |
| *Config → Power → After Power Loss* | **Power On** | Ensures deterministic recovery after outages. |
| *Security → I/O Port Access → Ethernet LAN* | **Enabled** | Keeps NIC exposed to OS. |
| *Power → Enhanced Power Saving* | **Disabled** | Prevents deep power savings that drop WoL. |
| *Advanced → APM Configuration → Power On with PCI-E devices* | **Enabled** | Allows NIC wake. |

**Validation**
- Run `powercfg /devicequery wake_programmable` and ensure the Intel or Realtek NIC shows up.
- Execute `LabStation.exe energy audit` and check that `Wake Programmable` count ≥ 1 and no sleep timers are reported.

## 5. Post-change verification workflow

1. **Firmware photos**: Capture screenshots/photos of each BIOS page you changed and attach them to the hardware’s Confluence page.
2. **Windows verification**:
   - `LabStation.exe wol`
   - `LabStation.exe energy audit --json "C:\\LabStation\\data\\energy-<host>.json"`
   - `LabStation.exe status-json` (verifica `wake.nicPower` y `power.sleep`/`power.hibernate` para asegurar que WoL y los timeouts siguen conformes)
3. **Remote test**: From Lab Gateway, send a WoL packet, wait for WinRM to respond, then run `prepare-session`.
4. **Sign-off**: Attach the audit output and WoL test log to the ticket before closing the maintenance task.

## 6. Troubleshooting tips

| Symptom | Fix |
| --- | --- |
| Device wakes immediately after WoL | Disable USB wake and "Wake on Pattern" in NIC advanced properties. |
| WoL works from sleep but not from shutdown | Ensure "Deep Sleep Control" (Dell) / "S4/S5 Maximum Power Savings" (HP) is disabled. |
| WoL unreliable after Windows Update | Re-run `.\LabStation.exe wol` and verify NIC driver version; some updates reset power features. |
| Machine wakes but powers down again | Set `powercfg -change standby-timeout-ac 0` and confirm no vendor power utility is overriding the plan. |

Keep this document under version control and update it whenever a new hardware SKU enters the lab inventory.
