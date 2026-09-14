# BIOS & Wake-on-LAN Playbook

The goal is to guarantee that every Lab Station host can power on via Wake-on-LAN (WoL) and stay awake for the entire reservation. Follow the steps below for each supported hardware family.

## 1. Reference checklist (all models)

1. Update BIOS/UEFI to the latest vendor-approved version.
2. Enable WoL from the power state required by the station (usually S4/hibernate; Fast Startup and full S5 shutdown wake are platform-dependent and must be tested).
3. Force the onboard NIC as the primary wake device; disable wake on Wi-Fi.
4. Disable all automatic sleep/hibernate timers while the host is in lab mode.
5. In Windows, run `LabStation.exe wol` after BIOS changes to refresh OS-level power settings.
6. Validate with `LabStation.exe energy audit --json="C:\LabStation\labstation\data\energy-<host>.json"` and keep the JSON report in the compliance folder.

## 2. Windows 10/11 desktop NIC configuration

This section is the Windows-side checklist for desktop stations using an
integrated or PCIe wired Ethernet adapter. The procedure applies to Windows
10 and Windows 11. Run the PowerShell commands from an elevated PowerShell
window (Run as administrator).

### 2.1 Identify the physical wired adapter

The name shown by Windows (`Ethernet`, `Ethernet 2`, etc.) is an interface
alias, not the hardware model. First identify the active physical adapter and
its interface description:

```powershell
Get-NetAdapter -Physical | Format-Table Name,Status,InterfaceDescription,MacAddress -Auto
```

Use the adapter whose `Status` is `Up` and whose cable is connected to the
station network. Lab Station evaluates every physical adapter that is active;
an additional active wired adapter must also be configured. Disconnected
physical adapters remain visible in diagnostics but do not fail readiness.

### 2.2 Configure the adapter in Device Manager

Open `devmgmt.msc`, then open **Network adapters → _the intended Ethernet
adapter_ → Properties**.

In **Power Management**:

- Enable **Allow this device to wake the computer**.
- If available, enable **Only allow a magic packet to wake the computer**.
- Disable **Allow the computer to turn off this device to save power**.

In **Advanced** (the exact names depend on the NIC driver):

- Set **Wake on Magic Packet** to **Enabled**.
- Set **Wake on Pattern Match** (or **Wake on Pattern**) to **Disabled**.
- If present, set **Shutdown Wake-On-LAN**, **Wake from power off**, or the
  equivalent vendor option to **Enabled**.

Apply the changes and restart the adapter, or reboot the station. Do not use a
Wi-Fi, virtual, or unused USB/dock adapter as the primary WoL path for a
desktop station unless its driver and firmware explicitly support wake from
the required power state.

### 2.3 Verify the values expected by Lab Station

Replace `Ethernet 2` with the alias returned by `Get-NetAdapter`:

```powershell
Get-NetAdapterPowerManagement -Name "Ethernet 2" |
    Select-Object WakeOnMagicPacket,WakeOnPattern,AllowComputerToTurnOffDevice,DeviceSleepOnDisconnect |
    Format-List

powercfg /devicequery wake_programmable
powercfg /devicequery wake_armed
```

For the active adapter, the expected power-management values are:

```text
WakeOnMagicPacket              : Enabled
WakeOnPattern                  : Disabled
AllowComputerToTurnOffDevice  : Disabled
```

The adapter's **interface description** (which may be different from the
alias `Ethernet 2`) should appear in `wake_armed`. Then run:

```powershell
.\LabStation.exe wol
if ($LASTEXITCODE -eq 0) {
    "WoL configuration completed"
} else {
    "WoL configuration failed with exit code $LASTEXITCODE"
}

.\LabStation.exe energy audit
.\LabStation.exe status-json "C:\LabStation\labstation\data\status.json"
```

`wol` may not open a dialog or print a success message; use `$LASTEXITCODE`
and `labstation\labstation.log` to determine whether it succeeded. The
visible `energy audit` result should show the active adapter as `[ready]`.
An inactive adapter shown as `[not evaluated (inactive)]` is expected and does
not require changes. `status` normally opens a summary dialog in an
interactive desktop session. `status-json` is intentionally silent when a
destination path is provided because it writes the report to that file; use
`energy audit` or inspect the generated JSON when no dialog is available.

### 2.4 Windows 11 power-state note

Check the power model before testing wake from sleep or power-off:

```powershell
powercfg /a
```

If the output contains **Standby (S0 Low Power Idle)**, the machine uses
Modern Standby. Do not force legacy S3 by editing the registry. Windows
manages network wake patterns differently in Modern Standby, and a USB-attached
Ethernet adapter or dock can lose wake capability during that state. Use the
OEM NIC/BIOS driver and validate the actual transition required by the lab.
See Microsoft's [system power-state guidance](https://learn.microsoft.com/en-us/windows/win32/power/system-power-states).

Windows does not guarantee WoL from Fast Startup or an S5 soft-off shutdown;
some firmware supports it independently. If the gateway must wake a powered-
down station, test the exact transition used in production. `power hibernate`
uses S4 and is generally the more predictable Windows-managed WoL test; a
`power shutdown` test additionally depends on the platform firmware.

### 2.5 Unsupported or unknown driver values

If `WakeOnMagicPacket`, `WakeOnPattern`, or
`AllowComputerToTurnOffDevice` is empty or reported as unsupported:

1. Install the latest wired-LAN driver and BIOS/UEFI update from the computer
   manufacturer.
2. Confirm that the integrated/PCIe NIC is enabled in BIOS/UEFI.
3. Reopen Device Manager and repeat the Power Management and Advanced checks.
4. Run `LabStation.exe wol` again and inspect `energy audit`.

If the active adapter still reports an unknown or unsupported value, the driver
does not expose the standard Windows power-management capability required by
the station. Escalate that hardware/driver combination instead of suppressing
the diagnostic.

## 3. Dell OptiPlex / Precision (7000, 5000 series)

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
  .\LabStation.exe energy audit --json="C:\LabStation\labstation\data\energy-dell-<host>.json"
  Get-Content -Raw "C:\LabStation\labstation\data\energy-dell-<host>.json" | ConvertFrom-Json
  ```
- Confirm `Wake-capable devices` includes `Intel(R) Ethernet Connection I219-LM` and that the audit report flags no sleep/hibernate timers.

## 4. HP Z2/Z4 Workstations & EliteDesk 800

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

## 5. Lenovo ThinkStation/ThinkCentre (P340, M920)

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

## 6. Post-change verification workflow

1. **Firmware photos**: Capture screenshots/photos of each BIOS page you changed and attach them to the hardware’s Confluence page.
2. **Windows verification**:
   - `LabStation.exe wol`
   - `LabStation.exe energy audit --json="C:\LabStation\labstation\data\energy-<host>.json"`
   - `LabStation.exe status-json "C:\LabStation\labstation\data\status.json"` (verify `wake.nicPower` and `power.sleep`/`power.hibernate` to ensure WoL and timeouts remain compliant)
3. **Remote test**: From Lab Gateway, send a WoL packet, wait for WinRM to respond, then run `prepare-session`.
4. **Sign-off**: Attach the audit output and WoL test log to the ticket before closing the maintenance task.

## 7. Troubleshooting tips

| Symptom | Fix |
| --- | --- |
| Device wakes immediately after WoL | Disable USB wake and "Wake on Pattern" in NIC advanced properties. |
| WoL works from sleep but not from shutdown | Ensure "Deep Sleep Control" (Dell) / "S4/S5 Maximum Power Savings" (HP) is disabled. |
| WoL unreliable after Windows Update | Re-run `.\LabStation.exe wol` and verify NIC driver version; some updates reset power features. |
| Machine wakes but powers down again | Set `powercfg -change standby-timeout-ac 0` and confirm no vendor power utility is overriding the plan. |

Keep this document under version control and update it whenever a new hardware SKU enters the lab inventory.
