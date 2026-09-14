#Requires AutoHotkey v2.0
#Include TestSupport.ahk
#Include ..\system\ServiceManager.ahk

global TEST_FAILURES := 0

RunServiceManagerTests()

class RecordingServiceManager extends LS_ServiceManager {
    static adminResult := true
    static commandResult := 0
    static commands := []
    static captures := []
    static powershellResult := Map("exitCode", 0, "stdout", "", "stderr", "")

    static Reset() {
        this.adminResult := true
        this.commandResult := 0
        this.commands := []
        this.captures := []
        this.powershellResult := Map("exitCode", 0, "stdout", "", "stderr", "")
    }

    static EnsureAdmin() {
        return this.adminResult
    }

    static RunCommand(command, description) {
        this.commands.Push(Map("command", command, "description", description))
        return this.commandResult
    }

    static RunCommandCapture(command, description) {
        this.captures.Push(Map("command", command, "description", description))
        return this.powershellResult
    }

    static RunPowerShellCapture(script, description, timeoutMs := 0) {
        this.captures.Push(Map("script", script, "description", description, "timeoutMs", timeoutMs))
        return this.powershellResult
    }
}

RunServiceManagerTests() {
    try {
        TestInstallRequiresAdmin()
        TestInstallBuildsOnStartTaskDefinition()
        TestInstallReportsTaskSchedulerFailure()
        TestInstallEscapesPowerShellSingleQuotesAndKeepsArgumentsSeparate()
        TestUninstallUsesTaskNameAndReportsFailure()
        TestStartAndStopUseTaskName()
        TestStatusTextPrefersStdoutAndFallsBackToStderr()
        TestGetStatusParsesHealthyTask()
        TestGetStatusFailsClosedOnCaptureOrJsonErrors()
    } catch as err {
        Fail("Unhandled service-manager test exception: " . err.Message)
    }

    if (TEST_FAILURES > 0) {
        LS_TestOutput("ServiceManagerTests failed: " . TEST_FAILURES . " failure(s)" . Chr(10))
        ExitApp(1)
    }

    LS_TestOutput("ServiceManagerTests passed" . Chr(10))
    ExitApp(0)
}

TestInstallRequiresAdmin() {
    RecordingServiceManager.Reset()
    RecordingServiceManager.adminResult := false

    result := RecordingServiceManager.Install()

    Assert(!result, "service install fails when administrator privileges are unavailable")
    Assert(RecordingServiceManager.commands.Length = 0, "service install does not touch Task Scheduler when authorization fails")
    Assert(RecordingServiceManager.captures.Length = 0, "service install does not invoke PowerShell when authorization fails")
}

TestInstallBuildsOnStartTaskDefinition() {
    RecordingServiceManager.Reset()

    result := RecordingServiceManager.Install()

    Assert(result, "service install succeeds when Task Scheduler accepts the request")
    Assert(RecordingServiceManager.commands.Length = 0, "service install does not use fragile schtasks quoting")
    Assert(RecordingServiceManager.captures.Length = 1, "service install invokes Task Scheduler once")
    script := RecordingServiceManager.captures[1]["script"]
    Assert(InStr(script, "Register-ScheduledTask") > 0, "service install registers a scheduled task")
    Assert(InStr(script, "New-ScheduledTaskAction") > 0, "service install creates a task action")
    Assert(InStr(script, "$taskPath = '\LabStation\'") > 0 && InStr(script, "$taskName = 'BackgroundService'") > 0, "service install uses the canonical task path and name")
    Assert(InStr(script, "-AtStartup") > 0, "service install starts the task at system startup")
    Assert(InStr(script, "-UserId 'SYSTEM'") > 0 && InStr(script, "-RunLevel Highest") > 0, "service install uses the required elevated system principal")
    Assert(InStr(script, "service-loop") > 0 && InStr(script, "LabStation.ahk") > 0, "service install points the task at the service loop")
    Assert(RecordingServiceManager.captures[1]["timeoutMs"] = LAB_STATION_LONG_COMMAND_TIMEOUT_MS, "service install uses the long command timeout")
}

TestInstallReportsTaskSchedulerFailure() {
    RecordingServiceManager.Reset()
    RecordingServiceManager.powershellResult := Map("exitCode", 5, "stdout", "", "stderr", "Task Scheduler rejected the request")

    result := RecordingServiceManager.Install()

    Assert(!result, "service install reports a Task Scheduler failure")
}

TestInstallEscapesPowerShellSingleQuotesAndKeepsArgumentsSeparate() {
    script := LS_ServiceManager.BuildInstallScript(
        "C:\Lab Station\O'Connor\LabStation.exe",
        "service-loop",
        "C:\Lab Station\O'Connor"
    )

    Assert(InStr(script, "$execute = 'C:\Lab Station\O''Connor\LabStation.exe'") > 0, "service install escapes apostrophes in the executable path")
    Assert(InStr(script, "$argumentList = 'service-loop'") > 0, "service install keeps the service argument separate from the executable")
    Assert(InStr(script, "$workingDirectory = 'C:\Lab Station\O''Connor'") > 0, "service install escapes apostrophes in the working directory")
}

TestUninstallUsesTaskNameAndReportsFailure() {
    RecordingServiceManager.Reset()
    RecordingServiceManager.commandResult := 5

    result := RecordingServiceManager.Uninstall()

    Assert(!result, "service uninstall reports a Task Scheduler failure")
    Assert(RecordingServiceManager.commands.Length = 1, "service uninstall invokes Task Scheduler once")
    Assert(InStr(RecordingServiceManager.commands[1]["command"], "schtasks /delete") > 0, "service uninstall deletes the scheduled task")
    Assert(InStr(RecordingServiceManager.commands[1]["command"], "LabStation\BackgroundService") > 0, "service uninstall uses the canonical task name")
}

TestStartAndStopUseTaskName() {
    RecordingServiceManager.Reset()

    startResult := RecordingServiceManager.Start()
    stopResult := RecordingServiceManager.Stop()

    Assert(startResult && stopResult, "service start and stop report successful Task Scheduler calls")
    Assert(RecordingServiceManager.commands.Length = 2, "service start and stop each invoke Task Scheduler once")
    Assert(InStr(RecordingServiceManager.commands[1]["command"], "schtasks /run") > 0, "service start runs the configured task")
    Assert(InStr(RecordingServiceManager.commands[2]["command"], "schtasks /end") > 0, "service stop ends the configured task")
}

TestStatusTextPrefersStdoutAndFallsBackToStderr() {
    RecordingServiceManager.Reset()
    RecordingServiceManager.powershellResult := Map("exitCode", 0, "stdout", "STATE : Running", "stderr", "warning")

    stdoutText := RecordingServiceManager.StatusText()

    RecordingServiceManager.powershellResult := Map("exitCode", 1, "stdout", "", "stderr", "ERROR: task missing")
    stderrText := RecordingServiceManager.StatusText()

    Assert(stdoutText = "STATE : Running", "service status prefers Task Scheduler stdout")
    Assert(stderrText = "ERROR: task missing", "service status falls back to stderr when stdout is empty")
}

TestGetStatusParsesHealthyTask() {
    RecordingServiceManager.Reset()
    RecordingServiceManager.powershellResult := Map(
        "exitCode", 0,
        "stdout", "{" . Chr(34) . "installed" . Chr(34) . ":true," . Chr(34) . "state" . Chr(34) . ":" . Chr(34) . "Running" . Chr(34) . "," . Chr(34) . "running" . Chr(34) . ":true," . Chr(34) . "restartable" . Chr(34) . ":true}",
        "stderr", ""
    )

    status := RecordingServiceManager.GetStatus()

    Assert(status["installed"] && status["running"] && status["restartable"], "service status parses a healthy scheduled task")
    Assert(status["state"] = "Running", "service status preserves the Task Scheduler state")
}

TestGetStatusFailsClosedOnCaptureOrJsonErrors() {
    RecordingServiceManager.Reset()
    RecordingServiceManager.powershellResult := Map("exitCode", 1, "stdout", "", "stderr", "query failed")

    captureFailure := RecordingServiceManager.GetStatus()

    RecordingServiceManager.powershellResult := Map("exitCode", 0, "stdout", "not-json", "stderr", "")
    jsonFailure := RecordingServiceManager.GetStatus()

    Assert(!captureFailure["installed"] && !captureFailure["running"] && !captureFailure["restartable"], "service status fails closed when the query command fails")
    Assert(!jsonFailure["installed"] && jsonFailure["state"] = "Unknown", "service status fails closed when the query payload is invalid")
}

Assert(condition, message) {
    if (!condition)
        Fail(message)
}

Fail(message) {
    global TEST_FAILURES
    TEST_FAILURES += 1
    LS_TestOutput(message . Chr(10))
}
