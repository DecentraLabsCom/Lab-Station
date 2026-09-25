#Requires AutoHotkey v2.0
#Include TestSupport.ahk
#Include ..\..\controller\lib\Config.ahk
#Include ..\..\controller\lib\Utils.ahk
#Include ..\..\controller\lib\WindowClosing.ahk
#Include ..\..\controller\lib\CloseRequest.ahk
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
