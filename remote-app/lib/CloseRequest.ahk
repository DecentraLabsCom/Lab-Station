; ============================================================================
; CloseRequest.ahk - Cooperative AppControl close handshake
; ============================================================================
; Lab Station runs under WinRM/service context while AppControl runs in the
; interactive RemoteApp session. A small file handshake crosses that boundary
; without force-killing the controller or relying on a particular desktop
; session/window handle.
; ============================================================================

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
    global DUAL_APP_MODE, containerHwnd, target

    if (CONTROLLER_CLOSE_REQUEST_HANDLED || !FileExist(CONTROLLER_CLOSE_REQUEST_FILE))
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

    closeTarget := DUAL_APP_MODE
        ? (containerHwnd ? "ahk_id " . containerHwnd : "")
        : target
    success := false
    if (closeTarget != "") {
        try {
            success := ForceCloseWindow(closeTarget, 3)
        } catch as e {
            Log("Controller close failed: " . e.Message, "ERROR")
        }
    }

    ControllerWriteCloseResult(token, success)
    try FileDelete(CONTROLLER_CLOSE_REQUEST_FILE)

    if (success) {
        Log("Controlled lab application close completed", "INFO")
        ControllerClearPresence()
        ExitApp(0)
    }

    Log("Controlled lab application close did not complete; controller remains active", "ERROR")
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

ControllerCloseResultMatches(resultText, token, status) {
    return Trim(resultText) = token . "|" . status
}
