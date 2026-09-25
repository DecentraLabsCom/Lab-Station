#Requires AutoHotkey v2.0
#Include TestSupport.ahk
#Include ..\service\FmuExecutor.ahk

global TEST_FAILURES := 0
global TEST_ROOT := A_Temp "\LabStation-FmuExecutorTests-" A_TickCount
global ORIGINAL_EXECUTOR_DIR := LAB_STATION_FMU_EXECUTOR_DIR
global ORIGINAL_EXECUTOR_PORT := LAB_STATION_FMU_EXECUTOR_PORT
global ORIGINAL_EXECUTOR_LOG := LAB_STATION_FMU_EXECUTOR_LOG

DirCreate(TEST_ROOT)
DirCreate(TEST_ROOT "\fmu-data\.tmp")
LAB_STATION_FMU_EXECUTOR_DIR := TEST_ROOT
LAB_STATION_FMU_EXECUTOR_PORT := 18091
LAB_STATION_FMU_EXECUTOR_LOG := TEST_ROOT "\executor.log"

RunFmuExecutorTests()

class RecordingFmuExecutor extends LS_FmuExecutor {
    static _pid := 0
    static _lastHealthCheck := 0
    static _healthInterval := 30000
    static _consecutiveFailures := 0
    static _maxFailures := 3
    static _lastHealthResult := Map()
    static _lastHealthOk := false
    static available := false
    static tokenReady := false
    static processRunning := false
    static firewallResult := true
    static shellResult := 0
    static pythonExecutable := ""
    static launchResult := true
    static launchPid := 4242
    static stopResult := 0
    static launchCalls := []
    static stopCalls := []
    static waitCalls := []
    static firewallCalls := 0
    static shellCalls := []
    static captureCalls := []
    static commandCaptures := []
    static captureResult := Map("exitCode", 0, "stdout", "", "stderr", "")

    static Reset() {
        this.available := false
        this.tokenReady := false
        this.processRunning := false
        this.firewallResult := true
        this.shellResult := 0
        this.pythonExecutable := ""
        this.launchResult := true
        this.launchPid := 4242
        this.stopResult := 0
        this.launchCalls := []
        this.stopCalls := []
        this.waitCalls := []
        this.firewallCalls := 0
        this.shellCalls := []
        this.captureCalls := []
        this.commandCaptures := []
        this.captureResult := Map("exitCode", 0, "stdout", "", "stderr", "")
        this._pid := 0
        this._lastHealthCheck := 0
        this._healthInterval := 30000
        this._consecutiveFailures := 0
        this._maxFailures := 3
        this._lastHealthResult := Map()
        this._lastHealthOk := false
    }

    static IsAvailable() {
        return this.available
    }

    static TokenConfigured() {
        return this.tokenReady
    }

    static _ProcessExists(pid) {
        return this.processRunning
    }

    static EnsureFirewallRule() {
        this.firewallCalls += 1
        return this.firewallResult
    }

    static _FindPython() {
        return this.pythonExecutable
    }

    static LaunchProcess(command, workingDir, options) {
        this.launchCalls.Push(Map("command", command, "workingDir", workingDir, "options", options))
        if (!this.launchResult)
            throw Error("synthetic launch failure")
        return this.launchPid
    }

    static StopProcess(pid) {
        this.stopCalls.Push(pid)
        return this.stopResult
    }

    static WaitBeforeRestart(milliseconds) {
        this.waitCalls.Push(milliseconds)
    }

    static RunPowerShell(script, description) {
        this.shellCalls.Push(Map("script", script, "description", description))
        return this.shellResult
    }

    static RunPowerShellCapture(script, description, timeoutMs := 15000) {
        this.captureCalls.Push(Map("script", script, "description", description, "timeoutMs", timeoutMs))
        return this.captureResult
    }

    static RunCommandCapture(command, description) {
        this.captureCalls.Push(Map("command", command, "description", description))
        if (this.commandCaptures.Length = 0)
            return Map("exitCode", 1, "stdout", "", "stderr", "not configured")
        result := this.commandCaptures[1]
        this.commandCaptures.RemoveAt(1)
        return result
    }
}

class RecordingPythonFmuExecutor extends LS_FmuExecutor {
    static commandCaptures := []
    static captureCalls := []

    static Reset() {
        this.commandCaptures := []
        this.captureCalls := []
    }

    static RunCommandCapture(command, description) {
        this.captureCalls.Push(Map("command", command, "description", description))
        result := this.commandCaptures[1]
        this.commandCaptures.RemoveAt(1)
        return result
    }
}

class ProcessProbeFmuExecutor extends LS_FmuExecutor {
    static captureResult := Map("exitCode", 0, "stdout", "1", "stderr", "")
    static captureCalls := []

    static Reset() {
        this.captureResult := Map("exitCode", 0, "stdout", "1", "stderr", "")
        this.captureCalls := []
    }

    static RunPowerShellCapture(script, description, timeoutMs := 15000) {
        this.captureCalls.Push(Map(
            "script", script,
            "description", description,
            "timeoutMs", timeoutMs
        ))
        return this.captureResult
    }
}

RunFmuExecutorTests() {
    global ORIGINAL_EXECUTOR_DIR, ORIGINAL_EXECUTOR_PORT, ORIGINAL_EXECUTOR_LOG
    global LAB_STATION_FMU_EXECUTOR_DIR, LAB_STATION_FMU_EXECUTOR_PORT, LAB_STATION_FMU_EXECUTOR_LOG, TEST_ROOT

    try {
        TestAvailabilityUsesExecutorLayout()
        TestConfiguredPortUsesEnvironmentAndSafeFallback()
        TestStartRequiresAvailabilityAndToken()
        TestStartRunsTheConfiguredPythonExecutor()
        TestStartStopsBeforeLaunchWhenFirewallFails()
        TestStartReportsLaunchFailure()
        TestStartDoesNotDuplicateRunningExecutor()
        TestProcessExistsBuildsRunnablePowerShell()
        TestStopIsIdempotentAndClearsPid()
        TestRestartStopsWaitsAndStarts()
        TestHealthCheckParsesSuccessAndTracksFailures()
        TestTickStartsMissingExecutor()
        TestTickRestartsAfterConsecutiveHealthFailures()
        TestFindPythonUsesTheFirstWorkingCandidate()
        TestCleanTempStateUsesTheExecutorTempFolder()
        TestTerminateAllSessionsRestartsRunningExecutor()
        TestHealthSummaryMirrorsOperationalState()
        TestHealthSummaryFallsBackToSidecarHealth()
        TestHealthSummaryRejectsUnhealthyLiveProcess()
    } catch as err {
        LS_TestFail("Unhandled FMU executor test exception: " . err.Message)
    }

    LAB_STATION_FMU_EXECUTOR_DIR := ORIGINAL_EXECUTOR_DIR
    LAB_STATION_FMU_EXECUTOR_PORT := ORIGINAL_EXECUTOR_PORT
    LAB_STATION_FMU_EXECUTOR_LOG := ORIGINAL_EXECUTOR_LOG
    try DirDelete(TEST_ROOT, true)

    if (TEST_FAILURES > 0) {
        LS_TestOutput("FmuExecutorTests failed: " . TEST_FAILURES . " failure(s)" . Chr(10))
        ExitApp(1)
    }

    LS_TestOutput("FmuExecutorTests passed" . Chr(10))
    ExitApp(0)
}

TestConfiguredPortUsesEnvironmentAndSafeFallback() {
    original := EnvGet("FMU_EXECUTOR_PORT")

    EnvSet("FMU_EXECUTOR_PORT", "19091")
    LS_TestAssert(LS_ResolveFmuExecutorPort() = 19091, "FMU supervisor reads a valid port from the environment")

    EnvSet("FMU_EXECUTOR_PORT", "65536")
    LS_TestAssert(LS_ResolveFmuExecutorPort() = 8091, "FMU supervisor falls back when the port is outside the TCP range")

    EnvSet("FMU_EXECUTOR_PORT", "not-a-port")
    LS_TestAssert(LS_ResolveFmuExecutorPort() = 8091, "FMU supervisor falls back when the port is not numeric")

    EnvSet("FMU_EXECUTOR_PORT", original)
}

TestAvailabilityUsesExecutorLayout() {
    global LAB_STATION_FMU_EXECUTOR_DIR, TEST_ROOT

    try FileDelete(TEST_ROOT "\app\main.py")
    try DirDelete(TEST_ROOT "\app", true)
    LS_TestAssert(!LS_FmuExecutor.IsAvailable(), "FMU executor is unavailable without its application entrypoint")

    DirCreate(TEST_ROOT "\app")
    FileAppend("# test executor" . Chr(10), TEST_ROOT "\app\main.py", "UTF-8")
    LS_TestAssert(LS_FmuExecutor.IsAvailable(), "FMU executor is available when app/main.py is present")
}

TestStartRequiresAvailabilityAndToken() {
    RecordingFmuExecutor.Reset()

    result := RecordingFmuExecutor.Start()
    LS_TestAssert(!result, "FMU start fails when the executor directory is unavailable")
    LS_TestAssert(RecordingFmuExecutor.firewallCalls = 0, "unavailable executor does not configure firewall")

    RecordingFmuExecutor.available := true
    result := RecordingFmuExecutor.Start()
    LS_TestAssert(!result, "FMU start fails when the internal token is missing")
    LS_TestAssert(RecordingFmuExecutor.firewallCalls = 0, "missing token does not configure firewall")
}

TestStartRunsTheConfiguredPythonExecutor() {
    RecordingFmuExecutor.Reset()
    RecordingFmuExecutor.available := true
    RecordingFmuExecutor.tokenReady := true
    RecordingFmuExecutor.pythonExecutable := "python"

    result := RecordingFmuExecutor.Start()

    LS_TestAssert(result, "FMU start succeeds after availability, token and firewall checks")
    LS_TestAssert(RecordingFmuExecutor.firewallCalls = 1, "FMU start configures firewall before launch")
    LS_TestAssert(RecordingFmuExecutor.launchCalls.Length = 1, "FMU start launches one executor process")
    LS_TestAssert(InStr(RecordingFmuExecutor.launchCalls[1]["command"], Chr(34) . "python" . Chr(34) . " -m app") > 0, "FMU start launches the Python app module")
    LS_TestAssert(RecordingFmuExecutor.launchCalls[1]["workingDir"] = LAB_STATION_FMU_EXECUTOR_DIR, "FMU start uses the executor working directory")
    LS_TestAssert(RecordingFmuExecutor._pid = 4242, "FMU start records the child process PID")
}

TestStartStopsBeforeLaunchWhenFirewallFails() {
    RecordingFmuExecutor.Reset()
    RecordingFmuExecutor.available := true
    RecordingFmuExecutor.tokenReady := true
    RecordingFmuExecutor.firewallResult := false

    result := RecordingFmuExecutor.Start()

    LS_TestAssert(!result, "FMU start reports firewall configuration failure")
    LS_TestAssert(RecordingFmuExecutor.launchCalls.Length = 0, "FMU start does not launch after firewall failure")
}

TestStartReportsLaunchFailure() {
    RecordingFmuExecutor.Reset()
    RecordingFmuExecutor.available := true
    RecordingFmuExecutor.tokenReady := true
    RecordingFmuExecutor.pythonExecutable := "python"
    RecordingFmuExecutor.launchResult := false

    result := RecordingFmuExecutor.Start()

    LS_TestAssert(!result, "FMU start reports a process launch exception")
    LS_TestAssert(RecordingFmuExecutor._pid = 0, "failed FMU launch does not publish a child PID")
}

TestStartDoesNotDuplicateRunningExecutor() {
    RecordingFmuExecutor.Reset()
    RecordingFmuExecutor.available := true
    RecordingFmuExecutor.tokenReady := true
    RecordingFmuExecutor.pythonExecutable := "python"
    RecordingFmuExecutor.processRunning := true
    RecordingFmuExecutor._pid := 111

    result := RecordingFmuExecutor.Start()

    LS_TestAssert(result, "FMU start is idempotent when the child is already running")
    LS_TestAssert(RecordingFmuExecutor.launchCalls.Length = 0, "FMU start does not launch a duplicate child")
}

TestProcessExistsBuildsRunnablePowerShell() {
    ProcessProbeFmuExecutor.Reset()

    LS_TestAssert(ProcessProbeFmuExecutor._ProcessExists(4242), "FMU process probe accepts a successful PowerShell marker")
    LS_TestAssert(ProcessProbeFmuExecutor.captureCalls.Length = 1, "FMU process probe invokes PowerShell once")

    script := ProcessProbeFmuExecutor.captureCalls[1]["script"]
    LS_TestAssert(InStr(script, "try {") > 0 && InStr(script, "} catch {") > 0, "FMU process probe generates single-brace PowerShell blocks")
    LS_TestAssert(InStr(script, "{{") = 0 && InStr(script, "}}") = 0, "FMU process probe does not leak Format brace escapes")
    LS_TestAssert(InStr(script, "Get-Process -Id 4242") > 0, "FMU process probe substitutes the PID")

    ProcessProbeFmuExecutor.captureResult := Map("exitCode", 0, "stdout", "0", "stderr", "")
    LS_TestAssert(!ProcessProbeFmuExecutor._ProcessExists(4242), "FMU process probe rejects a negative PowerShell marker")
}

TestStopIsIdempotentAndClearsPid() {
    RecordingFmuExecutor.Reset()

    LS_TestAssert(RecordingFmuExecutor.Stop(), "FMU stop succeeds when no child is registered")
    LS_TestAssert(RecordingFmuExecutor.stopCalls.Length = 0, "FMU stop does not kill an empty PID")

    RecordingFmuExecutor._pid := 1234
    result := RecordingFmuExecutor.Stop()

    LS_TestAssert(result, "FMU stop succeeds after issuing the process termination command")
    LS_TestAssert(RecordingFmuExecutor.stopCalls[1] = 1234, "FMU stop targets the recorded child PID")
    LS_TestAssert(RecordingFmuExecutor._pid = 0 && RecordingFmuExecutor._consecutiveFailures = 0, "FMU stop clears PID and health failure state")
}

TestRestartStopsWaitsAndStarts() {
    RecordingFmuExecutor.Reset()
    RecordingFmuExecutor.available := true
    RecordingFmuExecutor.tokenReady := true
    RecordingFmuExecutor.pythonExecutable := "python"
    RecordingFmuExecutor.processRunning := true
    RecordingFmuExecutor._pid := 1234

    result := RecordingFmuExecutor.Restart()

    LS_TestAssert(result, "FMU restart succeeds when stop and start succeed")
    LS_TestAssert(RecordingFmuExecutor.stopCalls.Length = 1, "FMU restart stops the previous executor")
    LS_TestAssert(RecordingFmuExecutor.waitCalls.Length = 1 && RecordingFmuExecutor.waitCalls[1] = 1000, "FMU restart waits before launching again")
    LS_TestAssert(RecordingFmuExecutor.launchCalls.Length = 1, "FMU restart launches a replacement executor")
}

TestHealthCheckParsesSuccessAndTracksFailures() {
    RecordingFmuExecutor.Reset()
    RecordingFmuExecutor.captureResult := Map(
        "exitCode", 0,
        "stdout", "{" . Chr(34) . "status" . Chr(34) . ":" . Chr(34) . "UP" . Chr(34) . "," . Chr(34) . "fmuCount" . Chr(34) . ":2}",
        "stderr", ""
    )

    LS_TestAssert(RecordingFmuExecutor.CheckHealth(), "FMU health check accepts a valid JSON response")
    LS_TestAssert(RecordingFmuExecutor._consecutiveFailures = 0, "successful health check clears failure count")
    LS_TestAssert(RecordingFmuExecutor._lastHealthResult["fmuCount"] = 2, "health check stores executor metadata")

    RecordingFmuExecutor.captureResult := Map("exitCode", 0, "stdout", "ERROR", "stderr", "")
    LS_TestAssert(!RecordingFmuExecutor.CheckHealth(), "FMU health check rejects the executor error response")
    LS_TestAssert(RecordingFmuExecutor._consecutiveFailures = 1 && RecordingFmuExecutor._lastHealthResult["status"] = "unreachable", "unreachable health checks are counted")

    RecordingFmuExecutor.captureResult := Map("exitCode", 0, "stdout", "not-json", "stderr", "")
    LS_TestAssert(!RecordingFmuExecutor.CheckHealth(), "FMU health check rejects malformed JSON")
    LS_TestAssert(RecordingFmuExecutor._lastHealthResult["status"] = "parse-error", "malformed health JSON is classified as a parse error")
}

TestTickStartsMissingExecutor() {
    RecordingFmuExecutor.Reset()
    RecordingFmuExecutor.available := true
    RecordingFmuExecutor.tokenReady := true
    RecordingFmuExecutor.pythonExecutable := "python"

    RecordingFmuExecutor.Tick()

    LS_TestAssert(RecordingFmuExecutor.launchCalls.Length = 1, "service tick starts an available executor that is not running")
    LS_TestAssert(RecordingFmuExecutor._lastHealthCheck > 0, "service tick schedules the next health check after startup")
}

TestTickRestartsAfterConsecutiveHealthFailures() {
    RecordingFmuExecutor.Reset()
    RecordingFmuExecutor.available := true
    RecordingFmuExecutor.tokenReady := true
    RecordingFmuExecutor.pythonExecutable := "python"
    RecordingFmuExecutor.processRunning := true
    RecordingFmuExecutor._pid := 99
    RecordingFmuExecutor.captureResult := Map("exitCode", 0, "stdout", "ERROR", "stderr", "")

    loop 3 {
        RecordingFmuExecutor._lastHealthCheck := A_TickCount - RecordingFmuExecutor._healthInterval - 1
        RecordingFmuExecutor.Tick()
    }

    LS_TestAssert(RecordingFmuExecutor.captureCalls.Length = 3, "service tick performs three health checks before restarting")
    LS_TestAssert(RecordingFmuExecutor._consecutiveFailures = 0, "FMU restart clears the consecutive failure count")
    LS_TestAssert(RecordingFmuExecutor.stopCalls.Length = 1 && RecordingFmuExecutor.launchCalls.Length = 1, "service tick restarts the executor at the failure threshold")
    LS_TestAssert(RecordingFmuExecutor.waitCalls.Length = 1, "service tick restart uses the controlled restart path")
}

TestFindPythonUsesTheFirstWorkingCandidate() {
    RecordingPythonFmuExecutor.Reset()
    RecordingPythonFmuExecutor.commandCaptures := [
        Map("exitCode", 1, "stdout", "", "stderr", "not found"),
        Map("exitCode", 0, "stdout", "Python 3.12.0", "stderr", "")
    ]

    python := RecordingPythonFmuExecutor._FindPython()

    LS_TestAssert(python = "python3", "FMU executor falls back to python3 when python is unavailable")
    LS_TestAssert(RecordingPythonFmuExecutor.captureCalls.Length = 2, "FMU executor probes both Python candidates in order")
}

TestCleanTempStateUsesTheExecutorTempFolder() {
    RecordingFmuExecutor.Reset()
    RecordingFmuExecutor.shellResult := 5

    result := RecordingFmuExecutor.CleanTempState()

    LS_TestAssert(!result, "FMU temp cleanup reports a PowerShell failure")
    LS_TestAssert(RecordingFmuExecutor.shellCalls.Length = 1, "FMU temp cleanup executes one cleanup script")
    LS_TestAssert(InStr(RecordingFmuExecutor.shellCalls[1]["script"], "fmu-data") > 0, "FMU temp cleanup targets the executor data directory")

    RecordingFmuExecutor.shellResult := 0
    LS_TestAssert(RecordingFmuExecutor.CleanTempState(), "FMU temp cleanup succeeds when PowerShell succeeds")
}

TestTerminateAllSessionsRestartsRunningExecutor() {
    RecordingFmuExecutor.Reset()
    RecordingFmuExecutor.available := true
    RecordingFmuExecutor.tokenReady := true
    RecordingFmuExecutor.pythonExecutable := "python"
    RecordingFmuExecutor.processRunning := true
    RecordingFmuExecutor._pid := 77

    result := RecordingFmuExecutor.TerminateAllSessions()

    LS_TestAssert(result, "FMU session termination succeeds through process restart")
    LS_TestAssert(RecordingFmuExecutor.stopCalls.Length = 1 && RecordingFmuExecutor.launchCalls.Length = 1, "FMU session termination restarts a running executor")
}

TestHealthSummaryMirrorsOperationalState() {
    RecordingFmuExecutor.Reset()
    RecordingFmuExecutor.available := true
    RecordingFmuExecutor.tokenReady := true
    RecordingFmuExecutor.processRunning := true
    RecordingFmuExecutor._pid := 8080
    RecordingFmuExecutor._lastHealthCheck := A_TickCount
    RecordingFmuExecutor._lastHealthOk := true
    RecordingFmuExecutor._consecutiveFailures := 0
    RecordingFmuExecutor._lastHealthResult := Map("status", "UP")

    summary := RecordingFmuExecutor.GetHealthSummary()

    LS_TestAssert(summary["available"] && summary["running"] && summary["tokenConfigured"], "FMU health summary reports availability, process and token state")
    LS_TestAssert(summary["pid"] = 8080 && summary["port"] = 18091, "FMU health summary reports PID and configured port")
    LS_TestAssert(summary["consecutiveFailures"] = 0 && summary["lastHealth"]["status"] = "UP", "FMU health summary reports health history")
}

TestHealthSummaryFallsBackToSidecarHealth() {
    RecordingFmuExecutor.Reset()
    RecordingFmuExecutor.available := true
    RecordingFmuExecutor.captureResult := Map(
        "exitCode", 0,
        "stdout", "{" . Chr(34) . "status" . Chr(34) . ":" . Chr(34) . "UP" . Chr(34) . "}",
        "stderr", ""
    )

    summary := RecordingFmuExecutor.GetHealthSummary()

    LS_TestAssert(summary["running"], "FMU health summary detects an executor started by another process")
    LS_TestAssert(RecordingFmuExecutor.captureCalls.Length = 1, "cross-process FMU status performs a health probe")
}

TestHealthSummaryRejectsUnhealthyLiveProcess() {
    RecordingFmuExecutor.Reset()
    RecordingFmuExecutor.available := true
    RecordingFmuExecutor.processRunning := true
    RecordingFmuExecutor._pid := 8080
    RecordingFmuExecutor.captureResult := Map("exitCode", 0, "stdout", "ERROR", "stderr", "")

    summary := RecordingFmuExecutor.GetHealthSummary()

    LS_TestAssert(!summary["running"], "FMU health summary rejects a live process with an unhealthy endpoint")
    LS_TestAssert(RecordingFmuExecutor.captureCalls.Length = 1, "live FMU status probes the endpoint when health is unknown")
}
