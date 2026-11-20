#Requires AutoHotkey v2.0
#Include TestSupport.ahk
#Include ..\core\Json.ahk
#Include ..\..\remote-app\lib\RdpMonitoring.ahk

global RDP_TEST_CLOSE_MARKER := ""
global RDP_TEST_LOGOFF_MARKER := ""
global PRODUCTION_MODE := true
RunDisconnectGraceChild()

RunDisconnectGraceChild() {
    global CONTROLLER_DISCONNECT_CLOSE_FILE, CONTROLLER_LEASE_STATE_FILE
    global CONTROLLER_DISCONNECT_GRACE_ACTIVE, CONTROLLER_DISCONNECT_GRACE_STARTED_TICK
    global CONTROLLER_CLOSE_IN_PROGRESS, RDP_DISCONNECT_GRACE_MS
    global WORKSPACE_MODE, WORKSPACE_CLOSE_HANDLER, RDP_TEST_CLOSE_MARKER
    global CONTROLLER_CURRENT_SESSION_LOGOFF_HANDLER, RDP_TEST_LOGOFF_MARKER

    if (A_Args.Length < 5)
        ExitApp(3)

    mode := A_Args[1]
    CONTROLLER_DISCONNECT_CLOSE_FILE := A_Args[2]
    CONTROLLER_LEASE_STATE_FILE := A_Args[3]
    RDP_TEST_CLOSE_MARKER := A_Args[4]
    RDP_TEST_LOGOFF_MARKER := A_Args[5]
    CONTROLLER_CURRENT_SESSION_LOGOFF_HANDLER := RdpTestLogoffCurrentSession
    RDP_DISCONNECT_GRACE_MS := 50
    CONTROLLER_DISCONNECT_GRACE_ACTIVE := false
    CONTROLLER_DISCONNECT_GRACE_STARTED_TICK := 0
    CONTROLLER_CLOSE_IN_PROGRESS := false
    WORKSPACE_MODE := true
    WORKSPACE_CLOSE_HANDLER := RdpTestWorkspaceClose

    if (mode = "expire") {
        ControllerStartDisconnectGrace("RDP disconnect unit test")
        ; Exercise the expiry handler directly. The RDP test uses its injected
        ; logoff callback and never waits for or invokes the real Windows API.
        ControllerDisconnectGraceExpired()
        ExitApp(4)
    }

    if (mode = "late-reconnect") {
        CONTROLLER_DISCONNECT_GRACE_ACTIVE := true
        CONTROLLER_DISCONNECT_GRACE_STARTED_TICK := A_TickCount - RDP_DISCONNECT_GRACE_MS
        OnSessionChange(0x3, 0, 0, 0)
        ExitApp(5)
    }

    ExitApp(6)
}

RdpTestWorkspaceClose(reason) {
    global RDP_TEST_CLOSE_MARKER
    FileAppend(reason, RDP_TEST_CLOSE_MARKER, "UTF-8")
    return true
}

RdpTestLogoffCurrentSession() {
    global RDP_TEST_LOGOFF_MARKER
    FileAppend("requested", RDP_TEST_LOGOFF_MARKER, "UTF-8")
    return true
}
