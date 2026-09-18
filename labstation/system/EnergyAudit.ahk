; ============================================================================
; Lab Station - Energy & Wake-on-LAN audit helpers
; ============================================================================
#Requires AutoHotkey v2.0
#Include ..\core\Config.ahk
#Include ..\core\Logger.ahk
#Include ..\core\Shell.ahk
#Include ..\core\Json.ahk

class LS_EnergyAudit {
    static Run() {
        data := Map()
        data["timestamp"] := FormatTime(A_NowUTC, "yyyy-MM-ddTHH:mm:ssZ")
        data["activePlan"] := this.GetActivePlan()
        data["sleep"] := this.QueryPowerSetting("STANDBYIDLE")
        data["hibernate"] := this.QueryPowerSetting("HIBERNATEIDLE")
        data["wakeDevices"] := this.GetWakeDevices()
        data["nicPower"] := this.GetNicPowerManagement()
        data["recommendations"] := this.BuildRecommendations(data)
        return data
    }

    static RenderSummary(data) {
        lines := []
        lines.Push("Active plan: " . data["activePlan"]["name"])
        lines.Push(Format("Sleep timeout (AC/DC): {1} / {2}", this.FormatSeconds(data["sleep"]["acSeconds"]), this.FormatSeconds(data["sleep"]["dcSeconds"])))
        lines.Push(Format("Hibernate timeout (AC/DC): {1} / {2}", this.FormatSeconds(data["hibernate"]["acSeconds"]), this.FormatSeconds(data["hibernate"]["dcSeconds"])))
        lines.Push(Format("Wake-programmable devices: {1}", data["wakeDevices"]["programmableCount"]))
        lines.Push(Format("Wake-armed devices: {1} ({2})", data["wakeDevices"]["armedCount"], this.JoinSample(data["wakeDevices"]["armedDevices"])))
        lines.Push("NIC power state:")
        for nic in data["nicPower"] {
            verdict := !nic["isOperational"] ? "not evaluated (inactive)"
                : (nic["wolReady"] ? "ready" : "issues: " . LS_StrJoin(nic["complianceIssues"], "; "))
            lines.Push(Format("  - {1}: WakeOnMagicPacket={2}, WakeOnPattern={3}, AllowTurnOff={4} [{5}]", nic["name"], nic["wakeOnMagicPacket"], nic["wakeOnPattern"], nic["allowTurnOff"], verdict))
        }
        lines.Push("Recommendations:")
        if (data["recommendations"].Length = 0) {
            lines.Push("  - None. Power posture looks good.")
        } else {
            for rec in data["recommendations"]
                lines.Push("  - " . rec)
        }
        return LS_StrJoin(lines, "`n")
    }

    static SaveJson(path, data) {
        target := this.ResolvePath(path)
        try {
            LS_WriteJson(target, data)
            return true
        } catch as e {
            LS_LogError("Energy audit: unable to write " . target . " (" . e.Message . ")")
            return false
        }
    }

    static GetActivePlan() {
        capture := LS_RunCommandCapture("powercfg /getactivescheme", "Query active power plan")
        name := "Unknown"
        if RegExMatch(capture["stdout"], "\(([^\)]+)\)$", &m)
            name := m[1]
        return Map("name", name, "raw", capture["stdout"])
    }

    static QueryPowerSetting(setting) {
        command := Format("powercfg /q SCHEME_CURRENT SUB_SLEEP {1}", setting)
        capture := LS_RunCommandCapture(command, "Query power setting " . setting)
        info := Map()
        info["raw"] := capture["stdout"]
        info["acSeconds"] := this.ParsePowerIndex(capture["stdout"], "AC")
        info["dcSeconds"] := this.ParsePowerIndex(capture["stdout"], "DC")
        return info
    }

    static ParsePowerIndex(text, mode) {
        pattern := mode = "AC" ? "Current AC Power Setting Index:\s+0x([0-9A-F]+)" : "Current DC Power Setting Index:\s+0x([0-9A-F]+)"
        if RegExMatch(text, pattern, &m) {
            return this.HexToDecimal(m[1])
        }
        return ""
    }

    static GetWakeDevices() {
        info := Map()
        programmable := LS_RunCommandCapture("powercfg /devicequery wake_programmable", "wake_programmable")
        armed := LS_RunCommandCapture("powercfg /devicequery wake_armed", "wake_armed")
        info["programmableDevices"] := this.ParseLines(programmable["stdout"])
        info["armedDevices"] := this.ParseLines(armed["stdout"])
        info["programmableCount"] := info["programmableDevices"].Length
        info["armedCount"] := info["armedDevices"].Length
        return info
    }

    static GetNicPowerManagement() {
        script := "
        (
        `$adapters = @(Get-NetAdapter -Physical -ErrorAction SilentlyContinue)
        if (-not `$adapters) {
            Write-Error 'No physical network adapters could be queried'
            exit 1
        }
        foreach (`$adapter in `$adapters) {
            `$pm = Get-NetAdapterPowerManagement -Name `$adapter.Name -ErrorAction SilentlyContinue
            `$advancedTable = @{}
            Get-NetAdapterAdvancedProperty -Name `$adapter.Name -AllProperties -ErrorAction SilentlyContinue | ForEach-Object {
                `$keyword = ([string]`$_.RegistryKeyword).Trim().TrimStart([char]'*').ToLowerInvariant()
                if (`$keyword -ne '') {
                    # Standardized NDIS keywords have a leading '*'. Keep the
                    # normalized key and the raw registry value so detection
                    # does not depend on the display language of Windows.
                    `$advancedTable[`$keyword] = `$_
                }
            }
            `$advWakeMagic = `$null
            `$advWakeMagicRegistry = `$null
            if (`$advancedTable.ContainsKey('wakeonmagicpacket')) {
                `$property = `$advancedTable['wakeonmagicpacket']
                `$advWakeMagic = `$property.DisplayValue
                `$advWakeMagicRegistry = (`$property.RegistryValue -join ',')
            }
            `$advWakePattern = `$null
            `$advWakePatternRegistry = `$null
            if (`$advancedTable.ContainsKey('wakeonpattern')) {
                `$property = `$advancedTable['wakeonpattern']
                `$advWakePattern = `$property.DisplayValue
                `$advWakePatternRegistry = (`$property.RegistryValue -join ',')
            }
            `$safeName = ([string]`$adapter.Name) -replace '\|', ' '
            `$safeMagic = ([string]`$pm.WakeOnMagicPacket) -replace '\|', ' '
            `$safePattern = ([string]`$pm.WakeOnPattern) -replace '\|', ' '
            `$safeSleep = ([string]`$pm.DeviceSleepOnDisconnect) -replace '\|', ' '
            `$safeAllow = ([string]`$pm.AllowComputerToTurnOffDevice) -replace '\|', ' '
            `$safeAdvMagic = ([string]`$advWakeMagic) -replace '\|', ' '
            `$safeAdvPattern = ([string]`$advWakePattern) -replace '\|', ' '
            `$safeDescription = ([string]`$adapter.InterfaceDescription) -replace '\|', ' '
            `$line = '{0}|{1}|{2}|{3}|{4}|{5}|{6}|{7}|{8}|{9}|{10}|{11}|{12}' -f `$safeName, `$safeMagic, `$safePattern, `$safeSleep, `$safeAllow, `$safeAdvMagic, `$safeAdvPattern, `$adapter.MacAddress, `$adapter.Status, `$safeDescription, `$advWakeMagicRegistry, `$advWakePatternRegistry, [bool]`$pm
            Write-Output `$line
        }
        )"
        capture := LS_RunPowerShellCapture(script, "Query NIC power settings")
        adapters := []
        if (capture["exitCode"] != 0 || Trim(capture["stdout"]) = "") {
            detail := LS_CaptureDetail(capture)
            if (detail != "")
                LS_LogWarning("Energy audit: unable to read NIC power settings (exit=" . capture["exitCode"] . "): " . detail)
            else
                LS_LogWarning("Energy audit: unable to read NIC power settings (exit=" . capture["exitCode"] . ")")
            failure := Map(
                "name", "NIC power settings",
                "wakeOnMagicPacket", "",
                "wakeOnPattern", "",
                "allowTurnOff", "",
                "status", "Up",
                "interfaceDescription", "",
                "advancedWakeOnMagicPacket", "",
                "advancedWakeOnPattern", "",
                "advancedWakeOnMagicPacketRegistryValue", "",
                "advancedWakeOnPatternRegistryValue", "",
                "powerManagementAvailable", false,
                "isOperational", true,
                "queryFailed", true,
                "complianceIssues", ["Unable to query NIC power settings"],
                "wolConfigReady", false,
                "wolReady", false
            )
            adapters.Push(failure)
            return adapters
        }
        for rawLine in StrSplit(capture["stdout"], "`n") {
            line := Trim(StrReplace(rawLine, "`r"))
            if (line = "")
                continue
            parts := StrSplit(line, "|")
            if (parts.Length < 5)
                continue
            entry := Map()
            entry["name"] := Trim(parts[1])
            entry["wakeOnMagicPacket"] := Trim(parts[2])
            entry["wakeOnPattern"] := Trim(parts[3])
            entry["deviceSleepOnDisconnect"] := Trim(parts[4])
            entry["allowTurnOff"] := parts.Length >= 5 ? Trim(parts[5]) : ""
            entry["advancedWakeOnMagicPacket"] := parts.Length >= 6 ? Trim(parts[6]) : ""
            entry["advancedWakeOnPattern"] := parts.Length >= 7 ? Trim(parts[7]) : ""
            entry["macAddress"] := parts.Length >= 8 ? Trim(parts[8]) : ""
            entry["status"] := parts.Length >= 9 ? Trim(parts[9]) : ""
            entry["interfaceDescription"] := parts.Length >= 10 ? Trim(parts[10]) : ""
            entry["advancedWakeOnMagicPacketRegistryValue"] := parts.Length >= 11 ? Trim(parts[11]) : ""
            entry["advancedWakeOnPatternRegistryValue"] := parts.Length >= 12 ? Trim(parts[12]) : ""
            entry["powerManagementAvailable"] := parts.Length < 13 || StrLower(Trim(parts[13])) = "true"
            entry["isOperational"] := entry["status"] = "" || StrLower(entry["status"]) = "up"
            this.DecorateNicCompliance(entry)
            adapters.Push(entry)
        }
        return adapters
    }

    static DecorateNicCompliance(entry) {
        issues := []
        magicState := this.ResolveSettingState([
            entry["wakeOnMagicPacket"],
            entry["advancedWakeOnMagicPacketRegistryValue"],
            entry["advancedWakeOnMagicPacket"]
        ], "wake")
        patternState := this.ResolveSettingState([
            entry["wakeOnPattern"],
            entry["advancedWakeOnPatternRegistryValue"],
            entry["advancedWakeOnPattern"]
        ], "wake")
        allowState := this.ResolveSettingState([entry["allowTurnOff"]], "allow")
        if (magicState != "enabled")
            issues.Push("Wake on Magic Packet disabled or unavailable")
        if (patternState != "disabled")
            issues.Push("Wake on Pattern enabled or unavailable")
        if (allowState != "enabled")
            issues.Push("Allow computer to turn off is disabled or unavailable")
        entry["complianceIssues"] := issues
        entry["wolConfigReady"] := issues.Length = 0
        ; Disconnected physical adapters are retained in diagnostics, but do
        ; not make the station fail readiness. An active adapter with an
        ; unsupported or unknown setting remains non-compliant.
        entry["wolReady"] := !entry["isOperational"] || entry["wolConfigReady"]
    }

    static ResolveSettingState(values, kind := "wake") {
        hasEnabled := false
        hasDisabled := false
        hasUnsupported := false
        for value in values {
            state := this.ParseSettingState(value, kind)
            if (state = "enabled")
                hasEnabled := true
            else if (state = "disabled")
                hasDisabled := true
            else if (state = "unsupported")
                hasUnsupported := true
        }
        if (hasEnabled && hasDisabled)
            return "conflict"
        if (hasEnabled)
            return "enabled"
        if (hasDisabled)
            return "disabled"
        if (hasUnsupported)
            return "unsupported"
        return "unknown"
    }

    static ParseSettingState(value, kind := "wake") {
        if (value = "")
            return "unknown"
        normalized := StrLower(Trim(value))
        if (normalized = "enabled" || normalized = "true" || normalized = "on"
            || normalized = "yes" || normalized = "si" || normalized = "sí"
            || normalized = "habilitado" || normalized = "habilitada"
            || normalized = "activado" || normalized = "activada")
            return "enabled"
        if (normalized = "disabled" || normalized = "false" || normalized = "off"
            || normalized = "no" || normalized = "deshabilitado" || normalized = "deshabilitada"
            || normalized = "desactivado" || normalized = "desactivada")
            return "disabled"
        if (normalized = "unsupported" || normalized = "not supported"
            || normalized = "unavailable" || normalized = "n/a")
            return "unsupported"
        if RegExMatch(normalized, "^\d+$") {
            number := normalized + 0
            if (kind = "allow")
                return number = 2 ? "enabled" : (number = 1 ? "disabled" : (number = 0 ? "unsupported" : "unknown"))
            return number = 1 ? "enabled" : (number = 0 ? "disabled" : "unknown")
        }
        return "unknown"
    }

    static BuildRecommendations(data) {
        recs := []
        if (data["sleep"]["acSeconds"] != "" && data["sleep"]["acSeconds"] > 0)
            recs.Push("Set AC sleep timeout to Never (0).")
        if (data["sleep"]["dcSeconds"] != "" && data["sleep"]["dcSeconds"] > 0)
            recs.Push("Set DC sleep timeout to Never (0) while in lab mode.")
        if (data["hibernate"]["acSeconds"] != "" && data["hibernate"]["acSeconds"] > 0)
            recs.Push("Disable hibernate on AC (powercfg /hibernate off).")
        if (data["hibernate"]["dcSeconds"] != "" && data["hibernate"]["dcSeconds"] > 0)
            recs.Push("Disable hibernate on DC while hosts are wired.")
        if (data["wakeDevices"]["armedCount"] = 0)
            recs.Push("No wake-armed devices detected. Re-run LabStation.exe wol or review BIOS settings.")
        for nic in data["nicPower"] {
            if (!nic["wolReady"]) {
                recs.Push("Enable WakeOnMagicPacket and allow the computer to turn off this device for " . nic["name"] . ".")
            }
        }
        return recs
    }

    static FormatSeconds(value) {
        if (value = "" || value = 0)
            return "Never"
        minutes := Round(value / 60, 1)
        if (minutes >= 120)
            return Round(minutes / 60, 1) . " h"
        return minutes . " min"
    }

    static JoinSample(list, maxItems := 3) {
        if (list.Length = 0)
            return "none"
        sample := []
        limit := Min(maxItems, list.Length)
        Loop limit
            sample.Push(list[A_Index])
        if (list.Length > maxItems)
            sample.Push("+" . (list.Length - maxItems) . " more")
        return LS_StrJoin(sample, ", ")
    }

    static ParseLines(text) {
        items := []
        for line in StrSplit(Trim(text), "`n") {
            trimmed := Trim(line, " `t`r")
            if (trimmed != "")
                items.Push(trimmed)
        }
        return items
    }

    static ResolvePath(path) {
        if (RegExMatch(path, "^[A-Za-z]:\\") || SubStr(path, 1, 2) = "\\")
            return path
        if (SubStr(path, 1, 2) = ".\")
            return LAB_STATION_PROJECT_ROOT "\" SubStr(path, 3)
        return LAB_STATION_PROJECT_ROOT "\" path
    }

    static HexToDecimal(value) {
        if (!value || value = "")
            return ""
        return ("0x" . value) + 0
    }
}
