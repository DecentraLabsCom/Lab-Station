; ============================================================================
; Lab Station - Lightweight persistent service state
; ============================================================================
#Requires AutoHotkey v2.0
#Include ..\core\Config.ahk
#Include ..\core\Logger.ahk
#Include ..\core\Json.ahk

class LS_ServiceState {
    static RecordPrepareSession(success, details := Map()) {
        record := Map("success", success)
        this.CopyIfPresent(record, details, ["durationMs", "user"])
        return this.WriteSection("prepare-session", record)
    }

    static RecordReleaseSession(success, details := Map()) {
        record := Map("success", success)
        this.CopyIfPresent(record, details, ["durationMs", "user", "rebootRequested", "rebootTimeout"])
        return this.WriteSection("release-session", record)
    }

    static RecordSafeguardReboot(rebooted, details := Map()) {
        record := Map("rebooted", rebooted)
        this.CopyIfPresent(record, details, ["reason", "issues", "message"])
        if (details.Has("success"))
            record["success"] := details["success"]
        return this.WriteSection("safeguard-reboot", record)
    }

    static RecordForcedLogoff(details := Map()) {
        record := Map("success", true)
        this.CopyIfPresent(record, details, ["user", "sessionId", "state", "message", "source", "grace"])
        if (details.Has("success"))
            record["success"] := details["success"]
        return this.WriteSection("forced-logoff", record)
    }

    static RecordPowerAction(details := Map()) {
        record := Map("success", details.Has("success") ? details["success"] : true)
        this.CopyIfPresent(record, details, ["mode", "delay", "force", "reason", "wakeReady", "wakeArmed"])
        if (details.Has("wakeIssues"))
            record["wakeIssues"] := details["wakeIssues"]
        return this.WriteSection("power-action", record)
    }

    static GetOperationsSummary() {
        summary := Map()
        summary["lastPrepareSession"] := this.ReadSection("prepare-session")
        summary["lastReleaseSession"] := this.ReadSection("release-session")
        summary["lastSafeguardReboot"] := this.ReadSection("safeguard-reboot")
        summary["lastForcedLogoff"] := this.ReadSection("forced-logoff")
        summary["lastPowerAction"] := this.ReadSection("power-action")
        return summary
    }

    static WriteSection(section, record) {
        record := this.NormalizeRecord(record)
        for key, value in record {
            IniWrite(this.FormatValue(value), LAB_STATION_SERVICE_STATE_FILE, section, key)
        }
        return record
    }

    static NormalizeRecord(record) {
        normalized := Map("timestamp", this.TimestampUtc())
        for key, value in record {
            normalized[key] := value
        }
        return normalized
    }

    static ReadSection(section) {
        if (!FileExist(LAB_STATION_SERVICE_STATE_FILE))
            return Map()
        try {
            raw := IniRead(LAB_STATION_SERVICE_STATE_FILE, section)
        } catch {
            return Map()
        }
        if (raw = "")
            return Map()
        data := Map()
        for rawLine in StrSplit(raw, "`n") {
            line := Trim(StrReplace(rawLine, "`r"))
            if (line = "")
                continue
            splitter := InStr(line, "=")
            if (!splitter)
                continue
            key := Trim(SubStr(line, 1, splitter - 1))
            value := Trim(SubStr(line, splitter + 1))
            data[key] := this.ParseValue(value)
        }
        return data
    }

    static CopyIfPresent(target, source, keys) {
        for key in keys {
            if (source.Has(key)) {
                target[key] := source[key]
            }
        }
    }

    static FormatValue(value) {
        if (value is Number)
            return Format("{:.0f}", value)
        if (value = true)
            return "1"
        if (value = false)
            return "0"
        return value
    }

    static ParseValue(value) {
        lower := StrLower(value)
        if (lower = "true" || lower = "on")
            return true
        if (lower = "false" || lower = "off")
            return false
        if (lower = "1")
            return true
        if (lower = "0")
            return false
        if RegExMatch(value, "^-?\d+$")
            return value + 0
        return value
    }

    static TimestampUtc() {
        return FormatTime(A_NowUTC, "yyyy-MM-ddTHH:mm:ssZ")
    }
}
