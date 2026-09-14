#Requires AutoHotkey v2.0
#Include TestSupport.ahk

class LS_SessionGuard {
    static Run(options) {
        return true
    }
}

class LS_FmuExecutor {
    static TerminateAllSessions() {
    }

    static CleanTempState() {
    }
}

#Include ..\service\SessionManager.ahk

global TEST_FAILURES := 0
global TEST_ROOT := A_Temp "\LabStation-ReservationFlowTests-" A_TickCount
global ORIGINAL_STATE_FILE := LAB_STATION_SERVICE_STATE_FILE

DirCreate(TEST_ROOT)
LAB_STATION_SERVICE_STATE_FILE := TEST_ROOT "\service-state.ini"

RunReservationFlowTests()

class RecordingSessionManager extends LS_SessionManager {
    static calls := []
    static guardResult := true
    static closeResult := true
    static fmuResult := true
    static clearResult := true
    static resetResult := true
    static logoffResult := true
    static rebootResult := true

    static Reset() {
        this.calls := []
        this.guardResult := true
        this.closeResult := true
        this.fmuResult := true
        this.clearResult := true
        this.resetResult := true
        this.logoffResult := true
        this.rebootResult := true
        try FileDelete(LAB_STATION_SERVICE_STATE_FILE)
    }

    static RunSessionGuard(options) {
        this.calls.Push(Map("name", "guard", "options", options))
        return this.guardResult
    }

    static CloseControllerProcesses() {
        this.calls.Push(Map("name", "close-controller"))
        return this.closeResult
    }

    static CleanFmuExecutorState() {
        this.calls.Push(Map("name", "fmu-cleanup"))
        return this.fmuResult
    }

    static ClearLabUserWorkingDirs(user := "") {
        this.calls.Push(Map("name", "clear-profile", "user", user))
        return this.clearResult
    }

    static ResetControllerLogs() {
        this.calls.Push(Map("name", "reset-controller"))
        return this.resetResult
    }

    static LogoffLabUser(user := "", force := true) {
        this.calls.Push(Map("name", "logoff", "user", user, "force", force))
        return this.logoffResult
    }

    static TriggerReboot(timeout := 0) {
        this.calls.Push(Map("name", "reboot", "timeout", timeout))
        return this.rebootResult
    }
}

RunReservationFlowTests() {
    global ORIGINAL_STATE_FILE, LAB_STATION_SERVICE_STATE_FILE, TEST_ROOT

    try {
        TestPrepareSessionSuccess()
        TestPrepareSessionFailureStillRunsCleanup()
        TestReleaseSessionWithoutReboot()
        TestReleaseSessionWithReboot()
        TestReleaseSessionFailureStillRecordsFailure()
    } catch as err {
        Fail("Unhandled reservation-flow test exception: " . err.Message)
    }

    LAB_STATION_SERVICE_STATE_FILE := ORIGINAL_STATE_FILE
    try DirDelete(TEST_ROOT, true)

    if (TEST_FAILURES > 0) {
        LS_TestOutput("ReservationFlowTests failed: " . TEST_FAILURES . " failure(s)`n")
        ExitApp(1)
    }

    LS_TestOutput("ReservationFlowTests passed`n")
    ExitApp(0)
}

TestPrepareSessionSuccess() {
    RecordingSessionManager.Reset()

    options := Map(
        "user", "LABUSER",
        "guard", false,
        "extraCleaners", [TestExtraCleaner]
    )

    success := RecordingSessionManager.PrepareSession(options)

    Assert(success, "prepare-session succeeds when all operations succeed")
    AssertCallSequence([
        "guard",
        "close-controller",
        "fmu-cleanup",
        "clear-profile",
        "reset-controller",
        "extra-cleaner"
    ], "prepare-session operation order")

    guardCall := RecordingSessionManager.calls[1]
    Assert(guardCall["options"]["guard"] = false, "prepare-session forwards guard=false")
    Assert(RecordingSessionManager.calls[4]["user"] = "LABUSER", "prepare-session forwards the selected user")

    state := LS_ServiceState.ReadSection("prepare-session")
    Assert(state.Has("success") && state["success"], "prepare-session records success")
    Assert(state.Has("user") && state["user"] = "LABUSER", "prepare-session records the selected user")
}

TestPrepareSessionFailureStillRunsCleanup() {
    RecordingSessionManager.Reset()
    RecordingSessionManager.clearResult := false

    success := RecordingSessionManager.PrepareSession(Map("user", "LABUSER"))

    Assert(!success, "prepare-session reports failure when profile cleanup fails")
    AssertCallSequence([
        "guard",
        "close-controller",
        "fmu-cleanup",
        "clear-profile",
        "reset-controller"
    ], "prepare-session continues cleanup after a failed operation")

    state := LS_ServiceState.ReadSection("prepare-session")
    Assert(state.Has("success") && !state["success"], "prepare-session records failure")
}

TestReleaseSessionWithoutReboot() {
    RecordingSessionManager.Reset()

    success := RecordingSessionManager.ReleaseSession(Map("user", "LABUSER"))

    Assert(success, "release-session succeeds without reboot")
    AssertCallSequence([
        "close-controller",
        "fmu-cleanup",
        "logoff"
    ], "release-session does not reboot by default")

    state := LS_ServiceState.ReadSection("release-session")
    Assert(state.Has("success") && state["success"], "release-session records success")
    Assert(!state.Has("rebootRequested"), "release-session omits reboot metadata when not requested")
}

TestReleaseSessionWithReboot() {
    RecordingSessionManager.Reset()

    options := Map("user", "LABUSER", "reboot", true, "rebootTimeout", 15)
    success := RecordingSessionManager.ReleaseSession(options)

    Assert(success, "release-session succeeds with reboot")
    AssertCallSequence([
        "close-controller",
        "fmu-cleanup",
        "logoff",
        "reboot"
    ], "release-session reboots after cleanup")
    Assert(RecordingSessionManager.calls[4]["timeout"] = 15, "release-session forwards reboot timeout")

    state := LS_ServiceState.ReadSection("release-session")
    Assert(state.Has("rebootRequested") && state["rebootRequested"], "release-session records reboot request")
    Assert(state.Has("rebootTimeout") && state["rebootTimeout"] = 15, "release-session records reboot timeout")
}

TestReleaseSessionFailureStillRecordsFailure() {
    RecordingSessionManager.Reset()
    RecordingSessionManager.logoffResult := false

    success := RecordingSessionManager.ReleaseSession(Map(
        "user", "LABUSER",
        "reboot", true,
        "rebootTimeout", 20
    ))

    Assert(!success, "release-session reports failure when logoff fails")
    AssertCallSequence([
        "close-controller",
        "fmu-cleanup",
        "logoff",
        "reboot"
    ], "release-session attempts the requested reboot after a failed cleanup step")

    state := LS_ServiceState.ReadSection("release-session")
    Assert(state.Has("success") && !state["success"], "release-session records failure")
}

TestExtraCleaner(*) {
    RecordingSessionManager.calls.Push(Map("name", "extra-cleaner"))
    return true
}

AssertCallSequence(expectedNames, description) {
    actualNames := []
    for call in RecordingSessionManager.calls
        actualNames.Push(call["name"])

    if (actualNames.Length != expectedNames.Length) {
        Fail(description . " expected " . expectedNames.Length . " calls but got " . actualNames.Length)
        return
    }

    for index, expectedName in expectedNames {
        if (actualNames[index] != expectedName) {
            Fail(description . " mismatch at position " . index . " (expected " . expectedName . ", got " . actualNames[index] . ")")
        }
    }
}

Assert(condition, message) {
    if (!condition)
        Fail(message)
}

Fail(message) {
    global TEST_FAILURES
    TEST_FAILURES += 1
    LS_TestOutput(message . "`n")
}
