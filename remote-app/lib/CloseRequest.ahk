; ============================================================================
; CloseRequest.ahk - Cooperative AppControl close handshake
; ============================================================================
; Lab Station runs under WinRM/service context while AppControl runs in the
; interactive RemoteApp session. A small file handshake crosses that boundary
; without force-killing the controller or relying on a particular desktop
; session/window handle.
; ============================================================================
#Include Config.ahk
#Include Utils.ahk
#Include WindowClosing.ahk

ControllerRegisterPresence() {
    global CONTROLLER_CLOSE_PRESENCE_TOKEN, CONTROLLER_DATA_DIR, CONTROLLER_PRESENCE_FILE

    try DirCreate(CONTROLLER_DATA_DIR)
    processId := DllCall("GetCurrentProcessId")
    CONTROLLER_CLOSE_PRESENCE_TOKEN := processId . "|" . A_TickCount
    if (!ControllerWriteAtomic(CONTROLLER_PRESENCE_FILE, CONTROLLER_CLOSE_PRESENCE_TOKEN)) {
        Log("WARNING: Could not publish controller presence", "WARNING")
    }
    OnExit(ControllerClearPresence)
}

ControllerRecordReservationDisconnectClose(success) {
    global CONTROLLER_DISCONNECT_CLOSE_FILE, CONTROLLER_LEASE_STATE_FILE

    try {
        state := LS_ParseJson(FileRead(CONTROLLER_LEASE_STATE_FILE, "UTF-8"))
    } catch {
        Log("Could not read the active reservation lease after disconnect cleanup", "WARNING")
        return false
    }
    if (Type(state) != "Map" || !state.Has("active") || Type(state["active"]) != "Map")
        return false

    lease := state["active"]
    required := ["kind", "state", "reservationKey", "labId", "leaseId", "generation"]
    for key in required {
        if (!lease.Has(key))
            return false
    }
    if (lease["kind"] != "reservation" || lease["state"] != "active"
        || Type(lease["reservationKey"]) != "String" || lease["reservationKey"] = ""
        || Type(lease["labId"]) != "String" || lease["labId"] = ""
        || Type(lease["leaseId"]) != "String" || lease["leaseId"] = ""
        || !IsInteger(lease["generation"]) || lease["generation"] < 1)
        return false

    completedAt := ControllerUtcTimestampMilliseconds()
    record := Map(
        "reservationKey", lease["reservationKey"],
        "labId", lease["labId"],
        "leaseId", lease["leaseId"],
        "generation", lease["generation"],
        "success", success,
        "completedAt", completedAt,
        "method", "app-control"
    )
    if (!ControllerWriteAtomic(CONTROLLER_DISCONNECT_CLOSE_FILE, LS_ToJson(record))) {
        Log("Could not publish reservation disconnect-close completion", "WARNING")
        return false
    }
    return true
}

ControllerUtcTimestampMilliseconds() {
    stamp := A_NowUTC
    millisecond := A_MSec
    if (stamp != A_NowUTC) {
        stamp := A_NowUTC
        millisecond := A_MSec
    }
    return FormatTime(stamp, "yyyy-MM-ddTHH:mm:ss") . "." . Format("{:03}", millisecond) . "Z"
}

ControllerClearPresence(*) {
    global CONTROLLER_CLOSE_PRESENCE_TOKEN, CONTROLLER_PRESENCE_FILE

    if (CONTROLLER_CLOSE_PRESENCE_TOKEN = "")
        return
    try {
        if (FileExist(CONTROLLER_PRESENCE_FILE)
            && Trim(FileRead(CONTROLLER_PRESENCE_FILE, "UTF-8")) = CONTROLLER_CLOSE_PRESENCE_TOKEN) {
            FileDelete(CONTROLLER_PRESENCE_FILE)
        }
    } catch as e {
        Log("WARNING: Could not clear controller presence: " . e.Message, "WARNING")
    }
}

ControllerSetupCloseRequestMonitoring() {
    global CONTROLLER_CLOSE_REQUEST_POLL_MS
    SetTimer(ControllerCheckCloseRequest, CONTROLLER_CLOSE_REQUEST_POLL_MS)
}

ControllerCheckCloseRequest(*) {
    global CONTROLLER_CLOSE_REQUEST_FILE, CONTROLLER_CLOSE_REQUEST_START_TICK
    global CONTROLLER_CLOSE_REQUEST_LAST_TOKEN, CONTROLLER_CLOSE_REQUEST_HANDLED
    global WORKSPACE_MODE, target

    if (CONTROLLER_CLOSE_REQUEST_HANDLED || !FileExist(CONTROLLER_CLOSE_REQUEST_FILE))
        return
    if (CONTROLLER_CLOSE_IN_PROGRESS)
        return

    try {
        token := Trim(FileRead(CONTROLLER_CLOSE_REQUEST_FILE, "UTF-8"))
    } catch {
        return
    }
    if (token = "" || token = CONTROLLER_CLOSE_REQUEST_LAST_TOKEN)
        return

    requestTick := ControllerRequestTick(token)
    if (!requestTick)
        return
    if (requestTick <= CONTROLLER_CLOSE_REQUEST_START_TICK)
        return

    CONTROLLER_CLOSE_REQUEST_LAST_TOKEN := token
    CONTROLLER_CLOSE_REQUEST_HANDLED := true
    Log("Cooperative controller close requested", "INFO")

    success := ControllerCloseManagedApps("Lab Station release request")

    ControllerWriteCloseResult(token, success)
    try FileDelete(CONTROLLER_CLOSE_REQUEST_FILE)

    if (success) {
        Log("Controlled lab application close completed", "INFO")
        ControllerClearPresence()
        ExitApp(0)
    }

    Log("Controlled lab application close did not complete; controller remains active", "ERROR")
}

ControllerCloseManagedApps(reason) {
    global CONTROLLER_CLOSE_IN_PROGRESS, CONTROLLER_DISCONNECT_GRACE_ACTIVE
    global WORKSPACE_MODE, target

    if (CONTROLLER_CLOSE_IN_PROGRESS)
        return false

    CONTROLLER_CLOSE_IN_PROGRESS := true
    CONTROLLER_DISCONNECT_GRACE_ACTIVE := false
    SetTimer(ControllerDisconnectGraceExpired, 0)
    success := false
    try {
        if (WORKSPACE_MODE)
            success := ControllerCloseWorkspace(reason)
        else if (target != "")
            success := ForceCloseWindow(target, 3)
    } catch as e {
        Log("Controlled application close failed (" . reason . "): " . e.Message, "ERROR")
    }

    if (!success)
        CONTROLLER_CLOSE_IN_PROGRESS := false
    return success
}

ControllerCloseWorkspace(reason) {
    global WORKSPACE_CLOSE_HANDLER
    if (!IsObject(WORKSPACE_CLOSE_HANDLER))
        throw Error("Workspace close handler is not initialized")
    return WORKSPACE_CLOSE_HANDLER.Call(reason)
}

ControllerWriteCloseResult(token, success) {
    global CONTROLLER_CLOSE_RESULT_FILE
    status := success ? "ok" : "failed"
    if (!ControllerWriteAtomic(CONTROLLER_CLOSE_RESULT_FILE, token . "|" . status))
        Log("WARNING: Could not publish controller close result", "WARNING")
}

ControllerWriteAtomic(path, content) {
    tempPath := path . ".tmp-" . A_TickCount
    try {
        if (FileExist(tempPath))
            FileDelete(tempPath)
        FileAppend(content, tempPath, "UTF-8")
        FileMove(tempPath, path, 1)
        return true
    } catch as e {
        try FileDelete(tempPath)
        Log("WARNING: Could not write controller handshake file: " . e.Message, "WARNING")
        return false
    }
}

ControllerRequestTick(token) {
    if RegExMatch(token, "^(\d+)-", &match)
        return match[1] + 0
    return 0
}
