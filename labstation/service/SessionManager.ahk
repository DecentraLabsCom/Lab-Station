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
    static LastPrepareExitCode := 0

    static PrepareSession(options := Map()) {
        this.LastPrepareExitCode := 0
        LS_LogInfo("Prepare-session started")
        started := A_TickCount
        user := options.Has("user") ? options["user"] : ""
        managedUser := user != "" ? user : LS_AccountManager.DefaultUser
        if (LS_Status.IsLocalModeEnabled())
            return this.RecordPrepareFailure(started, user, "local mode is active")

        try {
            localSessions := this.GetPrepareLocalSessions(managedUser)
        } catch as e {
            return this.RecordPrepareFailure(started, user, "session inventory unavailable: " . e.Message)
        }

        profile := LS_Status.GetStationProfile()
        allowEviction := localSessions.Length > 0 && LS_Status.IsLocalSessionEvictionAllowed()
        localSessionDecision := this.PrepareLocalSessionDecision(profile, localSessions.Length, allowEviction)
        if (localSessionDecision = "refuse") {
            reason := profile = "hybrid"
                ? "local session is active and local-session eviction is disabled"
                : "unexpected local interactive session on dedicated station"
            return this.RecordPrepareFailure(started, user, reason)
        }
        if (localSessionDecision = "evict") {
            if (options.Has("guard") && !options["guard"]) {
                try {
                    currentLocalSessions := LS_SessionGuard.FindConflictingSessions(managedUser, true)
                } catch as e {
                    return this.RecordPrepareFailure(started, user, "session inventory unavailable before immediate eviction: " . e.Message)
                }
                if (!LS_SessionGuard.SameSessionSnapshot(localSessions, currentLocalSessions))
                    return this.RecordPrepareFailure(started, user, "local sessions changed before immediate eviction")
                for session in localSessions {
                    if (LS_Status.IsLocalModeEnabled())
                        return this.RecordPrepareFailure(started, user, "local mode became active during session release")
                    if (!LS_SessionGuard.LogoffSession(session))
                        return this.RecordPrepareFailure(started, user, "unable to evict local interactive session")
                }
            } else if (!this.RunSessionGuard(options, true)) {
                return this.RecordPrepareFailure(started, user, "session guard failed")
            }
        }
        try {
            if (LS_SessionGuard.FindConflictingSessions(managedUser, true).Length > 0)
                return this.RecordPrepareFailure(started, user, "local interactive session became active or remained active during preparation")
        } catch as e {
            return this.RecordPrepareFailure(started, user, "session inventory unavailable after guard: " . e.Message)
        }
        if (LS_Status.IsLocalModeEnabled())
            return this.RecordPrepareFailure(started, user, "local mode became active during preparation")

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
        if (ok) {
            LS_LogInfo("Prepare-session completed")
        } else {
            this.LastPrepareExitCode := 1
            LS_LogWarning("Prepare-session finished with warnings")
        }
        details := Map("durationMs", A_TickCount - started, "user", user)
        LS_ServiceState.RecordPrepareSession(ok, details)
        return ok
    }

    static GetPrepareLocalSessions(managedUser) {
        return LS_SessionGuard.FindConflictingSessions(managedUser, true)
    }

    static PrepareLocalSessionDecision(profile, localSessionCount, allowEviction) {
        if (localSessionCount <= 0)
            return "continue"
        if (profile = "hybrid" && allowEviction)
            return "evict"
        return "refuse"
    }

    static RecordPrepareFailure(started, user, reason) {
        this.LastPrepareExitCode := 2
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
        return LS_SessionGuard.Run(guardOpts)
    }

    static ReleaseSession(options := Map()) {
        LS_LogInfo("Release-session started")
        started := A_TickCount
        ok := true
        ok := this.CloseControllerProcesses() && ok
        ok := this.CleanFmuExecutorState() && ok
        user := options.Has("user") ? options["user"] : ""
        ok := this.LogoffLabUser(user) && ok
        if (options.Has("reboot") && options["reboot"]) {
            ok := this.TriggerReboot(options.Has("rebootTimeout") ? options["rebootTimeout"] : 0) && ok
        }
        if (ok) {
            LS_LogInfo("Release-session completed")
        } else {
            LS_LogWarning("Release-session finished with warnings")
        }
        details := Map("durationMs", A_TickCount - started, "user", user)
        if (options.Has("reboot"))
            details["rebootRequested"] := options["reboot"]
        if (options.Has("rebootTimeout"))
            details["rebootTimeout"] := options["rebootTimeout"]
        LS_ServiceState.RecordReleaseSession(ok, details)
        return ok
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
            LS_FmuExecutor.TerminateAllSessions()
            LS_FmuExecutor.CleanTempState()
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

    static LogoffLabUser(user := "", force := true) {
        if (!user || user = "") {
            user := LS_AccountManager.DefaultUser
        }
        sanitized := StrReplace(user, "'", "''")
        script := "
        (
`$User = '__USER__'
`$regex = '^\s*>?\s*' + [regex]::Escape(`$User) + '\s+(?:\S+\s+)?(\d+)\s+\S+'
`$lines = @()
try {
    `$lines = @(quser)
} catch {
    Write-Error ("Unable to query active sessions: " + `$_.Exception.Message)
    exit 2
}
`$matched = `$false
`$allLoggedOff = `$true
foreach (`$line in `$lines) {
    `$text = `$line.ToString()
    if (`$text -match `$regex) {
        `$sessionId = [int]`$Matches[1]
        `$matched = `$true
        logoff `$sessionId 2>`$null
        if (`$LASTEXITCODE -ne 0) { `$allLoggedOff = `$false }
    }
}
if (-not `$matched) {
    Write-Output "NO_ACTIVE_SESSION"
    exit 0
}
if (`$allLoggedOff) { exit 0 } else { exit 1 }
        )"
        script := StrReplace(script, "__USER__", sanitized)
        capture := LS_RunPowerShellCapture(script, "Logoff " . user)
        exitCode := capture["exitCode"]
        if (exitCode = 0) {
            if (InStr(capture["stdout"], "NO_ACTIVE_SESSION"))
                LS_LogInfo("No active session found for " . user . "; release already satisfied")
            return true
        }
        detail := LS_CaptureDetail(capture)
        message := "Unable to log off active session for " . user
        if (detail != "")
            message .= ": " . detail
        LS_LogWarning(message)
        return false
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
