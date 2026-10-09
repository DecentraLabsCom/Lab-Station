#Requires AutoHotkey v2.0
#Include TestSupport.ahk
#Include ..\system\PowerManager.ahk

global TEST_FAILURES := 0

RunPowerManagerTests()

class RecordingPowerManager extends LS_PowerManager {
    static readinessResults := []
    static configureCalls := 0
    static commands := []
    static records := []
    static scheduleResult := 0

    static Reset(readiness := []) {
        this.readinessResults := readiness
        this.configureCalls := 0
        this.commands := []
        this.records := []
        this.scheduleResult := 0
    }

    static ValidateWakeReadiness() {
        if (this.readinessResults.Length = 0)
            return Map("ok", true, "issues", [], "wake", Map("armedCount", 1), "nics", [])
        result := this.readinessResults[1]
        this.readinessResults.RemoveAt(1)
        return result
    }

    static ConfigureWake() {
        this.configureCalls += 1
    }

    static ScheduleCommand(command, description) {
        this.commands.Push(Map("command", command, "description", description))
        return this.scheduleResult
    }

    static RecordPowerAction(success, mode, options, readiness) {
        this.records.Push(Map(
            "success", success,
            "mode", mode,
            "delay", options["delay"],
            "force", options["force"],
            "wakeReady", readiness["ok"]
        ))
    }
}

RunPowerManagerTests() {
    try {
        TestNormalizeOptionsUsesSafeDefaults()
        TestShutdownSkipsWakeCheckAndSchedulesCommand()
        TestWakeIssuesAreRepairedBeforePowerAction()
        TestWakeIssuesCanBlockPowerAction()
        TestWakeWarningsStillAllowPowerActionByDefault()
        TestScheduleFailureIsRecorded()
        TestBuildCommandsForShutdownAndHibernate()
    } catch as err {
        LS_TestFail("Unhandled power-manager test exception: " . err.Message)
    }

    if (TEST_FAILURES > 0) {
        LS_TestOutput("PowerManagerTests failed: " . TEST_FAILURES . " failure(s)`n")
        ExitApp(1)
    }

    LS_TestOutput("PowerManagerTests passed`n")
    ExitApp(0)
}

TestNormalizeOptionsUsesSafeDefaults() {
    options := LS_PowerManager.NormalizeOptions(Map("delay", -5, "force", false, "repairWake", false, "skipWakeCheck", true, "failOnWakeIssues", true))

    LS_TestAssert(options["delay"] = 0, "power manager clamps negative delays to zero")
    LS_TestAssert(!options["force"], "power manager preserves force=false")
    LS_TestAssert(!options["repairWake"], "power manager preserves repairWake=false")
    LS_TestAssert(options["skipWakeCheck"], "power manager preserves skipWakeCheck=true")
    LS_TestAssert(options["failOnWakeIssues"], "power manager preserves failOnWakeIssues=true")
    defaults := LS_PowerManager.NormalizeOptions(Map())
    LS_TestAssert(defaults["force"] && defaults["repairWake"], "power manager enables force and WoL repair by default")
}

TestShutdownSkipsWakeCheckAndSchedulesCommand() {
    RecordingPowerManager.Reset()

    result := RecordingPowerManager.Shutdown(Map(
        "delay", 60,
        "reason", "Reservation completed",
        "skipWakeCheck", true
    ))

    LS_TestAssert(result, "shutdown succeeds when scheduling succeeds")
    LS_TestAssert(RecordingPowerManager.configureCalls = 0, "skipping WoL check does not reconfigure wake")
    LS_TestAssert(RecordingPowerManager.commands.Length = 1, "shutdown schedules exactly one command")
    LS_TestAssert(InStr(RecordingPowerManager.commands[1]["command"], "shutdown /s /t 60") > 0, "shutdown command contains the requested delay")
    LS_TestAssert(InStr(RecordingPowerManager.commands[1]["command"], "/c " . Chr(34) . "Reservation completed" . Chr(34)) > 0, "shutdown command contains the reason")
    LS_TestAssert(RecordingPowerManager.records[1]["mode"] = "shutdown" && RecordingPowerManager.records[1]["success"], "shutdown records a successful power action")
    LS_TestAssert(RecordingPowerManager.records[1]["wakeReady"], "skipped WoL checks record readiness as true")
}

TestWakeIssuesAreRepairedBeforePowerAction() {
    RecordingPowerManager.Reset([
        Readiness(false, ["NIC not ready"]),
        Readiness(true, [])
    ])

    result := RecordingPowerManager.Shutdown(Map("repairWake", true))

    LS_TestAssert(result, "shutdown succeeds after wake configuration repairs readiness")
    LS_TestAssert(RecordingPowerManager.configureCalls = 1, "power manager repairs wake readiness once")
    LS_TestAssert(RecordingPowerManager.commands.Length = 1, "power manager schedules after readiness is repaired")
    LS_TestAssert(RecordingPowerManager.records[1]["wakeReady"], "power manager records repaired wake readiness")
}

TestWakeIssuesCanBlockPowerAction() {
    RecordingPowerManager.Reset([Readiness(false, ["No wake-armed devices"])])

    result := RecordingPowerManager.Shutdown(Map(
        "repairWake", false,
        "failOnWakeIssues", true
    ))

    LS_TestAssert(!result, "power manager fails when wake issues are required to be absent")
    LS_TestAssert(RecordingPowerManager.commands.Length = 0, "power manager does not schedule after a blocking wake failure")
    LS_TestAssert(!RecordingPowerManager.records[1]["success"], "power manager records the blocking wake failure")
}

TestWakeWarningsStillAllowPowerActionByDefault() {
    RecordingPowerManager.Reset([Readiness(false, ["NIC not ready"])])

    result := RecordingPowerManager.Shutdown(Map("repairWake", false))

    LS_TestAssert(result, "power manager allows shutdown when wake issues are warnings")
    LS_TestAssert(RecordingPowerManager.commands.Length = 1, "power manager schedules despite non-blocking wake warnings")
    LS_TestAssert(!RecordingPowerManager.records[1]["wakeReady"], "power manager records the wake warning state")
}

TestScheduleFailureIsRecorded() {
    RecordingPowerManager.Reset([Readiness(true, [])])
    RecordingPowerManager.scheduleResult := 5

    result := RecordingPowerManager.Hibernate(Map("delay", 30))

    LS_TestAssert(!result, "hibernate reports a failed scheduling command")
    LS_TestAssert(!RecordingPowerManager.records[1]["success"], "hibernate records the scheduling failure")
}

TestBuildCommandsForShutdownAndHibernate() {
    shutdown := LS_PowerManager.BuildCommand("shutdown", Map("delay", 10, "force", true, "reason", "Test"))
    hibernate := LS_PowerManager.BuildCommand("hibernate", Map("delay", 30, "force", false, "reason", "Night window"))
    quoted := LS_PowerManager.BuildReason("A " . Chr(34) . "quoted" . Chr(34) . " reason")

    LS_TestAssert(InStr(shutdown, "shutdown /s /t 10 /f") > 0, "shutdown command uses force and delay")
    LS_TestAssert(InStr(shutdown, "/c " . Chr(34) . "Test" . Chr(34)) > 0, "shutdown command includes a reason")
    LS_TestAssert(InStr(hibernate, "timeout /t 30 /nobreak") > 0, "delayed hibernate uses a timeout wrapper")
    LS_TestAssert(InStr(hibernate, "shutdown /h") > 0 && !InStr(hibernate, " /f "), "hibernate command respects force=false")
    LS_TestAssert(quoted = "/c " . Chr(34) . "A 'quoted' reason" . Chr(34), "power reasons sanitize embedded quotes")
}

Readiness(ok, issues) {
    return Map("ok", ok, "issues", issues, "wake", Map("armedCount", ok ? 1 : 0), "nics", [])
}
