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
            verdict := nic["wolReady"] ? "ready" : "issues: " . LS_StrJoin(nic["complianceIssues"], "; ")
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
        `$adapters = Get-NetAdapter -Physical -ErrorAction SilentlyContinue
        foreach (`$adapter in `$adapters) {
            `$pm = Get-NetAdapterPowerManagement -Name `$adapter.Name -ErrorAction SilentlyContinue
            if (-not `$pm) { continue }
            `$advancedTable = @{}
            Get-NetAdapterAdvancedProperty -Name `$adapter.Name -ErrorAction SilentlyContinue | ForEach-Object {
                if (`$_.RegistryKeyword) {
                    `$advancedTable[`$_.RegistryKeyword.ToLower()] = `$_.DisplayValue
                }
            }
            `$advWakeMagic = `$null
            if (`$advancedTable.ContainsKey('wakeonmagicpacket')) {
                `$advWakeMagic = `$advancedTable['wakeonmagicpacket']
            }
            `$advWakePattern = `$null
            if (`$advancedTable.ContainsKey('wakeonpattern')) {
                `$advWakePattern = `$advancedTable['wakeonpattern']
            }
            `$line = '{0}|{1}|{2}|{3}|{4}|{5}|{6}' -f `$adapter.Name, `$pm.WakeOnMagicPacket, `$pm.WakeOnPattern, `$pm.DeviceSleepOnDisconnect, `$pm.AllowComputerToTurnOffDevice, `$advWakeMagic, `$advWakePattern
            Write-Output `$line
        }
        )"
        capture := LS_RunPowerShellCapture(script, "Query NIC power settings")
        adapters := []
        if (capture["exitCode"] != 0) {
            LS_LogWarning("Energy audit: unable to read NIC power settings (exit=" . capture["exitCode"] . ")")
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
            this.DecorateNicCompliance(entry)
            adapters.Push(entry)
        }
        return adapters
    }

    static DecorateNicCompliance(entry) {
        issues := []
        if (!this.ValueIsEnabled(entry["wakeOnMagicPacket"]) && !this.ValueIsEnabled(entry["advancedWakeOnMagicPacket"]))
            issues.Push("Wake on Magic Packet disabled")
        if (this.ValueIsEnabled(entry["wakeOnPattern"]) || this.ValueIsEnabled(entry["advancedWakeOnPattern"]))
            issues.Push("Wake on Pattern should be disabled")
        if (this.ValueIsEnabled(entry["allowTurnOff"]))
            issues.Push("Allow computer to turn off is enabled")
        entry["complianceIssues"] := issues
        entry["wolReady"] := issues.Length = 0
    }

    static ValueIsEnabled(value) {
        if (!value)
            return false
        normalized := StrLower(Trim(value))
        return normalized = "enabled" || normalized = "true" || normalized = "on"
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
                recs.Push("Enable WakeOnMagicPacket and disable 'Allow computer to turn off this device' for " . nic["name"] . ".")
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
            trimmed := Trim(line)
            if (trimmed != "")
                items.Push(trimmed)
        }
        return items
    }

    static ResolvePath(path) {
        if (RegExMatch(path, "^[A-Za-z]:\\") || SubStr(path, 1, 2) = "\\\\")
            return path
        if (SubStr(path, 1, 2) = ".\\")
            return LAB_STATION_PROJECT_ROOT "\" SubStr(path, 3)
        return LAB_STATION_PROJECT_ROOT "\" path
    }

    static HexToDecimal(value) {
        if (!value || value = "")
            return ""
        return ("0x" . value) + 0
    }
}
