; ============================================================================
; RdpMonitoring.ahk - RDP Event Monitoring
; ============================================================================
; Functions for monitoring RDP session events and triggering application closure
; ============================================================================
#Include Config.ahk
#Include Utils.ahk
#Include WindowClosing.ahk
#Include CloseRequest.ahk

; Returns [EventRecordID, EventID] of the latest RDP events
GetLatestRdpEventRecord(ids := [23, 24, 25, 39, 40]) {
    record := QueryLatestRdpEventRecordViaApi(ids)
    if (record[1] != 0 || record[2] != 0)
        return record
    return QueryLatestRdpEventRecordViaWevtutil(ids)
}

QueryLatestRdpEventRecordViaApi(ids) {
    static apiAvailable := true
    static apiFailureLogged := false
    local hQuery := 0, hEvent := 0
    result := [0, 0]

    if (!apiAvailable)
        return result

    eventLog := "Microsoft-Windows-TerminalServices-LocalSessionManager/Operational"
    query := BuildRdpEventQuery(ids)

    try {
        flags := 0x0001 | 0x0200  ; Channel path + reverse direction (newest first)
        hQuery := DllCall("wevtapi\EvtQuery", "ptr", 0, "wstr", eventLog, "wstr", query, "uint", flags, "ptr")
        if (!hQuery)
            throw Error("EvtQuery failed", , DllCall("GetLastError", "UInt"))

        handleBuf := Buffer(A_PtrSize, 0)
        success := DllCall("wevtapi\EvtNext", "ptr", hQuery, "uint", 1, "ptr", handleBuf.Ptr,
            "uint", 100, "uint", 0, "uint*", &returned := 0)
        if (!success) {
            err := DllCall("GetLastError", "UInt")
            if (err = 259)  ; ERROR_NO_MORE_ITEMS
                return result
            throw Error("EvtNext failed", , err)
        }

        hEvent := NumGet(handleBuf, 0, "ptr")
        xml := RenderEventXml(hEvent)
        if (xml = "")
            return result

        recId := 0, evId := 0
        if RegExMatch(xml, "<EventRecordID>(\d+)</EventRecordID>", &m1)
            recId := Integer(m1[1])
        if RegExMatch(xml, "<EventID>(\d+)</EventID>", &m2)
            evId := Integer(m2[1])
        result := [recId, evId]
    } catch as e {
        if (!apiFailureLogged) {
            Log("WARNING: Windows Event API unavailable (" . e.Message . ") - falling back to wevtutil", "WARNING")
            apiFailureLogged := true
        }
        apiAvailable := false
        result := [0, 0]
    } finally {
        if (hEvent)
            DllCall("wevtapi\EvtClose", "ptr", hEvent)
        if (hQuery)
            DllCall("wevtapi\EvtClose", "ptr", hQuery)
    }

    return result
}

RenderEventXml(hEvent) {
    local buffer
    if (!hEvent)
        return ""

    bufferSize := 0
    propertyCount := 0
    success := DllCall("wevtapi\EvtRender", "ptr", 0, "ptr", hEvent, "uint", 1,
        "uint", 0, "ptr", 0, "uint*", &bufferSize, "uint*", &propertyCount)
    err := DllCall("GetLastError", "UInt")
    if (!success && err != 122)  ; ERROR_INSUFFICIENT_BUFFER expected on first call
        return ""

    if (bufferSize <= 0)
        return ""

    buffer := Buffer(bufferSize, 0)
    if !DllCall("wevtapi\EvtRender", "ptr", 0, "ptr", hEvent, "uint", 1,
        "uint", buffer.Size, "ptr", buffer.Ptr, "uint*", &bufferUsed := 0, "uint*", &propertyCount) {
        return ""
    }

    return StrGet(buffer.Ptr, bufferUsed // 2, "UTF-16")
}

BuildRdpEventQuery(ids) {
    cond := ""
    for id in ids
        cond .= (cond ? " or " : "") . "EventID=" . id
    return "*[System[(" . cond . ")]]"
}

QueryLatestRdpEventRecordViaWevtutil(ids) {
    static wevtutilErrorLogged := false

    eventLog := "Microsoft-Windows-TerminalServices-LocalSessionManager/Operational"
    tmp := A_Temp "\rdp_event.xml"
    xpath := BuildRdpEventQuery(ids)

    ; Try to find wevtutil.exe
    wevt := ""
    if FileExist(A_WinDir "\System32\wevtutil.exe")
        wevt := A_WinDir "\System32\wevtutil.exe"
    if (!wevt && FileExist(A_WinDir "\Sysnative\wevtutil.exe"))
        wevt := A_WinDir "\Sysnative\wevtutil.exe"
    if (!wevt)
        wevt := "wevtutil.exe"

    fullCmd := Format('"{1}" qe "{2}" /q:"{3}" /c:1 /f:xml /rd:true > "{4}"'
                    , wevt, eventLog, xpath, tmp)

    try {
        exitCode := RunWait(Format('"{1}" /C {2}', A_ComSpec, fullCmd), , "Hide")
        if (exitCode != 0) {
            if (!wevtutilErrorLogged) {
                Log("wevtutil failed (ExitCode=" . exitCode . ") - This is normal if WTS notifications work.")
                wevtutilErrorLogged := true
            }
            return [0, 0]
        }
    } catch as e {
        if (!wevtutilErrorLogged) {
            errMsg := (Type(e) = "Error") ? e.message : String(e)
            Log("wevtutil execution failed: " . errMsg . " - This is normal if WTS notifications work.")
            wevtutilErrorLogged := true
        }
        return [0, 0]
    }

    try {
        xml := FileRead(tmp, "UTF-8")
        FileDelete(tmp)
    } catch {
        try FileDelete(tmp)
        return [0, 0]
    }

    recId := 0, evId := 0
    if RegExMatch(xml, "<EventRecordID>(\d+)</EventRecordID>", &m1)
        recId := Integer(m1[1])
    if RegExMatch(xml, "<EventID>(\d+)</EventID>", &m2)
        evId := Integer(m2[1])
    return [recId, evId]
}

; Check for new RDP session events (fallback polling)
CheckSessionEvents(*) {
    global lastId, RdpSessionEventIds, VERBOSE_LOGGING, WORKSPACE_MODE

    rec := GetLatestRdpEventRecord(RdpSessionEventIds)
    current := rec[1], evId := rec[2]
    
    if (VERBOSE_LOGGING) {
        modeStr := WORKSPACE_MODE ? " (Workspace)" : ""
        Log("Event check" . modeStr . " - Current RecordId: " . current . ", Last RecordId: " . lastId . ", EventId: " . evId)
    }

    if (current > 0 && current != lastId && evId > 0) {
        lastId := current

        switch evId {
            case 25:
                ControllerCancelDisconnectGrace("RDP event 25")
            case 24, 39, 40:
                ControllerStartDisconnectGrace("RDP disconnect event " . evId)
            case 23:
                Log("RDP logoff event detected (RecordId " . current . ")", "INFO")
                ControllerCloseForSessionEnd("RDP logoff event 23")
        }
    }
}

; Session change handler (WM_WTSSESSION_CHANGE)
OnSessionChange(wParam, lParam, msg, hwnd) {
    static WTS_REMOTE_CONNECT := 0x3
    static WTS_SESSION_REMOTE_DISCONNECT := 0x4
    static WTS_SESSION_LOGOFF := 0x6
    static WTS_SESSION_LOCK := 0x7

    if (wParam = WTS_REMOTE_CONNECT) {
        ControllerCancelDisconnectGrace("WTS remote reconnect")
        return
    }

    if (wParam = WTS_SESSION_REMOTE_DISCONNECT) {
        ControllerStartDisconnectGrace("WTS remote disconnect")
        return
    }

    if (wParam = WTS_SESSION_LOGOFF || wParam = WTS_SESSION_LOCK) {
        reason := wParam = WTS_SESSION_LOGOFF ? "Windows session logoff" : "Windows session lock"
        ControllerCloseForSessionEnd(reason)
    }
}

; Query end session handler (WM_QUERYENDSESSION - logoff/shutdown)
OnQueryEndSession(wParam, lParam, msg, hwnd) {
    ControllerCloseForSessionEnd("Windows session ending")
}

ControllerStartDisconnectGrace(reason) {
    global CONTROLLER_DISCONNECT_GRACE_ACTIVE, CONTROLLER_CLOSE_IN_PROGRESS
    global CONTROLLER_DISCONNECT_GRACE_STARTED_TICK
    global CONTROLLER_DISCONNECT_CLOSE_RETRY_PENDING, CONTROLLER_DISCONNECT_CLOSE_ATTEMPTS
    global CONTROLLER_DISCONNECT_CLOSE_FIRST_ATTEMPT_TICK
    global RDP_DISCONNECT_GRACE_MS

    if (CONTROLLER_CLOSE_IN_PROGRESS || CONTROLLER_DISCONNECT_GRACE_ACTIVE
        || CONTROLLER_DISCONNECT_CLOSE_RETRY_PENDING)
        return

    CONTROLLER_DISCONNECT_CLOSE_ATTEMPTS := 0
    CONTROLLER_DISCONNECT_CLOSE_FIRST_ATTEMPT_TICK := 0
    SetTimer(ControllerReservationDisconnectCloseRetry, 0)
    CONTROLLER_DISCONNECT_GRACE_ACTIVE := true
    CONTROLLER_DISCONNECT_GRACE_STARTED_TICK := A_TickCount
    SetTimer(ControllerDisconnectGraceExpired, -RDP_DISCONNECT_GRACE_MS)
    Log(reason . "; keeping the lab workspace for " . (RDP_DISCONNECT_GRACE_MS // 1000)
        . " seconds to allow the user to reconnect", "INFO")
}

ControllerCancelDisconnectGrace(reason) {
    global CONTROLLER_DISCONNECT_GRACE_ACTIVE, CONTROLLER_CLOSE_IN_PROGRESS
    global CONTROLLER_DISCONNECT_GRACE_STARTED_TICK, RDP_DISCONNECT_GRACE_MS
    global CONTROLLER_DISCONNECT_CLOSE_RETRY_PENDING, CONTROLLER_DISCONNECT_CLOSE_ATTEMPTS
    global CONTROLLER_DISCONNECT_CLOSE_FIRST_ATTEMPT_TICK

    if (CONTROLLER_CLOSE_IN_PROGRESS)
        return

    if (CONTROLLER_DISCONNECT_CLOSE_RETRY_PENDING) {
        SetTimer(ControllerReservationDisconnectCloseRetry, 0)
        CONTROLLER_DISCONNECT_CLOSE_RETRY_PENDING := false
        CONTROLLER_DISCONNECT_CLOSE_ATTEMPTS := 0
        CONTROLLER_DISCONNECT_CLOSE_FIRST_ATTEMPT_TICK := 0
        Log(reason . "; cancelled the pending local close retry after reconnect", "INFO")
    }

    if (!CONTROLLER_DISCONNECT_GRACE_ACTIVE)
        return

    elapsedMs := A_TickCount - CONTROLLER_DISCONNECT_GRACE_STARTED_TICK
    if (elapsedMs < 0)
        elapsedMs += 4294967296
    if (elapsedMs >= RDP_DISCONNECT_GRACE_MS) {
        Log(reason . " arrived after the RDP reconnect grace expired; closing the controlled lab applications", "INFO")
        ControllerDisconnectGraceExpired()
        return
    }

    SetTimer(ControllerDisconnectGraceExpired, 0)
    CONTROLLER_DISCONNECT_GRACE_ACTIVE := false
    CONTROLLER_DISCONNECT_GRACE_STARTED_TICK := 0
    Log(reason . "; retained the existing lab workspace", "INFO")
}

ControllerDisconnectGraceExpired(*) {
    global CONTROLLER_DISCONNECT_GRACE_ACTIVE, CONTROLLER_CLOSE_IN_PROGRESS
    global CONTROLLER_DISCONNECT_GRACE_STARTED_TICK

    if (!CONTROLLER_DISCONNECT_GRACE_ACTIVE || CONTROLLER_CLOSE_IN_PROGRESS)
        return

    CONTROLLER_DISCONNECT_GRACE_ACTIVE := false
    CONTROLLER_DISCONNECT_GRACE_STARTED_TICK := 0
    Log("RDP reconnection grace expired; closing the controlled lab applications", "INFO")
    ControllerCloseForSessionEnd("RDP reconnection grace expired", true)
}

ControllerReservationDisconnectCloseRetry(*) {
    global CONTROLLER_DISCONNECT_CLOSE_RETRY_PENDING, CONTROLLER_CLOSE_IN_PROGRESS

    if (!CONTROLLER_DISCONNECT_CLOSE_RETRY_PENDING || CONTROLLER_CLOSE_IN_PROGRESS)
        return

    CONTROLLER_DISCONNECT_CLOSE_RETRY_PENDING := false
    Log("Retrying the reservation disconnect close once after the initial local attempt failed", "INFO")
    ControllerCloseForSessionEnd("RDP disconnect close retry", true)
}

ControllerCloseForSessionEnd(reason, publishReservationDisconnectClose := false) {
    global CONTROLLER_CLOSE_IN_PROGRESS
    global CONTROLLER_DISCONNECT_CLOSE_RETRY_PENDING, CONTROLLER_DISCONNECT_CLOSE_ATTEMPTS
    global CONTROLLER_DISCONNECT_CLOSE_FIRST_ATTEMPT_TICK, RDP_DISCONNECT_CLOSE_RETRY_MS

    if (CONTROLLER_CLOSE_IN_PROGRESS)
        return

    if (publishReservationDisconnectClose) {
        if (CONTROLLER_DISCONNECT_CLOSE_ATTEMPTS >= 2)
            return
        CONTROLLER_DISCONNECT_CLOSE_ATTEMPTS += 1
        if (CONTROLLER_DISCONNECT_CLOSE_ATTEMPTS = 1)
            CONTROLLER_DISCONNECT_CLOSE_FIRST_ATTEMPT_TICK := A_TickCount
    }

    success := ControllerCloseManagedApps(reason)
    if (publishReservationDisconnectClose) {
        recordCloseFn := closeSucceeded => ControllerRecordReservationDisconnectClose(closeSucceeded)
        logoffSessionFn := () => ControllerLogoffCurrentSession()
        success := ControllerCompleteReservationDisconnectClose(success, recordCloseFn, logoffSessionFn)

        if (!success) {
            ; The managed-app close may have succeeded while its status write or
            ; desktop logoff failed. Reset the guard so the one retry can run.
            CONTROLLER_CLOSE_IN_PROGRESS := false
            if (CONTROLLER_DISCONNECT_CLOSE_ATTEMPTS = 1 && ControllerHasActiveReservationLease()) {
                elapsedMs := A_TickCount - CONTROLLER_DISCONNECT_CLOSE_FIRST_ATTEMPT_TICK
                if (elapsedMs < 0)
                    elapsedMs += 4294967296
                retryDelayMs := RDP_DISCONNECT_CLOSE_RETRY_MS - elapsedMs
                if (retryDelayMs < 1)
                    retryDelayMs := 1
                CONTROLLER_DISCONNECT_CLOSE_RETRY_PENDING := true
                SetTimer(ControllerReservationDisconnectCloseRetry, -retryDelayMs)
                Log("Reservation disconnect close failed; one local retry is scheduled 25 seconds after the first attempt", "WARNING")
                return
            }
            if (CONTROLLER_DISCONNECT_CLOSE_ATTEMPTS = 1)
                Log("Reservation disconnect close failed without an active reservation lease; no local retry is scheduled", "WARNING")
            else
                Log("The one local reservation disconnect close retry failed; leaving the disconnected desktop for Gateway release-session", "WARNING")
        }
    }
    CONTROLLER_DISCONNECT_CLOSE_RETRY_PENDING := false
    ControllerClearPresence()
    ExitApp(success ? 0 : 1)
}

; Setup RDP event monitoring (used by both modes)
SetupRdpMonitoring(hwnd) {
    global POLL_INTERVAL_MS, lastId, WTS_NOTIFICATIONS_ACTIVE
    
    ; Register for session notifications
    if DllCall("Wtsapi32\WTSRegisterSessionNotification", "ptr", hwnd, "uint", 0, "int") {
        global WTS_NOTIFICATIONS_ACTIVE
        WTS_NOTIFICATIONS_ACTIVE := true
        SetTimer(CheckSessionEvents, 0)  ; Disable any residual polling
        OnMessage(0x02B1, OnSessionChange)
        OnMessage(0x0011, OnQueryEndSession)
        OnExit((*) => (
            DllCall("Wtsapi32\WTSUnRegisterSessionNotification", "ptr", hwnd),
            OnMessage(0x02B1, OnSessionChange, 0),
            OnMessage(0x0011, OnQueryEndSession, 0)
        ))
        Log("Registered for WM_WTSSESSION_CHANGE / WM_QUERYENDSESSION notifications - polling disabled", "DEBUG")
    } else {
        global WTS_NOTIFICATIONS_ACTIVE
        WTS_NOTIFICATIONS_ACTIVE := false
        Log("WARNING: Could not register for session notifications - falling back to polling", "WARNING")
        
        ; Set a baseline so an old event from before AppControl started is not
        ; mistaken for a new disconnect.
        baseline := GetLatestRdpEventRecord(RdpSessionEventIds)
        lastId := baseline[1]
        SetTimer(CheckSessionEvents, POLL_INTERVAL_MS)
    }
}
