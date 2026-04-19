; ============================================================================
; Lab Station - Status & diagnostics
; ============================================================================
#Requires AutoHotkey v2.0
#Include ..\core\Config.ahk
#Include ..\core\Logger.ahk
#Include ..\core\Shell.ahk
#Include ..\core\Json.ahk
#Include ..\system\RegistryManager.ahk
#Include ..\system\AccountManager.ahk
#Include ..\service\ServiceState.ahk
#Include ..\system\EnergyAudit.ahk

class LS_Status {
    static Collect() {
        data := Map()
        data["schemaVersion"] := LAB_STATION_SCHEMA_VERSION
        data["timestamp"] := FormatTime(A_NowUTC, "yyyy-MM-ddTHH:mm:ssZ")
        data["identity"] := this.GetIdentityInformation()
        data["remoteAppEnabled"] := this.CheckRemoteAppPolicy()
        data["autoStartConfigured"] := this.CheckRunEntry()
        data["wake"] := this.GetWakeInformation()
        data["power"] := this.GetPowerInformation()
        data["biosChecklist"] := this.GetBiosChecklist()
        rights := this.GetSecurityRights()
        data["policy"] := this.GetPolicyInformation(data["identity"], rights)
        data["sessions"] := this.GetSessionInformation(data["identity"])
        data["summary"] := this.BuildSummary(data)
        ops := LS_ServiceState.GetOperationsSummary()
        data["operations"] := ops
        data["lastForcedLogoff"] := ops.Has("lastForcedLogoff") ? ops["lastForcedLogoff"] : Map()
        data["localSessionActive"] := data["sessions"].Has("localSessionActive") ? data["sessions"]["localSessionActive"] : false
        data["localModeEnabled"] := this.IsLocalModeEnabled()
        return data
    }

    static ExportJson(path := "labstation\\status.json", data := "") {
        if (!IsObject(data))
            data := this.Collect()
        fullPath := this.ResolvePath(path)
        try {
            LS_WriteJson(fullPath, data)
            LS_LogInfo("Status exported to " . fullPath)
            return true
        } catch as e {
            LS_LogError("Cannot export status: " . e.Message)
            return false
        }
    }

    static SummaryText() {
        data := this.Collect()
        lines := []
        lines.Push("State: " . data["summary"]["state"])
        if (data["summary"]["issues"].Length > 0) {
            lines.Push("Issues: " . LS_StrJoin(data["summary"]["issues"], "; "))
        }
        lines.Push("RemoteApp: " . (data["remoteAppEnabled"] ? "OK" : "MISSING"))
        lines.Push("Autostart: " . (data["autoStartConfigured"] ? "OK" : "MISSING"))
        lines.Push(Format("Wake-capable devices: {1}", data["wake"]["armedCount"]))
        lines.Push("Active power plan: " . data["power"]["activePlan"])
        return LS_StrJoin(lines, "`n")
    }

    static GetIdentityInformation() {
        info := Map()
        user := LS_AccountManager.DefaultUser
        info["labUser"] := user
        info["labUserExists"] := this.LocalUserExists(user)
        info["labUserNormalized"] := this.NormalizePrincipal(user)
        profile := "C:\\Users\\" . user
        info["profilePath"] := DirExist(profile) ? profile : ""
        return info
    }

    static CheckRemoteAppPolicy() {
        basePath := "HKLM\\SOFTWARE\\Policies\\Microsoft\\Windows NT\\Terminal Services"
        try {
            value := RegRead(basePath, "fAllowUnlistedRemotePrograms")
            return value = 1
        } catch {
            return false
        }
    }

    static CheckRunEntry() {
        basePath := "HKLM\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Run"
        try {
            command := RegRead(basePath, "LabStationAppControl")
            return command != ""
        } catch {
            return false
        }
    }

    static GetWakeInformation() {
        info := Map()
        armed := LS_RunCommandCapture("powercfg /devicequery wake_armed", "wake_armed")
        programmable := LS_RunCommandCapture("powercfg /devicequery wake_programmable", "wake_programmable")
        info["armedDevices"] := this.ParseLines(armed["stdout"])
        info["armedCount"] := info["armedDevices"].Length
        info["programmableDevices"] := this.ParseLines(programmable["stdout"])
        info["programmableCount"] := info["programmableDevices"].Length
        adapters := LS_EnergyAudit.GetNicPowerManagement()
        info["nicPower"] := []
        lookup := this.BuildDeviceLookup(info["armedDevices"])
        nonCompliant := []
        for adapter in adapters {
            adapter["wakeArmed"] := this.AdapterAppearsInLookup(adapter["name"], lookup)
            info["nicPower"].Push(adapter)
            if (!adapter["wolReady"]) {
                nonCompliant.Push(adapter)
            }
        }
        info["nicNonCompliant"] := nonCompliant
        return info
    }

    static GetPowerInformation() {
        result := Map()
        scheme := LS_RunCommandCapture("powercfg /getactivescheme", "active scheme")
        result["activePlan"] := this.ParseSchemeName(scheme["stdout"])
        result["sleep"] := LS_EnergyAudit.QueryPowerSetting("STANDBYIDLE")
        result["hibernate"] := LS_EnergyAudit.QueryPowerSetting("HIBERNATEIDLE")
        result["sleepCompliant"] := this.IsTimeoutDisabled(result["sleep"])
        result["hibernateCompliant"] := this.IsTimeoutDisabled(result["hibernate"])
        return result
    }

    static ParseSchemeName(text) {
        if RegExMatch(text, "\(([^\)]+)\)$", &m) {
            return m[1]
        }
        return Trim(text)
    }

    static ParseLines(text) {
        cleaned := []
        for line in StrSplit(Trim(text), "`n") {
            trimmed := Trim(line)
            if (trimmed != "") {
                cleaned.Push(trimmed)
            }
        }
        return cleaned
    }

    static GetBiosChecklist() {
        return [
            "Verify in BIOS/UEFI that Wake-on-LAN is enabled",
            "Allow power-on from the integrated NIC",
            "If multiple NICs exist, confirm which one is wired",
            "Save changes and run a magic packet test"
        ]
    }

    static GetPolicyInformation(identity, rights) {
        policy := Map()
        target := identity["labUser"]
        policy["autoLogon"] := this.GetAutologonState(target)
        policy["remoteDesktopUsers"] := this.GetRemoteDesktopGroupState(target)
        policy["denyInteractive"] := this.GetDenyInteractiveState(target, rights)
        return policy
    }

    static GetAutologonState(targetUser) {
        state := Map("enabled", false, "user", "", "passwordSet", false, "userMatches", false)
        key := "HKLM\\SOFTWARE\\Microsoft\\Windows NT\\CurrentVersion\\Winlogon"
        try {
            value := RegRead(key, "AutoAdminLogon")
            state["enabled"] := (value = 1 || value = "1")
        } catch {
            state["enabled"] := false
        }
        try {
            defaultUser := RegRead(key, "DefaultUserName")
            state["user"] := defaultUser
            state["userMatches"] := this.EqualsUser(defaultUser, targetUser)
        } catch {
            state["user"] := ""
        }
        try {
            password := RegRead(key, "DefaultPassword")
            state["passwordSet"] := (password != "")
        } catch {
            state["passwordSet"] := false
        }
        return state
    }

    static GetRemoteDesktopGroupState(targetUser) {
        state := Map()
        script := "
        (
        try {
            Get-LocalGroupMember -Group 'Remote Desktop Users' -ErrorAction Stop | Where-Object {`$_.ObjectClass -eq 'User'} | ForEach-Object {`$_.Name}
        } catch {}
        )"
        capture := LS_RunPowerShellCapture(script, "Query Remote Desktop Users members")
        members := this.ParseLines(capture["stdout"])
        state["members"] := members
        state["labUserPresent"] := this.ContainsUser(members, targetUser)
        others := []
        for name in members {
            if (!this.EqualsUser(name, targetUser))
                others.Push(name)
        }
        state["otherMembers"] := others
        return state
    }

    static GetDenyInteractiveState(targetUser, rights) {
        state := Map("configured", false, "members", [], "labUserDenied", false, "raw" , "")
        if (rights.Has("SeDenyInteractiveLogonRight")) {
            raw := Trim(rights["SeDenyInteractiveLogonRight"])
            state["raw"] := raw
            if (raw != "") {
                state["configured"] := true
                entries := StrSplit(raw, ",")
                cleaned := []
                for entry in entries {
                    token := Trim(entry)
                    if (token = "")
                        continue
                    label := this.GetFriendlyPrincipalName(token)
                    cleaned.Push(Map("token", token, "label", label))
                    if (this.EqualsUser(token, targetUser) || this.EqualsUser(label, targetUser))
                        state["labUserDenied"] := true
                }
                state["members"] := cleaned
            }
        }
        return state
    }

    static GetSecurityRights() {
        rights := Map()
        temp := A_Temp "\LabStationPolicy-" . A_TickCount . ".inf"
        cmd := Format('secedit /export /cfg "{1}" /areas USER_RIGHTS >nul 2>&1', temp)
        exitCode := LS_RunCommand(cmd, "Export user rights")
        if (exitCode = 0) {
            text := ""
            try {
                text := FileRead(temp, "UTF-16")
            } catch {
                try text := FileRead(temp)
            }
            rights := this.ParseSecurityExport(text)
        } else {
            LS_LogWarning("Unable to export security policy (exit=" . exitCode . ")")
        }
        try FileDelete(temp)
        return rights
    }

    static ParseSecurityExport(text) {
        rights := Map()
        if (!text || text = "")
            return rights
        currentSection := ""
        for rawLine in StrSplit(text, "`n") {
            line := Trim(StrReplace(rawLine, "`r"))
            if (line = "" || SubStr(line, 1, 1) = ";")
                continue
            if (SubStr(line, 1, 1) = "[") {
                section := StrLower(SubStr(line, 2, StrLen(line) - 2))
                currentSection := section
                continue
            }
            if (currentSection != "privilege rights")
                continue
            if RegExMatch(line, "^(Se[A-Za-z0-9]+)\s*=\s*(.*)$", &m) {
                rights[m[1]] := Trim(m[2])
            }
        }
        return rights
    }

    static GetFriendlyPrincipalName(token) {
        cleaned := token
        if (SubStr(cleaned, 1, 1) = "*")
            cleaned := SubStr(cleaned, 2)
        normalized := this.NormalizePrincipal(cleaned)
        static Known := Map(
            "S-1-5-32-544", "Builtin\\Administrators",
            "S-1-5-32-545", "Builtin\\Users",
            "S-1-5-32-546", "Builtin\\Guests",
            "S-1-5-32-551", "Builtin\\Backup Operators"
        )
        if (Known.Has(cleaned))
            return Known[cleaned]
        if (RegExMatch(cleaned, "^S-\d-"))
            return cleaned
        if (InStr(cleaned, "\\"))
            return cleaned
        return normalized != "" ? normalized : cleaned
    }

    static ContainsUser(list, user) {
        for item in list {
            if (this.EqualsUser(item, user))
                return true
        }
        return false
    }

    static EqualsUser(candidate, target) {
        return this.NormalizePrincipal(candidate) = this.NormalizePrincipal(target)
    }

    static NormalizePrincipal(value) {
        if (!value)
            return ""
        cleaned := StrLower(Trim(value))
        if (cleaned = "")
            return ""
        if (SubStr(cleaned, 1, 1) = "*")
            cleaned := SubStr(cleaned, 2)
        lastSlash := InStr(cleaned, "\\", , -1)
        if (lastSlash > 0)
            cleaned := SubStr(cleaned, lastSlash + 1)
        return cleaned
    }

    static LocalUserExists(user) {
        escaped := StrReplace(user, "'", "''")
        script := Format("
        (
        if (Get-LocalUser -Name '{1}' -ErrorAction SilentlyContinue) {{ '1' }}
        )", escaped)
        capture := LS_RunPowerShellCapture(script, "Check local user")
        return InStr(capture["stdout"], "1") > 0
    }

    static GetSessionInformation(identity) {
        info := Map()
        capture := LS_RunCommandCapture("quser", "Query sessions")
        entries := capture["exitCode"] = 0 ? this.ParseSessionEntries(capture["stdout"]) : []
        info["entries"] := entries
        info["labUserState"] := "none"
        info["labUserSessionId"] := ""
        info["otherUsers"] := []
        target := identity["labUser"]
        for entry in entries {
            if (this.EqualsUser(entry["user"], target)) {
                info["labUserState"] := entry["state"]
                info["labUserSessionId"] := entry["id"]
            } else {
                info["otherUsers"].Push(entry)
            }
        }
        info["hasOtherUsers"] := info["otherUsers"].Length > 0
        info["localSessionActive"] := info["hasOtherUsers"]
        return info
    }

    static ParseSessionEntries(text) {
        entries := []
        for rawLine in StrSplit(text, "`n") {
            line := Trim(StrReplace(rawLine, "`r"))
            if (line = "" || InStr(line, "USERNAME") = 1)
                continue
            if (SubStr(line, 1, 1) = ">")
                line := Trim(SubStr(line, 2))
            normalized := RegExReplace(line, "\s{2,}", "|")
            parts := StrSplit(normalized, "|")
            if (parts.Length < 4)
                continue
            entry := Map()
            entry["user"] := Trim(parts[1])
            entry["session"] := parts.Length >= 2 ? Trim(parts[2]) : ""
            entry["id"] := parts.Length >= 3 ? Trim(parts[3]) : ""
            entry["state"] := parts.Length >= 4 ? Trim(parts[4]) : ""
            entry["idle"] := parts.Length >= 5 ? Trim(parts[5]) : ""
            remaining := []
            if (parts.Length >= 6) {
                loop parts.Length - 5 {
                    remaining.Push(Trim(parts[A_Index + 5]))
                }
                entry["logonTime"] := Trim(LS_StrJoin(remaining, " "))
            } else {
                entry["logonTime"] := ""
            }
            entries.Push(entry)
        }
        return entries
    }

    static IsLocalModeEnabled() {
        return FileExist(LAB_STATION_LOCAL_MODE_FLAG) ? true : false
    }

    static BuildSummary(data) {
        issues := []
        if (!data["identity"]["labUserExists"])
            issues.Push("Lab user not found")
        if (!data["remoteAppEnabled"])
            issues.Push("RemoteApp policy missing")
        if (!data["autoStartConfigured"])
            issues.Push("Controller autostart missing")
        autoLogon := data["policy"]["autoLogon"]
        if (!autoLogon["enabled"])
            issues.Push("AutoAdminLogon disabled")
        if (!autoLogon["userMatches"])
            issues.Push("Autologon user mismatch")
        if (!autoLogon["passwordSet"])
            issues.Push("Autologon password not stored")
        rds := data["policy"]["remoteDesktopUsers"]
        if (!rds["labUserPresent"])
            issues.Push("Lab user missing from Remote Desktop Users")
        if (rds["otherMembers"].Length > 0)
            issues.Push("Unexpected Remote Desktop Users members: " . LS_StrJoin(rds["otherMembers"], ", "))
        deny := data["policy"]["denyInteractive"]
        if (!deny["configured"])
            issues.Push("SeDenyInteractiveLogonRight not configured")
        if (deny["labUserDenied"])
            issues.Push("Lab user denied interactive logon")
        if (data["sessions"]["hasOtherUsers"])
            issues.Push("Another user is logged on")
        if (data["wake"]["armedCount"] = 0)
            issues.Push("No wake-armed devices detected")
        if (data["wake"]["nicNonCompliant"].Length > 0)
            issues.Push("NIC power settings incomplete for: " . this.JoinAdapterNames(data["wake"]["nicNonCompliant"]))
        if (!data["power"]["sleepCompliant"])
            issues.Push("Sleep timeout is not disabled")
        if (!data["power"]["hibernateCompliant"])
            issues.Push("Hibernate timeout is not disabled")
        summary := Map()
        summary["state"] := issues.Length > 0 ? "needs-action" : "ready"
        summary["issues"] := issues
        return summary
    }

    static IsTimeoutDisabled(info) {
        if (!info || !info.Has("acSeconds"))
            return false
        ac := info["acSeconds"]
        dc := info["dcSeconds"]
        return (ac = "" || ac = 0) && (dc = "" || dc = 0)
    }

    static JoinAdapterNames(adapters) {
        names := []
        for adapter in adapters {
            if (adapter.Has("name"))
                names.Push(adapter["name"])
        }
        return names.Length > 0 ? LS_StrJoin(names, ", ") : "NICs"
    }

    static BuildDeviceLookup(devices) {
        lookup := Map()
        for device in devices {
            key := this.NormalizeDeviceName(device)
            if (key != "")
                lookup[key] := true
        }
        return lookup
    }

    static AdapterAppearsInLookup(name, lookup) {
        key := this.NormalizeDeviceName(name)
        return key != "" && lookup.Has(key)
    }

    static NormalizeDeviceName(name) {
        if (!name)
            return ""
        cleaned := StrLower(Trim(name))
        return cleaned
    }

    static ResolvePath(path) {
        if (RegExMatch(path, "^[A-Za-z]:\\") || SubStr(path, 1, 2) = "\\\\") {
            return path
        }
        if (SubStr(path, 1, 2) = ".\\") {
            return LAB_STATION_PROJECT_ROOT "\" SubStr(path, 3)
        }
        return LAB_STATION_PROJECT_ROOT "\" path
    }
}
