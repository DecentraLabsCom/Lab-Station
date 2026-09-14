#Requires AutoHotkey v2.0
#Include TestSupport.ahk

class LS_SessionGuard {
    static Run(options) {
        return true
    }
}

#Include ..\service\Recovery.ahk

global TEST_FAILURES := 0
global TEST_ROOT := A_Temp "\LabStation-RecoveryTests-" A_TickCount
global ORIGINAL_STATE_FILE := LAB_STATION_SERVICE_STATE_FILE

DirCreate(TEST_ROOT)
LAB_STATION_SERVICE_STATE_FILE := TEST_ROOT "\service-state.ini"

RunRecoveryTests()

class RecordingRecovery extends LS_Recovery {
    static recordedStatus := Map()
    static calls := []
    static rebootResult := true

    static Reset(status) {
        this.recordedStatus := status
        this.calls := []
        this.rebootResult := true
        try FileDelete(LAB_STATION_SERVICE_STATE_FILE)
    }

    static CollectStatus() {
        return this.recordedStatus
    }

    static CloseControllerProcesses() {
        this.calls.Push(Map("name", "close-controller"))
        return true
    }

    static LogoffLabUser(user := "") {
        this.calls.Push(Map("name", "logoff", "user", user))
        return true
    }

    static TriggerReboot(timeout := 0) {
        this.calls.Push(Map("name", "reboot", "timeout", timeout))
        return this.rebootResult
    }
}

RunRecoveryTests() {
    global ORIGINAL_STATE_FILE, LAB_STATION_SERVICE_STATE_FILE, TEST_ROOT

    try {
        TestHealthyStateSkipsReboot()
        TestUnhealthyStateRunsCleanupAndReboot()
        TestFailedRebootIsReportedAndRecorded()
        TestForcedRecoveryShortCircuitsStatusReasons()
        TestReasonsAreDistinctAndCaseInsensitive()
    } catch as err {
        Fail("Unhandled recovery test exception: " . err.Message)
    }

    LAB_STATION_SERVICE_STATE_FILE := ORIGINAL_STATE_FILE
    try DirDelete(TEST_ROOT, true)

    if (TEST_FAILURES > 0) {
        LS_TestOutput("RecoveryTests failed: " . TEST_FAILURES . " failure(s)`n")
        ExitApp(1)
    }

    LS_TestOutput("RecoveryTests passed`n")
    ExitApp(0)
}

TestHealthyStateSkipsReboot() {
    RecordingRecovery.Reset(HealthyStatus())

    result := RecordingRecovery.RebootIfNeeded()

    Assert(result["success"], "healthy recovery result is successful")
    Assert(result["skipped"], "healthy recovery skips the reboot")
    Assert(result["reason"] = "healthy", "healthy recovery explains why reboot was skipped")
    Assert(RecordingRecovery.calls.Length = 0, "healthy recovery does not close, log off, or reboot")
    state := LS_ServiceState.ReadSection("safeguard-reboot")
    Assert(state["success"] && state["rebooted"] = false, "healthy recovery records a skipped safeguard")
}

TestUnhealthyStateRunsCleanupAndReboot() {
    RecordingRecovery.Reset(UnhealthyStatus())

    result := RecordingRecovery.RebootIfNeeded(Map("timeout", 15, "user", "LABUSER"))

    Assert(result["success"] && result["rebooted"], "unhealthy recovery schedules the reboot")
    Assert(RecordingRecovery.calls.Length = 3, "unhealthy recovery performs all cleanup steps")
    Assert(RecordingRecovery.calls[1]["name"] = "close-controller", "recovery closes controller processes first")
    Assert(RecordingRecovery.calls[2]["name"] = "logoff", "recovery logs off the configured user second")
    Assert(RecordingRecovery.calls[2]["user"] = "LABUSER", "recovery forwards the configured user")
    Assert(RecordingRecovery.calls[3]["name"] = "reboot", "recovery schedules reboot after cleanup")
    Assert(RecordingRecovery.calls[3]["timeout"] = 15, "recovery forwards the reboot timeout")
    Assert(InStr(result["reason"], "other-users-active") > 0, "recovery records the active-user reason")
    state := LS_ServiceState.ReadSection("safeguard-reboot")
    Assert(state["success"] && state["rebooted"], "recovery records the successful safeguard")
}

TestFailedRebootIsReportedAndRecorded() {
    RecordingRecovery.Reset(UnhealthyStatus())
    RecordingRecovery.rebootResult := false

    result := RecordingRecovery.RebootIfNeeded(Map("timeout", 20))

    Assert(!result["success"] && !result["rebooted"], "recovery reports a failed reboot schedule")
    Assert(RecordingRecovery.calls.Length = 3, "recovery attempts cleanup before reporting reboot failure")
    state := LS_ServiceState.ReadSection("safeguard-reboot")
    Assert(!state["success"] && state["rebooted"] = false, "recovery records the failed safeguard")
}

TestForcedRecoveryShortCircuitsStatusReasons() {
    reasons := LS_Recovery.ResolveReasons(UnhealthyStatus(), Map("force", true))

    Assert(reasons.Length = 1, "forced recovery uses one explicit reason")
    Assert(reasons[1] = "forced-by-backend", "forced recovery identifies the backend override")
}

TestReasonsAreDistinctAndCaseInsensitive() {
    reasons := LS_Recovery.DistinctReasons(["RemoteApp-Disabled", "remoteapp-disabled", "", "Other-users-active"])

    Assert(reasons.Length = 2, "recovery removes duplicate and empty reasons")
    Assert(reasons[1] = "RemoteApp-Disabled" && reasons[2] = "Other-users-active", "recovery preserves the first spelling of each reason")
}

HealthyStatus() {
    return Map(
        "summary", Map("state", "ready", "issues", []),
        "sessions", Map("hasOtherUsers", false),
        "remoteAppEnabled", true,
        "autoStartConfigured", true,
        "policy", Map(
            "autoLogon", Map("enabled", true),
            "remoteDesktopUsers", Map("otherMembers", [])
        )
    )
}

UnhealthyStatus() {
    return Map(
        "summary", Map("state", "degraded", "issues", ["RemoteApp disabled"]),
        "sessions", Map("hasOtherUsers", true),
        "remoteAppEnabled", false,
        "autoStartConfigured", false,
        "policy", Map(
            "autoLogon", Map("enabled", false),
            "remoteDesktopUsers", Map("otherMembers", ["OtherUser"])
        )
    )
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
