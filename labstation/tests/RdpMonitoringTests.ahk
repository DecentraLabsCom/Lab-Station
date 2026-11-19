#Requires AutoHotkey v2.0
#Include TestSupport.ahk
#Include ..\core\Json.ahk
#Include ..\..\remote-app\lib\RdpMonitoring.ahk

global TEST_FAILURES := 0
global TEST_ROOT := A_Temp "\LabStation-RdpMonitoringTests-" A_TickCount
global ORIGINAL_DISCONNECT_CLOSE_FILE := CONTROLLER_DISCONNECT_CLOSE_FILE
global ORIGINAL_LEASE_STATE_FILE := CONTROLLER_LEASE_STATE_FILE

DirCreate(TEST_ROOT)
CONTROLLER_DISCONNECT_CLOSE_FILE := TEST_ROOT "\reservation-disconnect-close.json"
CONTROLLER_LEASE_STATE_FILE := TEST_ROOT "\reservation-lease-state.json"

RunRdpMonitoringTests()

RunRdpMonitoringTests() {
    global TEST_FAILURES, TEST_ROOT, CONTROLLER_DISCONNECT_CLOSE_FILE, CONTROLLER_LEASE_STATE_FILE
    global ORIGINAL_DISCONNECT_CLOSE_FILE, ORIGINAL_LEASE_STATE_FILE

    try {
        TestDisconnectGraceStartsAndReconnectCancels()
        TestDisconnectGraceExpiryClosesAndReports()
        TestReconnectAfterGraceExpiryClosesAndReports()
        TestDisconnectCloseReportRequiresAnActiveReservation()
    } catch as err {
        LS_TestFail("Unhandled RDP monitoring test exception: " . err.Message)
    }

    CONTROLLER_DISCONNECT_CLOSE_FILE := ORIGINAL_DISCONNECT_CLOSE_FILE
    CONTROLLER_LEASE_STATE_FILE := ORIGINAL_LEASE_STATE_FILE
    try DirDelete(TEST_ROOT, true)

    if (TEST_FAILURES > 0) {
        LS_TestOutput("RdpMonitoringTests failed: " . TEST_FAILURES . " failure(s)`n")
        ExitApp(1)
    }

    LS_TestOutput("RdpMonitoringTests passed`n")
    ExitApp(0)
}

TestDisconnectGraceStartsAndReconnectCancels() {
    global CONTROLLER_DISCONNECT_GRACE_ACTIVE, CONTROLLER_DISCONNECT_GRACE_STARTED_TICK
    global RDP_DISCONNECT_GRACE_MS

    LS_TestAssert(RDP_DISCONNECT_GRACE_MS = 120000, "Windows reconnect grace is configured for 120 seconds")
    CONTROLLER_DISCONNECT_GRACE_ACTIVE := false
    CONTROLLER_DISCONNECT_GRACE_STARTED_TICK := 0
    OnSessionChange(0x4, 0, 0, 0)
    startedTick := CONTROLLER_DISCONNECT_GRACE_STARTED_TICK
    LS_TestAssert(CONTROLLER_DISCONNECT_GRACE_ACTIVE, "RDP disconnect starts the reconnect grace")
    LS_TestAssert(startedTick > 0, "RDP disconnect records the grace start tick")

    OnSessionChange(0x4, 0, 0, 0)
    LS_TestAssert(CONTROLLER_DISCONNECT_GRACE_STARTED_TICK = startedTick,
        "duplicate RDP disconnect does not restart the grace")

    OnSessionChange(0x3, 0, 0, 0)
    LS_TestAssert(!CONTROLLER_DISCONNECT_GRACE_ACTIVE, "RDP reconnect before expiry cancels the grace")
    LS_TestAssert(CONTROLLER_DISCONNECT_GRACE_STARTED_TICK = 0, "cancelled grace clears its start tick")
}

TestDisconnectGraceExpiryClosesAndReports() {
    RunDisconnectChildAndAssert("expire", "RDP reconnection grace expired")
}

TestReconnectAfterGraceExpiryClosesAndReports() {
    RunDisconnectChildAndAssert("late-reconnect", "RDP reconnection grace expired")
}

RunDisconnectChildAndAssert(mode, expectedReason) {
    global TEST_ROOT
    reportPath := TEST_ROOT "\" mode "-report.json"
    leasePath := TEST_ROOT "\" mode "-lease.json"
    markerPath := TEST_ROOT "\" mode "-close.txt"
    try FileDelete(reportPath)
    try FileDelete(markerPath)
    FileAppend('{"active":{"kind":"reservation","state":"active","reservationKey":"reservation-1","labId":"42","leaseId":"lease-1","generation":7}}', leasePath, "UTF-8")

    childScript := A_ScriptDir "\RdpMonitoringDisconnectChild.ahk"
    command := '"' . A_AhkPath . '" /ErrorStdOut "' . childScript . '" "'
        . mode . '" "' . reportPath . '" "' . leasePath . '" "' . markerPath . '"'
    exitCode := RunWait(command, , "Hide")
    LS_TestAssert(exitCode = 0, mode . " child exits successfully after controlled close; exit=" . exitCode)
    LS_TestAssert(FileExist(reportPath), mode . " writes the reservation disconnect-close report")
    LS_TestAssert(FileExist(markerPath), mode . " invokes the controlled application close handler")

    if (FileExist(reportPath)) {
        report := LS_ParseJson(FileRead(reportPath, "UTF-8"))
        LS_TestAssert(Type(report) = "Map" && report.Has("success") && report["success"],
            mode . " reports a successful close")
        LS_TestAssert(report.Has("reservationKey") && report["reservationKey"] = "reservation-1",
            mode . " report identifies the active reservation")
        LS_TestAssert(report.Has("method") && report["method"] = "app-control",
            mode . " report records the AppControl close method")
    }

    if (FileExist(markerPath))
        LS_TestAssert(InStr(FileRead(markerPath, "UTF-8"), expectedReason),
            mode . " closes the workspace because the grace expired")
}

TestDisconnectCloseReportRequiresAnActiveReservation() {
    global CONTROLLER_LEASE_STATE_FILE, CONTROLLER_DISCONNECT_CLOSE_FILE

    try FileDelete(CONTROLLER_DISCONNECT_CLOSE_FILE)
    FileAppend('{"active":{"kind":"demo","state":"active","reservationKey":"demo:1","labId":"42","leaseId":"demo:1","generation":1}}',
        CONTROLLER_LEASE_STATE_FILE, "UTF-8")
    LS_TestAssert(!ControllerRecordReservationDisconnectClose(true),
        "non-reservation lease cannot produce a reservation disconnect-close report")
    LS_TestAssert(!FileExist(CONTROLLER_DISCONNECT_CLOSE_FILE),
        "non-reservation lease leaves no reservation close report")
}
