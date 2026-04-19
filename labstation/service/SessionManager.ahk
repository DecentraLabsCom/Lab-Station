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

class LS_SessionManager {
    static PrepareSession(options := Map()) {
        LS_LogInfo("Prepare-session started")
        started := A_TickCount
        ok := true
        ok := this.RunSessionGuard(options) && ok
        ok := this.CloseControllerProcesses() && ok
        user := options.Has("user") ? options["user"] : ""
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
            LS_LogWarning("Prepare-session finished with warnings")
        }
        details := Map("durationMs", A_TickCount - started, "user", user)
        LS_ServiceState.RecordPrepareSession(ok, details)
        return ok
    }

    static RunSessionGuard(options) {
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
        return LS_SessionGuard.Run(guardOpts)
    }

    static ReleaseSession(options := Map()) {
        LS_LogInfo("Release-session started")
        started := A_TickCount
        ok := true
        ok := this.CloseControllerProcesses() && ok
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
        targets := ["AppControl.exe", "AppControl.ahk"]
        result := true
        for exe in targets {
            cmd := Format('taskkill /IM "{1}" /F', exe)
            exitCode := LS_RunCommand(cmd, "Terminate " . exe)
            if (exitCode != 0 && exitCode != 128 && exitCode != 1) {
                result := false
                LS_LogWarning(Format("Unable to close {1} (exit={2})", exe, exitCode))
            }
        }
        return result
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
        logPath := LAB_STATION_CONTROLLER_DIR "\AppControl.log"
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

    static CleanDirectory(path) {
        if (!DirExist(path)) {
            return true
        }
        sanitized := StrReplace(path, "'", "''")
        script := Format("
        (
`$Path = '{1}'
if (Test-Path `$Path) {{
    Get-ChildItem -Path `$Path -Force -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
}}
        )", sanitized)
        exitCode := LS_RunPowerShell(script, "Clean " . path)
        if (exitCode != 0) {
            LS_LogWarning(Format("Unable to clean {1} (exit={2})", path, exitCode))
            return false
        }
        return true
    }

    static GetUserProfilePath(user) {
        profile := "C:\\Users\\" . user
        if (DirExist(profile)) {
            return profile
        }
        filterUser := StrReplace(user, "'", "''")
        script := Format("
        (
`$u = '{1}'
`$p = Get-CimInstance -ClassName Win32_UserProfile | Where-Object {{ `$_.LocalPath -like '*\\{1}' -and -not `$_.Special }} | Select-Object -First 1
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
        flag := force ? "/f" : ""
        sanitized := StrReplace(user, "'", "''")
        script := Format("
        (
`$User = '{1}'
`$regex = '^\s*>?\s*' + [regex]::Escape(`$User) + '\s+\S+\s+(\d+)'
`$lines = @()
try {{ `$lines = quser }} catch {{}}
`$found = `$false
foreach (`$line in `$lines) {{
    `$text = `$line.ToString()
    if (`$text -match `$regex) {{
        `$sessionId = [int]`$Matches[1]
        try {{ logoff `$sessionId {2} | Out-Null }} catch {{}}
        `$found = `$true
    }}
}}
if (`$found) {{ exit 0 }} else {{ exit 1 }}
        )", sanitized, flag)
        exitCode := LS_RunPowerShell(script, "Logoff " . user)
        if (exitCode = 0) {
            return true
        }
        LS_LogWarning("No active session found for " . user)
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
