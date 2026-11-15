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
    static LastRunWarning := false
    static LastRunRetryable := false
    static LastRunMessage := ""
    static LastRunAcknowledgedSessions := 0
    static LastRunFailureCode := ""

    static Run(options := Map()) {
        this.LastRunWarning := false
        this.LastRunRetryable := false
        this.LastRunMessage := ""
        this.LastRunAcknowledgedSessions := 0
        this.LastRunFailureCode := ""
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
            this.LastRunRetryable := true
            this.LastRunFailureCode := "STATION_SESSION_QUERY_FAILED"
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

        guardStarted := A_TickCount
        guardDeadline := guardStarted + grace * 1000
        if (localOnly) {
            if (!notify) {
                this.LastRunRetryable := true
                this.LastRunMessage := "local-session acknowledgement is required, but the confirmation dialog is disabled; no session was closed. Enable it or use --no-guard as an explicit bypass."
                this.LastRunFailureCode := "STATION_SESSION_ACKNOWLEDGEMENT_REQUIRED"
                LS_LogWarning("Session guard: local-session eviction requires an explicit acknowledgement")
                return false
            }
            for session in targets {
                remainingMs := guardDeadline - A_TickCount
                if (remainingMs <= 0) {
                    try {
                        currentTargets := this.FindConflictingSessions(guardUser, true)
                    } catch as e {
                        this.LastRunRetryable := true
                        this.LastRunMessage := "session inventory unavailable after the confirmation deadline; no session was closed"
                        this.LastRunFailureCode := "STATION_SESSION_QUERY_FAILED"
                        LS_LogWarning("Session guard: unable to recheck local sessions after the confirmation deadline - " . e.Message)
                        return false
                    }
                    if (!this.SameSessionSnapshot(targets, currentTargets)) {
                        this.LastRunRetryable := true
                        this.LastRunMessage := "local sessions changed during confirmation; no session was closed"
                        this.LastRunFailureCode := "STATION_SESSION_CHANGED"
                        LS_LogWarning("Session guard: local sessions changed during confirmation; refusing eviction")
                        return false
                    }
                    if (this.SessionSnapshotContains(currentTargets, session["id"])) {
                        this.LastRunRetryable := true
                        this.LastRunMessage := "local session acknowledgement timed out; no session was closed"
                        this.LastRunFailureCode := "STATION_SESSION_ACKNOWLEDGEMENT_REQUIRED"
                        LS_LogWarning("Session guard: local-session acknowledgement timed out")
                        return false
                    }
                    continue
                }
                if (!this.ConfirmSession(session, message, Ceil(remainingMs / 1000))) {
                    try {
                        currentTargets := this.FindConflictingSessions(guardUser, true)
                    } catch as e {
                        this.LastRunRetryable := true
                        this.LastRunMessage := "session inventory unavailable after the confirmation dialog; no session was closed"
                        this.LastRunFailureCode := "STATION_SESSION_QUERY_FAILED"
                        LS_LogWarning("Session guard: unable to recheck local sessions after confirmation - " . e.Message)
                        return false
                    }
                    if (!this.SameSessionSnapshot(targets, currentTargets)) {
                        this.LastRunRetryable := true
                        this.LastRunMessage := "local sessions changed during confirmation; no session was closed"
                        this.LastRunFailureCode := "STATION_SESSION_CHANGED"
                        LS_LogWarning("Session guard: local sessions changed during confirmation; refusing eviction")
                        return false
                    }
                    if (this.SessionSnapshotContains(currentTargets, session["id"])) {
                        this.LastRunRetryable := true
                        this.LastRunMessage := "local session did not acknowledge the warning; no session was closed"
                        this.LastRunFailureCode := "STATION_SESSION_ACKNOWLEDGEMENT_REQUIRED"
                        LS_LogWarning("Session guard: local-session acknowledgement was declined, timed out, or unavailable")
                        return false
                    }
                    continue
                }
                session["guardAcknowledged"] := true
                this.LastRunAcknowledgedSessions += 1
            }
        } else if (notify) {
            for session in targets {
                if (!this.NotifySession(session, message, grace))
                    this.LastRunWarning := true
            }
        }

        LS_LogInfo(Format("Session guard: waiting {1} seconds before forced logoff", grace))
        remainingGrace := localOnly ? Max(0, Ceil((guardDeadline - A_TickCount) / 1000)) : grace
        if (remainingGrace > 0)
            this.WaitForGrace(remainingGrace)
        if (options.Has("abortOnLocalMode") && options["abortOnLocalMode"] && LS_Status.IsLocalModeEnabled()) {
            LS_LogInfo("Session guard: local mode became active during grace period; no sessions were evicted")
            this.LastRunRetryable := true
            this.LastRunFailureCode := "STATION_LOCAL_MODE_ACTIVE"
            return false
        }
        if (localOnly) {
            try {
                currentTargets := this.FindConflictingSessions(guardUser, true)
            } catch as e {
                LS_LogWarning("Session guard: unable to recheck local sessions - " . e.Message)
                this.LastRunRetryable := true
                this.LastRunFailureCode := "STATION_SESSION_QUERY_FAILED"
                return false
            }
            if (!this.SameSessionSnapshot(targets, currentTargets)) {
                LS_LogInfo("Session guard: local sessions changed during grace period; no sessions were evicted")
                this.LastRunRetryable := true
                this.LastRunFailureCode := "STATION_SESSION_CHANGED"
                return false
            }
        }

        result := true
        releaseStarted := false
        releaseTargets := localOnly ? currentTargets : targets
        for session in releaseTargets {
            if (options.Has("abortOnLocalMode") && options["abortOnLocalMode"] && LS_Status.IsLocalModeEnabled()) {
                LS_LogInfo("Session guard: local mode became active during session release")
                this.LastRunRetryable := !releaseStarted
                return false
            }
            releaseStarted := true
            this.LastRunRetryable := false
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
            if (localOnly) {
                if (!LS_Status.IsPrepareLocalSession(session))
                    continue
            } else {
                if (this.EqualsUser(session["user"], guardUser))
                    continue
                state := StrLower(session["state"])
                if (state = "disc" || state = "down" || (state = "" && session["user"] = ""))
                    continue
            }
            targets.Push(session)
        }
        return targets
    }

    static SameSessionSnapshot(before, after) {
        if (after.Length > before.Length)
            return false
        originalById := Map()
        for session in before {
            id := session["id"]
            if (originalById.Has(id))
                return false
            originalById[id] := session
        }
        currentById := Map()
        for session in after {
            id := session["id"]
            if (currentById.Has(id) || !originalById.Has(id))
                return false
            currentById[id] := session
        }
        for id, current in currentById {
            original := originalById[id]
            if (!this.EqualsUser(current["user"], original["user"])
                || StrLower(current["session"]) != StrLower(original["session"])
                || StrLower(current["state"]) != StrLower(original["state"]))
                return false
        }
        return true
    }

    static SessionSnapshotContains(sessions, sessionId) {
        for session in sessions {
            if (session["id"] = sessionId)
                return true
        }
        return false
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
            return false
        }
        cmd := Format('msg {1} /time:{2} "{3}"', sessionId, timeout, text)
        return LS_RunCommand(cmd, "Notify session " . session["id"]) = 0
    }

    static ConfirmSession(session, message, timeout) {
        sessionId := session["id"]
        if (!RegExMatch(sessionId, "^\d+$") || timeout < 1)
            return false
        title := "Lab Station reservation"
        body := message . "`n`nSave your work, then choose Yes to allow your session to close after the grace period. Choose No or leave unanswered to keep your session open and cancel Prepare."
        response := 0
        try {
            shown := DllCall("Wtsapi32\WTSSendMessageW",
                "Ptr", 0,
                "UInt", sessionId + 0,
                "Str", title,
                "UInt", StrLen(title) * 2,
                "Str", body,
                "UInt", StrLen(body) * 2,
                "UInt", 0x00050034,
                "UInt", timeout,
                "UInt*", &response,
                "Int", 1,
                "Int")
        } catch as e {
            LS_LogWarning("Session guard: could not display a confirmation dialog for session " . sessionId . " - " . e.Message)
            return false
        }
        return shown && response = 6
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
        if (session.Has("guardAcknowledged"))
            event["acknowledged"] := session["guardAcknowledged"]
        if (session.Has("guardBypassed"))
            event["guardBypassed"] := session["guardBypassed"]
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
