; ============================================================================
; Lab Station - Session guard helpers
; ============================================================================
#Requires AutoHotkey v2.0
#Include ..\core\Config.ahk
#Include ..\core\Logger.ahk
#Include ..\core\Shell.ahk
#Include ..\core\Json.ahk
#Include ..\system\AccountManager.ahk
#Include ServiceState.ahk

class LS_SessionGuard {
    static Run(options := Map()) {
        guardUser := options.Has("user") ? options["user"] : LS_AccountManager.DefaultUser
        grace := options.Has("grace") ? (options["grace"] + 0) : 120
        grace := grace < 30 ? 30 : grace
        notify := !options.Has("notify") || options["notify"]
        force := !options.Has("force") || options["force"]
        message := options.Has("message") && options["message"] != "" ? options["message"] : this.BuildDefaultMessage(grace)

        sessions := this.QuerySessions()
        targets := []
        for session in sessions {
            if (this.EqualsUser(session["user"], guardUser))
                continue
            state := StrLower(session["state"])
            if (state = "disc" || state = "down" || (state = "" && session["user"] = ""))
                continue
            session["guardGrace"] := grace
            session["force"] := force
            session["guardMessage"] := message
            targets.Push(session)
        }

        if (targets.Length = 0) {
            LS_LogInfo("Session guard: no conflicting local users found")
            return true
        }

        if (notify) {
            for session in targets {
                this.NotifySession(session, message, grace)
            }
        }

        LS_LogInfo(Format("Session guard: waiting {1} seconds before forced logoff", grace))
        Sleep grace * 1000

        result := true
        for session in targets {
            if (!this.LogoffSession(session, force))
                result := false
        }
        return result
    }

    static QuerySessions() {
        capture := LS_RunCommandCapture("quser", "Enumerate sessions")
        if (capture["exitCode"] != 0) {
            LS_LogWarning("Session guard: unable to read sessions (exit=" . capture["exitCode"] . ")")
            return []
        }
        entries := []
        for rawLine in StrSplit(capture["stdout"], "`n") {
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
            entry["session"] := Trim(parts[2])
            entry["id"] := parts.Length >= 3 ? Trim(parts[3]) : ""
            entry["state"] := parts.Length >= 4 ? Trim(parts[4]) : ""
            entry["idle"] := parts.Length >= 5 ? Trim(parts[5]) : ""
            entries.Push(entry)
        }
        return entries
    }

    static NotifySession(session, message, timeout) {
        text := StrReplace(message, '"', "'")
        sessionId := session["id"]
        if (!sessionId || sessionId = "") {
            LS_LogWarning("Session guard: unable to notify session with empty ID")
            return
        }
        cmd := Format('msg {1} /time:{2} "{3}"', sessionId, timeout, text)
        LS_RunCommand(cmd, "Notify session " . session["id"])
    }

    static LogoffSession(session, force := true) {
        sessionId := session["id"]
        if (!sessionId || sessionId = "") {
            LS_LogWarning("Session guard: cannot logoff session with empty ID")
            return false
        }
        flag := force ? "/f" : ""
        cmd := Format('logoff {1} {2}', sessionId, flag)
        exitCode := LS_RunCommand(cmd, "Logoff session " . sessionId)
        if (exitCode != 0) {
            LS_LogWarning("Session guard: unable to logoff session " . sessionId . " (exit=" . exitCode . ")")
            return false
        }
        this.RecordLogoffAudit(session, force)
        return true
    }

    static RecordLogoffAudit(session, force) {
        event := Map()
        event["timestamp"] := FormatTime(A_NowUTC, "yyyy-MM-ddTHH:mm:ssZ")
        event["user"] := session["user"]
        event["sessionId"] := session["id"]
        event["state"] := session["state"]
        event["force"] := force
        if (session.Has("guardGrace"))
            event["grace"] := session["guardGrace"]
        if (session.Has("guardMessage"))
            event["message"] := session["guardMessage"]
        event["source"] := "session-guard"
        LS_ServiceState.RecordForcedLogoff(event)
        this.AppendAuditEvent(event)
    }

    static AppendAuditEvent(event) {
        payload := LS_ToJson(event)
        try {
            FileAppend(payload . "`n", LAB_STATION_SESSION_AUDIT_FILE, "UTF-8")
        } catch as e {
            LS_LogWarning("Session guard: unable to append audit event - " . e.Message)
        }
    }

    static BuildDefaultMessage(grace) {
        return Format("A remote lab reservation is about to start. Your session will close in {1} seconds.", grace)
    }

    static EqualsUser(candidate, target) {
        return this.NormalizeUser(candidate) = this.NormalizeUser(target)
    }

    static NormalizeUser(value) {
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
}
