#Requires AutoHotkey v2.0
#Include TestSupport.ahk
#Include ..\..\remote-app\lib\Config.ahk
#Include ..\..\remote-app\lib\Utils.ahk
#Include ..\..\remote-app\lib\WindowClosing.ahk
#Include ..\..\remote-app\lib\RdpMonitoring.ahk
#Include ..\service\SessionGuard.ahk
#Include ..\service\FmuExecutor.ahk
#Include ..\service\SessionManager.ahk

global TEST_FAILURES := 0
global TEST_ROOT := A_Temp "\LabStation-ControllerCloseRequestTests-" A_TickCount
global ORIGINAL_PRESENCE_FILE := LAB_STATION_CONTROLLER_PRESENCE_FILE

DirCreate(TEST_ROOT)
LAB_STATION_CONTROLLER_PRESENCE_FILE := TEST_ROOT "\controller-presence.txt"

RunControllerCloseRequestTests()

RunControllerCloseRequestTests() {
    global TEST_FAILURES, ORIGINAL_PRESENCE_FILE, LAB_STATION_CONTROLLER_PRESENCE_FILE, TEST_ROOT

    try {
        TestControllerRequestParsing()
        TestControllerResultMatching()
        TestControllerPresenceParsing()
        TestControllerPresenceRejectsStaleMarker()
        TestControllerPresenceRejectsMalformedMarker()
        TestReservationDisconnectCleanupRequiresCloseAndReportSuccess()
        TestReservationDisconnectCleanupLogsOffOnlyAfterSuccessfulReport()
        TestReservationDisconnectCleanupReportsLogoffFailure()
        TestRealSessionLogoffIsDisabledInTestMode()
    } catch as err {
        LS_TestFail("Unhandled controller-close test exception: " . err.Message)
    }

    LAB_STATION_CONTROLLER_PRESENCE_FILE := ORIGINAL_PRESENCE_FILE
    try DirDelete(TEST_ROOT, true)

    if (TEST_FAILURES > 0) {
        LS_TestOutput("ControllerCloseRequestTests failed: " . TEST_FAILURES . " failure(s)`n")
        ExitApp(1)
    }

    LS_TestOutput("ControllerCloseRequestTests passed`n")
    ExitApp(0)
}

TestControllerRequestParsing() {
    LS_TestAssert(ControllerRequestTick("12345-20260924200000-1234") = 12345,
        "controller request token exposes its creation tick")
    LS_TestAssert(ControllerRequestTick("not-a-request") = 0,
        "malformed controller request token is ignored")
}

TestControllerResultMatching() {
    token := "12345-20260924200000-1234"
    LS_TestAssert(LS_SessionManager.CloseResultMatches(token . "|ok", token, "ok"),
        "session manager accepts the matching successful result")
    LS_TestAssert(!LS_SessionManager.CloseResultMatches(token . "|failed", token, "ok"),
        "session manager rejects a result with the wrong status")
}

TestControllerPresenceParsing() {
    global LAB_STATION_CONTROLLER_PRESENCE_FILE
    pid := DllCall("GetCurrentProcessId")
    FileAppend(pid . "|" . A_TickCount, LAB_STATION_CONTROLLER_PRESENCE_FILE, "UTF-8")

    presence := LS_SessionManager.ReadControllerPresence()
    LS_TestAssert(presence["present"], "a live controller marker is detected")
    LS_TestAssert(presence["pid"] = pid, "controller marker PID is preserved")
    LS_TestAssert(!presence["stale"], "a live controller marker is not stale")
    try FileDelete(LAB_STATION_CONTROLLER_PRESENCE_FILE)
}

TestControllerPresenceRejectsStaleMarker() {
    global LAB_STATION_CONTROLLER_PRESENCE_FILE
    FileAppend("4294967295|" . A_TickCount, LAB_STATION_CONTROLLER_PRESENCE_FILE, "UTF-8")

    presence := LS_SessionManager.ReadControllerPresence()
    LS_TestAssert(!presence["present"], "a dead controller PID is not treated as active")
    LS_TestAssert(presence["stale"], "a dead controller marker is reported as stale")
    LS_TestAssert(!FileExist(LAB_STATION_CONTROLLER_PRESENCE_FILE), "stale controller marker is removed")
}

TestControllerPresenceRejectsMalformedMarker() {
    global LAB_STATION_CONTROLLER_PRESENCE_FILE
    FileAppend("not-a-marker", LAB_STATION_CONTROLLER_PRESENCE_FILE, "UTF-8")

    presence := LS_SessionManager.ReadControllerPresence()
    LS_TestAssert(!presence["present"], "a malformed controller marker is not treated as active")
    LS_TestAssert(presence["stale"], "a malformed controller marker is reported as stale")
    LS_TestAssert(!FileExist(LAB_STATION_CONTROLLER_PRESENCE_FILE), "malformed controller marker is removed")
}

TestReservationDisconnectCleanupRequiresCloseAndReportSuccess() {
    hooks := ControllerCloseTestHooks()
    completed := ControllerCompleteReservationDisconnectClose(
        false,
        success => ControllerCloseTestRecord(hooks, success),
        () => ControllerCloseTestLogoff(hooks)
    )

    LS_TestAssert(!completed, "failed application cleanup is not reported as a completed disconnect close")
    LS_TestAssert(hooks["records"].Length = 1 && hooks["records"][1] = false,
        "failed application cleanup publishes a failed close result")
    LS_TestAssert(hooks["logoffCalls"] = 0,
        "failed application cleanup leaves the disconnected desktop for Gateway retry")

    hooks := ControllerCloseTestHooks()
    hooks["recordResult"] := false
    completed := ControllerCompleteReservationDisconnectClose(
        true,
        success => ControllerCloseTestRecord(hooks, success),
        () => ControllerCloseTestLogoff(hooks)
    )

    LS_TestAssert(!completed, "a close result that could not be published is not complete")
    LS_TestAssert(hooks["logoffCalls"] = 0,
        "failure to publish the close result leaves the disconnected desktop for Gateway retry")
}

TestReservationDisconnectCleanupLogsOffOnlyAfterSuccessfulReport() {
    hooks := ControllerCloseTestHooks()
    completed := ControllerCompleteReservationDisconnectClose(
        true,
        success => ControllerCloseTestRecord(hooks, success),
        () => ControllerCloseTestLogoff(hooks)
    )

    LS_TestAssert(completed, "successful application close, report and logoff complete the disconnect cleanup")
    LS_TestAssert(hooks["records"].Length = 2 && hooks["records"][1] = false && hooks["records"][2] = true,
        "successful application cleanup is reported only after the desktop logoff request")
    LS_TestAssert(hooks["logoffCalls"] = 1,
        "a successfully reported disconnect cleanup logs off the local RDP session")
    LS_TestAssert(hooks["events"].Length = 3 && hooks["events"][1] = "record:false"
        && hooks["events"][2] = "logoff" && hooks["events"][3] = "record:true",
        "the status write is checked before logoff and success is published after it")
}

TestReservationDisconnectCleanupReportsLogoffFailure() {
    hooks := ControllerCloseTestHooks()
    hooks["logoffResult"] := false
    completed := ControllerCompleteReservationDisconnectClose(
        true,
        success => ControllerCloseTestRecord(hooks, success),
        () => ControllerCloseTestLogoff(hooks)
    )

    LS_TestAssert(!completed, "a failed desktop logoff does not report full disconnect cleanup")
    LS_TestAssert(hooks["records"].Length = 1 && hooks["records"][1] = false,
        "a failed desktop logoff leaves a retryable failure result")
    LS_TestAssert(hooks["logoffCalls"] = 1,
        "desktop logoff is attempted once after application close and report")
    LS_TestAssert(hooks["events"].Length = 2 && hooks["events"][1] = "record:false"
        && hooks["events"][2] = "logoff",
        "a failed desktop logoff is never reported as successful")
}

TestRealSessionLogoffIsDisabledInTestMode() {
    global CONTROLLER_ALLOW_CURRENT_SESSION_LOGOFF, CONTROLLER_CURRENT_SESSION_LOGOFF_HANDLER
    CONTROLLER_ALLOW_CURRENT_SESSION_LOGOFF := true
    CONTROLLER_CURRENT_SESSION_LOGOFF_HANDLER := ""

    requested := ControllerLogoffCurrentSession()

    LS_TestAssert(!requested, "test mode refuses the real WTS logoff API even if production opt-in is set")
}

ControllerCloseTestHooks() {
    return Map("records", [], "events", [], "recordResult", true, "logoffCalls", 0, "logoffResult", true)
}

ControllerCloseTestRecord(hooks, success) {
    hooks["records"].Push(success)
    hooks["events"].Push("record:" . (success ? "true" : "false"))
    return hooks["recordResult"]
}

ControllerCloseTestLogoff(hooks) {
    hooks["logoffCalls"] += 1
    hooks["events"].Push("logoff")
    return hooks["logoffResult"]
}
