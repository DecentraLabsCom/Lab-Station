; ============================================================================
; Lab Station - Lightweight command queue for background service
; ============================================================================
#Requires AutoHotkey v2.0

class LS_CommandQueue {
    static Initialized := false

    static Init() {
        if (this.Initialized)
            return
        EnsureDir(LAB_STATION_COMMAND_DIR)
        EnsureDir(LAB_STATION_COMMAND_INBOX)
        EnsureDir(LAB_STATION_COMMAND_PROCESSED_DIR)
        EnsureDir(LAB_STATION_COMMAND_RESULTS_DIR)
        this.Initialized := true
    }

    static ProcessPending() {
        this.Init()
        processed := 0
        Loop Files, LAB_STATION_COMMAND_INBOX "\*.ini" {
            try {
                this.HandleFile(A_LoopFileFullPath)
            } catch as e {
                LS_LogError("Command queue error: " . e.Message)
            }
            processed += 1
        }
        return processed
    }

    static HandleFile(path) {
        LS_LogInfo("Processing queued command: " . path)
        parsed := this.ParseCommandFile(path)
        cmd := Map()
        if (parsed.Has("name") && parsed["name"] != "") {
            cmd["name"] := StrLower(parsed["name"])
        } else {
            cmd["name"] := "unknown"
        }
        cmd["id"] := this.ResolveCommandId(parsed, path)
        cmd["options"] := this.ExtractOptions(parsed)
        cmd["metadata"] := parsed
        cmd["source"] := path
        result := parsed.Has("name") && parsed["name"] != "" ? this.Dispatch(cmd) : this.ResultState(false, 2, "Command name missing")
        this.WriteResult(cmd, result)
        this.Archive(path, cmd["id"])
    }

    static Dispatch(cmd) {
        try {
            switch cmd["name"] {
                case "prepare-session":
                    success := LS_SessionManager.PrepareSession(cmd["options"])
                    message := success ? "Prepare-session completed" : "Prepare-session reported warnings"
                    return this.ResultState(success, success ? 0 : 1, message)
                case "release-session":
                    success := LS_SessionManager.ReleaseSession(cmd["options"])
                    message := success ? "Release-session completed" : "Release-session reported warnings"
                    return this.ResultState(success, success ? 0 : 1, message)
                case "status-json":
                    target := cmd["options"].Has("path") ? cmd["options"]["path"] : LAB_STATION_STATUS_FILE
                    success := LS_Status.ExportJson(target)
                    message := success ? "Status exported" : "Unable to export status"
                    return this.ResultState(success, success ? 0 : 2, message)
                case "session-guard":
                    guard := LS_SessionGuard.Run(cmd["options"])
                    message := guard ? "Session guard completed" : "Session guard reported warnings"
                    return this.ResultState(guard, guard ? 0 : 1, message)
                case "reboot-if-needed":
                    outcome := LS_Recovery.RebootIfNeeded(cmd["options"])
                    success := outcome.Has("success") ? outcome["success"] : outcome["rebooted"]
                    exitCode := success ? 0 : 2
                    return this.ResultState(success, exitCode, outcome["message"])
                case "power-shutdown":
                    success := LS_PowerManager.Shutdown(cmd["options"])
                    message := success ? "Shutdown scheduled" : "Unable to schedule shutdown"
                    return this.ResultState(success, success ? 0 : 2, message)
                case "power-hibernate":
                    success := LS_PowerManager.Hibernate(cmd["options"])
                    message := success ? "Hibernate scheduled" : "Unable to schedule hibernate"
                    return this.ResultState(success, success ? 0 : 2, message)
                default:
                    return this.ResultState(false, 2, "Unsupported command: " . cmd["name"])
            }
        } catch as e {
            return this.ResultState(false, 2, "Command failed: " . e.Message)
        }
    }

    static ExtractOptions(parsed) {
        opts := Map()
        if (parsed.Has("user") && parsed["user"] != "")
            opts["user"] := parsed["user"]
        if (parsed.Has("reboot")) {
            if (this.ParseBool(parsed["reboot"]))
                opts["reboot"] := true
        }
        timeoutKey := parsed.Has("reboot-timeout") ? "reboot-timeout" : parsed.Has("reboottimeout") ? "reboottimeout" : ""
        if (timeoutKey != "" && parsed[timeoutKey] != "") {
            value := Integer(parsed[timeoutKey])
            if (value >= 0)
                opts["rebootTimeout"] := value
        }
        if (parsed.Has("path") && parsed["path"] != "")
            opts["path"] := parsed["path"]
        if (parsed.Has("timeout") && parsed["timeout"] != "") {
            timeout := parsed["timeout"] + 0
            if (timeout >= 0)
                opts["timeout"] := timeout
        }
        if (parsed.Has("reason") && parsed["reason"] != "")
            opts["reason"] := parsed["reason"]
        if (parsed.Has("delay") && parsed["delay"] != "") {
            delay := parsed["delay"] + 0
            if (delay >= 0)
                opts["delay"] := delay
        }
        if (parsed.Has("force"))
            opts["force"] := this.ParseBool(parsed["force"])
        if (parsed.Has("skip-wake-check"))
            opts["skipWakeCheck"] := this.ParseBool(parsed["skip-wake-check"])
        if (parsed.Has("repair-wake"))
            opts["repairWake"] := this.ParseBool(parsed["repair-wake"])
        if (parsed.Has("require-wake"))
            opts["failOnWakeIssues"] := this.ParseBool(parsed["require-wake"])
        if (parsed.Has("guard"))
            opts["guard"] := this.ParseBool(parsed["guard"])
        if (parsed.Has("guard-grace") && parsed["guard-grace"] != "") {
            grace := parsed["guard-grace"] + 0
            if (grace > 0)
                opts["guardGrace"] := grace
        }
        if (parsed.Has("guard-message") && parsed["guard-message"] != "") {
            opts["guardMessage"] := parsed["guard-message"]
        } else if (parsed.Has("guardmessage") && parsed["guardmessage"] != "") {
            opts["guardMessage"] := parsed["guardmessage"]
        }
        if (parsed.Has("guard-notify"))
            opts["guardNotify"] := this.ParseBool(parsed["guard-notify"])
        if (parsed.Has("grace") && parsed["grace"] != "") {
            grace := parsed["grace"] + 0
            if (grace > 0)
                opts["grace"] := grace
        }
        if (parsed.Has("message") && parsed["message"] != "")
            opts["message"] := parsed["message"]
        if (parsed.Has("notify"))
            opts["notify"] := this.ParseBool(parsed["notify"])
        return opts
    }

    static ParseCommandFile(path) {
        entries := Map()
        text := ""
        try {
            text := FileRead(path, "UTF-8")
        } catch {
            try text := FileRead(path)
        }
        inside := false
        for rawLine in StrSplit(text, "`n") {
            line := Trim(StrReplace(rawLine, "`r"))
            if (line = "" || SubStr(line, 1, 1) = ";" || SubStr(line, 1, 1) = "#")
                continue
            if (SubStr(line, 1, 1) = "[") {
                section := StrLower(SubStr(line, 2, StrLen(line) - 2))
                inside := (section = "command")
                continue
            }
            if (!inside)
                continue
            pos := InStr(line, "=")
            if (!pos)
                continue
            key := StrLower(Trim(SubStr(line, 1, pos - 1)))
            value := Trim(SubStr(line, pos + 1))
            entries[key] := value
        }
        return entries
    }

    static ResultState(success, exitCode, message) {
        return Map("success", success, "exitCode", exitCode, "message", message)
    }

    static WriteResult(cmd, result) {
        payload := Map()
        payload["id"] := cmd["id"]
        payload["command"] := cmd["name"]
        payload["completedAt"] := FormatTime(A_NowUTC, "yyyy-MM-ddTHH:mm:ssZ")
        payload["success"] := result["success"]
        payload["exitCode"] := result["exitCode"]
        payload["message"] := result["message"]
        payload["options"] := cmd["options"]
        payload["metadata"] := cmd["metadata"]
        payload["sourceFile"] := cmd["source"]
        target := LAB_STATION_COMMAND_RESULTS_DIR "\" . this.SanitizeId(cmd["id"]) . ".json"
        try {
            LS_WriteJson(target, payload)
            LS_LogInfo("Command result written: " . target)
        } catch as e {
            LS_LogError("Unable to write command result: " . e.Message)
        }
    }

    static Archive(path, cmdId := "") {
        base := this.GetFileName(path)
        timestamp := FormatTime(A_NowUTC, "yyyyMMddHHmmss")
        suffix := cmdId != "" ? ("-" . this.SanitizeId(cmdId)) : ""
        target := LAB_STATION_COMMAND_PROCESSED_DIR "\" . timestamp . suffix . "-" . base
        try {
            FileMove(path, target, true)
        } catch as e {
            LS_LogWarning("Unable to archive command file: " . e.Message)
            try FileDelete(path)
        }
    }

    static ResolveCommandId(parsed, path) {
        if (parsed.Has("id") && parsed["id"] != "")
            return parsed["id"]
        fileName := this.GetFileName(path)
        return RegExReplace(fileName, "\.ini$", "")
    }

    static GetFileName(path) {
        parts := StrSplit(path, "\\")
        return parts.Length > 0 ? parts[parts.Length] : path
    }

    static SanitizeId(value) {
        sanitized := RegExReplace(value, "[^A-Za-z0-9-_]", "_")
        if (sanitized = "")
            sanitized := FormatTime(A_NowUTC, "yyyyMMddHHmmss")
        return sanitized
    }

    static ParseBool(value) {
        lower := StrLower(Trim(value))
        return (lower = "1" || lower = "true" || lower = "yes" || lower = "on")
    }
}
