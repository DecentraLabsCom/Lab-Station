; ============================================================================
; Lab Station - FMU Executor supervisor
; ============================================================================
; Manages the Python fmu-executor sidecar as a child process supervised by
; Lab Station's service loop.
; ============================================================================
#Requires AutoHotkey v2.0
#Include ..\core\Config.ahk
#Include ..\core\Logger.ahk
#Include ..\core\Shell.ahk
#Include ..\core\Json.ahk

if (!IsSet(LAB_STATION_FMU_EXECUTOR_DIR)) {
    global LAB_STATION_FMU_EXECUTOR_DIR := LAB_STATION_PROJECT_ROOT "\fmu-executor"
}

if (!IsSet(LAB_STATION_FMU_EXECUTOR_PORT)) {
    global LAB_STATION_FMU_EXECUTOR_PORT := "8091"
}

if (!IsSet(LAB_STATION_FMU_EXECUTOR_LOG)) {
    global LAB_STATION_FMU_EXECUTOR_LOG := LAB_STATION_FMU_EXECUTOR_DIR "\executor.log"
}

class LS_FmuExecutor {
    static _pid := 0
    static _lastHealthCheck := 0
    static _healthInterval := 30000  ; ms
    static _consecutiveFailures := 0
    static _maxFailures := 3
    static _lastHealthResult := Map()

    ; lifecycle

    static IsAvailable() {
        return DirExist(LAB_STATION_FMU_EXECUTOR_DIR) && FileExist(LAB_STATION_FMU_EXECUTOR_DIR "\app\main.py")
    }

    static IsRunning() {
        if (this._pid = 0)
            return false
        return this._ProcessExists(this._pid)
    }

    static Start() {
        if (!this.IsAvailable()) {
            LS_LogWarning("FMU executor: not available (directory missing)")
            return false
        }
        if (this.IsRunning()) {
            LS_LogInfo("FMU executor: already running (PID=" . this._pid . ")")
            return true
        }

        pythonExe := this._FindPython()
        if (pythonExe = "") {
            LS_LogError("FMU executor: Python not found on PATH")
            return false
        }

        LS_LogInfo("FMU executor: starting sidecar on port " . LAB_STATION_FMU_EXECUTOR_PORT)

        command := Format('"{1}" -m app', pythonExe)
        try {
            Run(command, LAB_STATION_FMU_EXECUTOR_DIR, "Hide", &pid)
            this._pid := pid
            this._consecutiveFailures := 0
            LS_LogInfo(Format("FMU executor: started (PID={1})", pid))
            return true
        } catch as e {
            LS_LogError("FMU executor: unable to start - " . e.Message)
            return false
        }
    }

    static Stop() {
        if (this._pid = 0)
            return true
        LS_LogInfo(Format("FMU executor: stopping (PID={1})", this._pid))
        try {
            cmd := Format('taskkill /PID {1} /T /F', this._pid)
            RunWait(cmd, , "Hide")
        } catch {
        }
        this._pid := 0
        this._consecutiveFailures := 0
        return true
    }

    static Restart() {
        this.Stop()
        Sleep 1000
        return this.Start()
    }

    ; health probing

    static CheckHealth() {
        url := Format("http://127.0.0.1:{1}/internal/health", LAB_STATION_FMU_EXECUTOR_PORT)
        script := Format("
        (
try {{
    $r = Invoke-RestMethod -Uri '{1}' -TimeoutSec 5 -ErrorAction Stop
    $r | ConvertTo-Json -Compress
}} catch {{
    Write-Output 'ERROR'
}}
        )", url)
        capture := LS_RunPowerShellCapture(script, "FMU executor health check")
        output := Trim(capture["stdout"])
        if (output = "ERROR" || output = "" || capture["exitCode"] != 0) {
            this._consecutiveFailures += 1
            this._lastHealthResult := Map("status", "unreachable", "failures", this._consecutiveFailures)
            return false
        }
        try {
            parsed := LS_ParseJson(output)
            this._consecutiveFailures := 0
            this._lastHealthResult := parsed
            return true
        } catch {
            this._consecutiveFailures += 1
            this._lastHealthResult := Map("status", "parse-error", "failures", this._consecutiveFailures)
            return false
        }
    }

    static GetHealthSummary() {
        summary := Map()
        summary["available"] := this.IsAvailable()
        summary["running"] := this.IsRunning()
        summary["pid"] := this._pid
        summary["port"] := LAB_STATION_FMU_EXECUTOR_PORT
        summary["consecutiveFailures"] := this._consecutiveFailures
        summary["lastHealth"] := this._lastHealthResult
        return summary
    }

    ; service-loop tick

    static Tick() {
        if (!this.IsAvailable())
            return
        now := A_TickCount
        ; Start if not running
        if (!this.IsRunning()) {
            this.Start()
            this._lastHealthCheck := now
            return
        }
        ; Periodic health check
        if (now - this._lastHealthCheck >= this._healthInterval) {
            this._lastHealthCheck := now
            healthy := this.CheckHealth()
            if (!healthy && this._consecutiveFailures >= this._maxFailures) {
                LS_LogWarning(Format(
                    "FMU executor: {1} consecutive health failures - restarting",
                    this._consecutiveFailures
                ))
                this.Restart()
            }
        }
    }

    ; session cleanup

    static TerminateAllSessions() {
        if (!this.IsRunning())
            return true
        ; The executor auto-terminates all sessions on process kill
        ; but we can also use the health endpoint to check first
        LS_LogInfo("FMU executor: terminating all sessions via process restart")
        return this.Restart()
    }

    static CleanTempState() {
        tempDir := LAB_STATION_FMU_EXECUTOR_DIR "\fmu-data\.tmp"
        if (!DirExist(tempDir))
            return true
        script := Format("
        (
`$Path = '{1}'
if (Test-Path `$Path) {{
    Get-ChildItem -Path `$Path -Force -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
}}
        )", StrReplace(tempDir, "'", "''"))
        exitCode := LS_RunPowerShell(script, "Clean FMU executor temp")
        return exitCode = 0
    }

    ; private

    static _FindPython() {
        candidates := ["python", "python3"]
        for cmd in candidates {
            capture := LS_RunCommandCapture(Format('{1} --version', cmd), "Check " . cmd)
            if (capture["exitCode"] = 0 && InStr(capture["stdout"], "Python"))
                return cmd
        }
        return ""
    }

    static _ProcessExists(pid) {
        script := Format("
        (
try {{
    $p = Get-Process -Id {1} -ErrorAction Stop
    Write-Output '1'
}} catch {{
    Write-Output '0'
}}
        )", pid)
        capture := LS_RunPowerShellCapture(script, "Check PID " . pid)
        return InStr(Trim(capture["stdout"]), "1") > 0
    }
}
