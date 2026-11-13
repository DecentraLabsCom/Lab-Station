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
#Include ..\diagnostics\Status.ahk

class LS_SessionGuard {
    static Run(options := Map()) {
        guardUser := options.Has("user") ? options["user"] : LS_AccountManager.DefaultUser
        grace := options.Has("grace") ? (options["grace"] + 0) : 120
        grace := grace < 30 ? 30 : grace
        notify := !options.Has("notify") || options["notify"]
        force := !options.Has("force") || options["force"]
        localOnly := options.Has("localOnly") && options["localOnly"]
        message := options.Has("message") && options["message"] != "" ? options["message"] : this.BuildDefaultMessage(grace)

        try {
            targets := this.FindConflictingSessions(guardUser, localOnly)
        } catch as e {
            LS_LogWarning("Session guard: unable to read sessions - " . e.Message)
            return false
        }
        for session in targets {
            session["guardGrace"] := grace
            session["force"] := force
            session["guardMessage"] := message
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
        this.WaitForGrace(grace)
        if (options.Has("abortOnLocalMode") && options["abortOnLocalMode"] && LS_Status.IsLocalModeEnabled()) {
            LS_LogInfo("Session guard: local mode became active during grace period; no sessions were evicted")
            return false
        }
        if (localOnly) {
            try {
                currentTargets := this.FindConflictingSessions(guardUser, true)
            } catch as e {
                LS_LogWarning("Session guard: unable to recheck local sessions - " . e.Message)
                return false
            }
            if (!this.SameSessionSnapshot(targets, currentTargets)) {
                LS_LogInfo("Session guard: local sessions changed during grace period; no sessions were evicted")
                return false
            }
        }

        result := true
        for session in targets {
            if (options.Has("abortOnLocalMode") && options["abortOnLocalMode"] && LS_Status.IsLocalModeEnabled()) {
                LS_LogInfo("Session guard: local mode became active during session release")
                return false
            }
            if (!this.LogoffSession(session, force))
                result := false
        }
        return result
    }

    static FindConflictingSessions(guardUser := "", localOnly := false) {
        guardUser := guardUser != "" ? guardUser : LS_AccountManager.DefaultUser
        targets := []
        for session in this.QuerySessions() {
            ; Prepare considers every physical-console session, including one
            ; signed in as LABUSER. The managed account exemption applies only
            ; to the general guard, where its remote lab session is expected.
            if (!localOnly && this.EqualsUser(session["user"], guardUser))
                continue
            state := StrLower(session["state"])
            if (state = "disc" || state = "down" || (state = "" && session["user"] = ""))
                continue
            if (localOnly && StrLower(Trim(session["session"])) != "console")
                continue
            targets.Push(session)
        }
        return targets
    }

    static SameSessionSnapshot(before, after) {
        if (before.Length != after.Length)
            return false
        currentById := Map()
        for session in after
            currentById[session["id"]] := session
        for session in before {
            id := session["id"]
            if (!currentById.Has(id))
                return false
            current := currentById[id]
            if (!this.EqualsUser(current["user"], session["user"])
                || StrLower(current["session"]) != StrLower(session["session"])
                || StrLower(current["state"]) != StrLower(session["state"]))
                return false
        }
        return true
    }

    static WaitForGrace(seconds) {
        Sleep seconds * 1000
    }

    static QuerySessions() {
        capture := LS_RunCommandCapture("quser", "Enumerate sessions")
        if (capture["exitCode"] != 0) {
            throw Error("Unable to read sessions (exit=" . capture["exitCode"] . ")")
        }
        return this.ParseSessionOutput(capture["stdout"])
    }

    static ParseSessionOutput(output) {
        entries := []
        for rawLine in StrSplit(output, "`n") {
            line := Trim(StrReplace(rawLine, "`r"))
            if (line = "")
                continue
            if (SubStr(line, 1, 1) = ">")
                line := Trim(SubStr(line, 2))
            normalized := RegExReplace(line, "\s{2,}", "|")
            parts := StrSplit(normalized, "|")
            if (parts.Length < 4)
                continue
            candidateId := parts.Length >= 3 ? Trim(parts[3]) : ""
            if (!RegExMatch(candidateId, "^\d+$"))
                continue
            entry := Map()
            entry["user"] := Trim(parts[1])
            entry["session"] := Trim(parts[2])
            entry["id"] := candidateId
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
        cmd := Format('logoff {1}', sessionId)
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
        lastSlash := InStr(cleaned, "\", , -1)
        if (lastSlash > 0)
            cleaned := SubStr(cleaned, lastSlash + 1)
        return cleaned
    }
}
