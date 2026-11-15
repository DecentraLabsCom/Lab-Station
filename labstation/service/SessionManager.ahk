; ============================================================================
; Lab Station - Session preparation and cleanup
; ============================================================================
#Requires AutoHotkey v2.0
#Include ..\core\Config.ahk
#Include ..\core\Logger.ahk
#Include ..\core\Admin.ahk
#Include ..\core\Shell.ahk
#Include ..\system\AccountManager.ahk
#Include ServiceState.ahk
#Include ..\diagnostics\Status.ahk
#Include SessionGuard.ahk
#Include FmuExecutor.ahk

class LS_SessionManager {
    static ManualPrepareRemoteSessionMessage := "Manual Prepare deletes LABUSER temporary files, Downloads, and lab scratch data and may interrupt open apps. An active remote LABUSER session was detected, so no cleanup ran. Run Release or log off the session before retrying."
    static LastPrepareExitCode := 0
    static LastPrepareRetryable := false
    static LastPrepareMessage := ""
    static LastPrepareMetadata := Map()
    static LastReleaseExitCode := 0
    static LastReleaseRetryable := false
    static LastReleaseMessage := ""
    static LastReleaseMetadata := Map()
    static LastReleaseSessionCount := 0

    static PrepareSession(options := Map(), manualMaintenance := false) {
        this.LastPrepareExitCode := 0
        this.LastPrepareRetryable := false
        this.LastPrepareMessage := "station prepared"
        this.LastPrepareMetadata := Map()
        LS_LogInfo("Prepare-session started")
        started := A_TickCount
        user := options.Has("user") ? options["user"] : ""
        managedUser := user != "" ? user : LS_AccountManager.DefaultUser
        if (LS_Status.IsLocalModeEnabled())
            return this.RecordPrepareFailure(started, user, "local mode is active", true)

        if (manualMaintenance) {
            try {
                remoteLabUserSessions := this.GetPrepareRemoteLabUserSessions(managedUser)
            } catch as e {
                return this.RecordPrepareFailure(started, user,
                    "session inventory unavailable; no cleanup ran: " . e.Message,
                    true, "STATION_SESSION_QUERY_FAILED")
            }
            if (remoteLabUserSessions.Length > 0)
                return this.RecordPrepareFailure(started, user, this.ManualPrepareRemoteSessionMessage,
                    true, "STATION_REMOTE_SESSION_ACTIVE")
        }

        try {
            localSessions := this.GetPrepareLocalSessions(managedUser)
        } catch as e {
            return this.RecordPrepareFailure(started, user, "session inventory unavailable: " . e.Message, true)
        }

        profile := LS_Status.GetStationProfile()
        allowEviction := localSessions.Length > 0 && LS_Status.IsLocalSessionEvictionAllowed()
        localSessionDecision := this.PrepareLocalSessionDecision(profile, localSessions.Length, allowEviction)
        if (localSessionDecision = "refuse") {
            reason := profile = "hybrid"
                ? "local session is active and local-session eviction is disabled"
                : "unexpected local interactive session on dedicated station"
            return this.RecordPrepareFailure(started, user, reason, true)
        }
        if (localSessionDecision = "evict") {
            if (options.Has("guard") && !options["guard"]) {
                try {
                    currentLocalSessions := this.GetPrepareLocalSessions(managedUser)
                } catch as e {
                    return this.RecordPrepareFailure(started, user, "session inventory unavailable before immediate eviction: " . e.Message, true)
                }
                if (!LS_SessionGuard.SameSessionSnapshot(localSessions, currentLocalSessions))
                    return this.RecordPrepareFailure(started, user, "local sessions changed before immediate eviction", true)
                releaseStarted := false
                for session in currentLocalSessions {
                    if (LS_Status.IsLocalModeEnabled())
                        return this.RecordPrepareFailure(started, user, "local mode became active during session release", !releaseStarted)
                    releaseStarted := true
                    session["guardBypassed"] := true
                    if (!LS_SessionGuard.LogoffSession(session))
                        return this.RecordPrepareFailure(started, user, "unable to evict local interactive session")
                }
            } else if (!this.RunSessionGuard(options, true)) {
                message := this.LastPrepareMessage != "" ? this.LastPrepareMessage : "session guard failed"
                code := LS_SessionGuard.LastRunFailureCode
                if (code = "")
                    code := this.LastPrepareMetadata.Has("code") ? this.LastPrepareMetadata["code"] : ""
                result := this.RecordPrepareFailure(started, user, message, LS_SessionGuard.LastRunRetryable, code)
                if (code = "STATION_SESSION_ACKNOWLEDGEMENT_REQUIRED")
                    this.LastPrepareMetadata["acknowledgedSessions"] := LS_SessionGuard.LastRunAcknowledgedSessions
                return result
            }
        }
        try {
            if (this.GetPrepareLocalSessions(managedUser).Length > 0)
                return this.RecordPrepareFailure(started, user, "local interactive session became active or remained active during preparation")
        } catch as e {
            return this.RecordPrepareFailure(started, user, "session inventory unavailable after guard: " . e.Message)
        }
        if (LS_Status.IsLocalModeEnabled())
            return this.RecordPrepareFailure(started, user, "local mode became active during preparation")

        if (manualMaintenance) {
            try {
                remoteLabUserSessions := this.GetPrepareRemoteLabUserSessions(managedUser)
            } catch as e {
                return this.RecordPrepareFailure(started, user,
                    "session inventory unavailable before cleanup; no cleanup ran: " . e.Message,
                    true, "STATION_SESSION_QUERY_FAILED")
            }
            if (remoteLabUserSessions.Length > 0)
                return this.RecordPrepareFailure(started, user, this.ManualPrepareRemoteSessionMessage,
                    true, "STATION_REMOTE_SESSION_ACTIVE")
        }

        ok := true
        ok := this.CloseControllerProcesses() && ok
        ok := this.CleanFmuExecutorState() && ok
        ok := this.ClearLabUserWorkingDirs(user) && ok
        ok := this.ResetControllerLogs() && ok
        if (options.Has("extraCleaners")) {
            for cleaner in options["extraCleaners"] {
                try {
                    if (!cleaner.Call()) {
                        ok := false
                    }
                } catch as e {
                    LS_LogError("Extra cleaner failed: " . e.Message)
                    ok := false
                }
            }
        }
        details := Map("durationMs", A_TickCount - started, "user", user)
        if (ok) {
            LS_LogInfo("Prepare-session completed")
        } else {
            this.LastPrepareExitCode := 2
            this.LastPrepareMessage := "station preparation requires recovery because cleanup was incomplete"
            this.LastPrepareMetadata := Map(
                "code", "STATION_PREPARE_CLEANUP_FAILED",
                "cleanupWarnings", ["one or more cleanup actions failed"]
            )
            LS_LogWarning("Prepare-session failed because cleanup was incomplete")
            details["reason"] := "one or more cleanup actions failed"
        }
        LS_ServiceState.RecordPrepareSession(ok, details)
        return ok
    }

    static GetPrepareLocalSessions(managedUser) {
        return LS_SessionGuard.FindConflictingSessions(managedUser, true)
    }

    static GetPrepareRemoteLabUserSessions(managedUser) {
        return this.GetRemoteLabUserSessions(this.GetReleaseSessionInventory(), managedUser)
    }

    static PrepareLocalSessionDecision(profile, localSessionCount, allowEviction) {
        if (localSessionCount <= 0)
            return "continue"
        if (profile = "hybrid" && allowEviction)
            return "evict"
        return "refuse"
    }

    static RecordPrepareFailure(started, user, reason, retryable := false, code := "") {
        this.LastPrepareExitCode := 2
        this.LastPrepareRetryable := retryable
        this.LastPrepareMessage := reason
        this.LastPrepareMetadata := Map("reason", reason, "retryable", retryable)
        if (code != "")
            this.LastPrepareMetadata["code"] := code
        if (code = "STATION_REMOTE_SESSION_ACTIVE" || code = "STATION_SESSION_QUERY_FAILED"
            || code = "STATION_SESSION_ACKNOWLEDGEMENT_REQUIRED")
            this.LastPrepareMetadata["cleanupSkipped"] := true
        LS_LogWarning("Prepare-session refused: " . reason)
        LS_ServiceState.RecordPrepareSession(false, Map(
            "durationMs", A_TickCount - started,
            "user", user,
            "reason", reason
        ))
        return false
    }

    static RunSessionGuard(options, localOnly := false) {
        guardEnabled := true
        if (options.Has("guard"))
            guardEnabled := options["guard"]
        if (!guardEnabled)
            return true
        guardOpts := Map()
        guardOpts["user"] := options.Has("user") ? options["user"] : LS_AccountManager.DefaultUser
        guardOpts["grace"] := options.Has("guardGrace") ? options["guardGrace"] : 90
        if (options.Has("guardMessage"))
            guardOpts["message"] := options["guardMessage"]
        if (options.Has("guardNotify"))
            guardOpts["notify"] := options["guardNotify"]
        guardOpts["localOnly"] := localOnly
        guardOpts["abortOnLocalMode"] := localOnly
        result := LS_SessionGuard.Run(guardOpts)
        if (!result && localOnly && LS_SessionGuard.LastRunRetryable) {
            this.LastPrepareExitCode := 2
            this.LastPrepareRetryable := true
            this.LastPrepareMessage := LS_SessionGuard.LastRunMessage != "" ? LS_SessionGuard.LastRunMessage : "session guard failed before eviction"
            failureCode := LS_SessionGuard.LastRunFailureCode != "" ? LS_SessionGuard.LastRunFailureCode : "STATION_SESSION_CHANGED"
            this.LastPrepareMetadata := Map("code", failureCode, "retryable", true)
            return false
        }
        return result
    }

    static ReleaseSession(options := Map()) {
        this.LastReleaseExitCode := 0
        this.LastReleaseRetryable := false
        this.LastReleaseMessage := "station released"
        this.LastReleaseMetadata := Map()
        this.LastReleaseSessionCount := 0
        LS_LogInfo("Release-session started")
        started := A_TickCount
        user := options.Has("user") ? options["user"] : ""
        remoteSessionReleased := this.LogoffRemoteLabUser(user)
        fmuCleanupAttempted := false
        fmuCleanupCompleted := false
        ok := remoteSessionReleased
        if (!remoteSessionReleased) {
            this.LastReleaseExitCode := 2
            this.LastReleaseMessage := "Release-session failed because a remote LABUSER session could not be released"
        } else {
            fmuCleanupAttempted := true
            fmuCleanupCompleted := this.CleanFmuExecutorState()
            if (!fmuCleanupCompleted) {
                ok := false
                this.LastReleaseExitCode := 2
                this.LastReleaseMessage := "Release-session failed because FMU Executor sessions or temporary state could not be fully cleaned"
            }
        }
        rebootScheduled := false
        rebootDeferred := false
        rebootReason := ""
        rebootTimeout := options.Has("rebootTimeout") ? options["rebootTimeout"] : 0
        if (options.Has("reboot") && options["reboot"]) {
            if (!ok) {
                rebootDeferred := true
                rebootReason := remoteSessionReleased ? "FMU Executor cleanup failed" : "remote session release failed"
                this.LastReleaseExitCode := 2
            } else if (rebootTimeout < 0 || rebootTimeout > 3600) {
                rebootDeferred := true
                rebootReason := "reboot timeout must be between 0 and 3600 seconds"
                this.LastReleaseExitCode := 1
                LS_LogWarning("Release-session reboot deferred: " . rebootReason)
            } else {
                rebootSafety := this.WaitForSafeReboot(user, rebootTimeout)
                if (!rebootSafety["safe"]) {
                    rebootDeferred := true
                    rebootReason := rebootSafety["reason"]
                    this.LastReleaseExitCode := 1
                    LS_LogWarning("Release-session reboot deferred: " . rebootReason)
                } else if (this.TriggerReboot(0)) {
                    rebootScheduled := true
                } else {
                    this.LastReleaseExitCode := 1
                    rebootDeferred := true
                    rebootReason := "reboot request failed"
                }
            }
        }
        if (ok) {
            LS_LogInfo("Release-session completed")
        } else {
            LS_LogWarning("Release-session finished with warnings")
        }
        details := Map(
            "durationMs", A_TickCount - started,
            "user", user,
            "fmuCleanupAttempted", fmuCleanupAttempted,
            "fmuCleanupCompleted", fmuCleanupCompleted,
            "retryable", this.LastReleaseRetryable
        )
        if (options.Has("reboot")) {
            details["rebootRequested"] := options["reboot"]
            details["rebootScheduled"] := rebootScheduled
            details["rebootDeferred"] := rebootDeferred
            if (rebootReason != "")
                details["rebootReason"] := rebootReason
        }
        if (options.Has("rebootTimeout") || options.Has("reboot"))
            details["rebootTimeout"] := rebootTimeout
        this.LastReleaseMetadata := Map(
            "closedLabuserSessions", this.LastReleaseSessionCount,
            "fmuCleanupAttempted", fmuCleanupAttempted,
            "fmuCleanupCompleted", fmuCleanupCompleted,
            "retryable", this.LastReleaseRetryable
        )
        this.LastReleaseMetadata["rebootRequested"] := options.Has("reboot") && options["reboot"]
        this.LastReleaseMetadata["rebootScheduled"] := rebootScheduled
        this.LastReleaseMetadata["rebootDeferred"] := rebootDeferred
        if (rebootReason != "")
            this.LastReleaseMetadata["rebootReason"] := rebootReason
        if (options.Has("rebootTimeout") || options.Has("reboot"))
            this.LastReleaseMetadata["rebootTimeout"] := rebootTimeout
        if (ok) {
            if (rebootDeferred || this.LastReleaseExitCode = 1)
                this.LastReleaseMessage := "station released with warnings"
            else
                this.LastReleaseMessage := "station released"
        }
        LS_ServiceState.RecordReleaseSession(ok, details)
        return ok
    }

    static WaitForSafeReboot(user, timeout) {
        started := A_TickCount
        Loop {
            try {
                sessions := this.GetReleaseSessionInventory()
            } catch as e {
                LS_LogWarning("Release-session cannot verify users before reboot: " . e.Message)
                return Map("safe", false, "reason", "session inventory unavailable")
            }

            localSessions := this.GetActiveConsoleSessions(sessions)
            remoteLabUserSessions := this.GetRemoteLabUserSessions(sessions, user)
            if (localSessions.Length = 0 && remoteLabUserSessions.Length = 0)
                return Map("safe", true, "reason", "")

            elapsed := A_TickCount - started
            if (timeout <= 0 || elapsed >= timeout * 1000) {
                reason := localSessions.Length > 0 ? "physical console session remains active"
                    : "remote LABUSER session is still active"
                return Map("safe", false, "reason", reason)
            }
            Sleep(1000)
        }
    }

    static GetReleaseSessionInventory() {
        return LS_SessionGuard.QuerySessions()
    }

    static GetActiveConsoleSessions(sessions) {
        result := []
        for session in sessions {
            if (!session.Has("session") || StrLower(Trim(session["session"])) != "console")
                continue
            state := session.Has("state") ? StrLower(Trim(session["state"])) : ""
            if (state = "disc" || state = "down" || (state = "" && (!session.Has("user") || session["user"] = "")))
                continue
            result.Push(session)
        }
        return result
    }

    static GetRemoteLabUserSessions(sessions, user := "") {
        if (user = "")
            user := LS_AccountManager.DefaultUser
        result := []
        for session in sessions {
            if (!session.Has("user") || !session.Has("session"))
                continue
            if (LS_SessionGuard.EqualsUser(session["user"], user) && this.IsRemoteSessionName(session["session"]))
                result.Push(session)
        }
        return result
    }

    static IsRemoteSessionName(sessionName) {
        return RegExMatch(Trim(sessionName), "i)^\*?rdp-tcp#\d+$")
    }

    static CloseControllerProcesses() {
        presence := this.ReadControllerPresence()
        if (presence.Has("stale") && presence["stale"]) {
            LS_LogWarning("AppControl presence marker is stale or invalid; refusing to force-close an unknown process")
            return false
        }
        if (!presence["present"]) {
            if (ProcessExist("AppControl.exe")) {
                LS_LogWarning("AppControl is running without cooperative-close support")
                return false
            }
            return true
        }

        try FileDelete(LAB_STATION_CONTROLLER_CLOSE_REQUEST_FILE)
        try FileDelete(LAB_STATION_CONTROLLER_CLOSE_RESULT_FILE)

        token := A_TickCount . "-" . FormatTime(A_Now, "yyyyMMddHHmmss") . "-" . Random(1000, 9999)
        if (!this.WriteControllerHandshake(LAB_STATION_CONTROLLER_CLOSE_REQUEST_FILE, token)) {
            LS_LogWarning("Unable to request cooperative AppControl close")
            return false
        }

        deadline := A_TickCount + LAB_STATION_CONTROLLER_CLOSE_TIMEOUT_MS
        while (A_TickCount < deadline) {
            if (FileExist(LAB_STATION_CONTROLLER_CLOSE_RESULT_FILE)) {
                try {
                    resultText := Trim(FileRead(LAB_STATION_CONTROLLER_CLOSE_RESULT_FILE, "UTF-8"))
                } catch {
                    resultText := ""
                }
                if (this.CloseResultMatches(resultText, token, "ok")) {
                    try FileDelete(LAB_STATION_CONTROLLER_CLOSE_REQUEST_FILE)
                    try FileDelete(LAB_STATION_CONTROLLER_CLOSE_RESULT_FILE)
                    if (this.WaitForControllerPresenceToClear(deadline))
                        return true
                    LS_LogWarning("AppControl acknowledged close but remained active")
                    return false
                }
                if (this.CloseResultMatches(resultText, token, "failed")) {
                    try FileDelete(LAB_STATION_CONTROLLER_CLOSE_REQUEST_FILE)
                    try FileDelete(LAB_STATION_CONTROLLER_CLOSE_RESULT_FILE)
                    LS_LogWarning("AppControl could not close the controlled lab application")
                    return false
                }
            }
            Sleep(100)
        }

        try FileDelete(LAB_STATION_CONTROLLER_CLOSE_REQUEST_FILE)
        try FileDelete(LAB_STATION_CONTROLLER_CLOSE_RESULT_FILE)
        LS_LogWarning("Timed out waiting for cooperative AppControl close")
        return false
    }

    static ReadControllerPresence() {
        result := Map("present", false, "pid", 0, "stale", false)
        if (!FileExist(LAB_STATION_CONTROLLER_PRESENCE_FILE))
            return result

        try {
            content := Trim(FileRead(LAB_STATION_CONTROLLER_PRESENCE_FILE, "UTF-8"))
        } catch {
            content := ""
        }
        if (!RegExMatch(content, "^(\d+)\|(\d+)$", &marker)) {
            LS_LogWarning("Invalid AppControl presence marker")
            result["stale"] := true
            try FileDelete(LAB_STATION_CONTROLLER_PRESENCE_FILE)
            return result
        }

        pid := marker[1] + 0
        result["pid"] := pid
        if (pid && ProcessExist(pid)) {
            result["present"] := true
            return result
        }

        LS_LogWarning("Stale AppControl presence marker found")
        try FileDelete(LAB_STATION_CONTROLLER_PRESENCE_FILE)
        result["stale"] := true
        return result
    }

    static WriteControllerHandshake(path, token) {
        tempPath := path . ".tmp-" . A_TickCount
        try {
            FileDelete(tempPath)
            FileAppend(token, tempPath, "UTF-8")
            FileMove(tempPath, path, 1)
            return true
        } catch as e {
            try FileDelete(tempPath)
            LS_LogWarning("Unable to write controller handshake: " . e.Message)
            return false
        }
    }

    static WaitForControllerPresenceToClear(deadline) {
        while (A_TickCount < deadline) {
            if (!FileExist(LAB_STATION_CONTROLLER_PRESENCE_FILE))
                return true
            Sleep(100)
        }
        return false
    }

    static CloseResultMatches(resultText, token, status) {
        return Trim(resultText) = token . "|" . status
    }

    static ClearLabUserWorkingDirs(user := "") {
        if (!user || user = "") {
            user := LS_AccountManager.DefaultUser
        }
        profile := this.GetUserProfilePath(user)
        if (profile = "") {
            LS_LogWarning("User profile not found for " . user)
            return false
        }
        targets := [
            profile "\AppData\Local\Temp",
            profile "\AppData\Local\Microsoft\Windows\INetCache",
            profile "\AppData\Roaming\Microsoft\Windows\Recent",
            profile "\Downloads",
            profile "\Documents\LabStationScratch"
        ]
        result := true
        for path in targets {
            if (!this.CleanDirectory(path)) {
                result := false
            }
        }
        return result
    }

    static ResetControllerLogs() {
        logPath := LAB_STATION_REMOTE_APP_DIR "\AppControl.log"
        try {
            if (FileExist(logPath)) {
                FileDelete(logPath)
                LS_LogInfo("Controller log reset")
            }
            return true
        } catch as e {
            LS_LogWarning("Unable to reset controller log: " . e.Message)
            return false
        }
    }

    static CleanFmuExecutorState() {
        try {
            if (!LS_FmuExecutor.TerminateAllSessions())
                throw Error("FMU Executor sessions could not be terminated")
            if (!LS_FmuExecutor.CleanTempState())
                throw Error("FMU Executor temporary state could not be cleaned")
            LS_LogInfo("FMU executor state cleaned")
            return true
        } catch as e {
            LS_LogWarning("Unable to clean FMU executor state: " . e.Message)
            return false
        }
    }

    static CleanDirectory(path) {
        if (!DirExist(path)) {
            return true
        }
        sanitized := StrReplace(path, "'", "''")
        script := "
        (
`$Path = '__PATH__'
if (Test-Path `$Path) {
    Get-ChildItem -Path `$Path -Force -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
}
        )"
        script := StrReplace(script, "__PATH__", sanitized)
        exitCode := LS_RunPowerShell(script, "Clean " . path)
        if (exitCode != 0) {
            LS_LogWarning(Format("Unable to clean {1} (exit={2})", path, exitCode))
            return false
        }
        return true
    }

    static GetUserProfilePath(user) {
        profile := "C:\Users\" . user
        if (DirExist(profile)) {
            return profile
        }
        filterUser := StrReplace(user, "'", "''")
        script := Format("
        (
`$u = '{1}'
`$p = Get-CimInstance -ClassName Win32_UserProfile | Where-Object {{ `$_.LocalPath -like '*\{1}' -and -not `$_.Special }} | Select-Object -First 1
if (`$p) {{ `$p.LocalPath }}
        )", filterUser)
        capture := LS_RunPowerShellCapture(script, "Lookup user profile")
        if (capture["exitCode"] = 0) {
            text := Trim(capture["stdout"])
            if (text != "") {
                return text
            }
        }
        return ""
    }

    static LogoffRemoteLabUser(user := "") {
        this.LastReleaseSessionCount := 0
        if (user = "")
            user := LS_AccountManager.DefaultUser
        try {
            sessions := this.GetReleaseSessionInventory()
        } catch as e {
            LS_LogWarning("Unable to query active sessions: " . e.Message)
            this.LastReleaseExitCode := 2
            this.LastReleaseRetryable := true
            return false
        }

        targets := this.GetRemoteLabUserSessions(sessions, user)
        if (targets.Length = 0) {
            LS_LogInfo("NO_ACTIVE_SESSION: release already satisfied; no remote session found for " . user)
            return true
        }

        ok := true
        for session in targets {
            if (!this.LogoffRemoteSession(session)) {
                ok := false
            } else {
                this.LastReleaseSessionCount += 1
            }
        }
        if (!ok)
            this.LastReleaseExitCode := 2
        return ok
    }

    static LogoffRemoteSession(session) {
        sessionId := session.Has("id") ? Trim(session["id"]) : ""
        if (!RegExMatch(sessionId, "^\d+$")) {
            LS_LogWarning("Unable to log off active session for " . session["user"] . ": invalid session ID")
            return false
        }
        exitCode := LS_RunCommand(Format("logoff {1}", sessionId), "Logoff remote LABUSER session " . sessionId)
        if (exitCode != 0) {
            LS_LogWarning("Unable to log off active session for " . session["user"] . " (exit=" . exitCode . ")")
            return false
        }
        LS_LogInfo("Remote LABUSER session " . sessionId . " logged off")
        return true
    }

    static TriggerReboot(timeout := 0) {
        cmd := Format('shutdown /r /t {1} /f', timeout)
        exitCode := LS_RunCommand(cmd, "Reboot host")
        if (exitCode != 0) {
            LS_LogWarning("Unable to schedule reboot (exit=" . exitCode . ")")
            return false
        }
        return true
    }
}
