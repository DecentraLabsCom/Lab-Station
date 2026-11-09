; ============================================================================
; Utils.ahk - Utility Functions
; ============================================================================
; General utility functions used across the application
; ============================================================================

; Logging function for auditing and support
; Levels: ERROR, WARNING, INFO (default), DEBUG
; In PRODUCTION_MODE, only ERROR and WARNING are logged
Log(msg, level := "INFO") {
    global PRODUCTION_MODE
    
    ; In production mode, only log ERROR and WARNING
    if (PRODUCTION_MODE && level != "ERROR" && level != "WARNING") {
        return
    }
    
    logFile := A_ScriptDir "\AppControl.log"
    timestamp := FormatTime(A_Now, "yyyyMMddHHmmss")
    prefix := (level != "INFO") ? "[" . level . "] " : ""
    logEntry := timestamp . " - " . prefix . msg . "`n"
    FileAppend(logEntry, logFile, "UTF-8")
    OutputDebug(timestamp . " - AppControl: " . prefix . msg)
}

WaitUntil(conditionCallback, timeoutMs := 0, intervalMs := 0) {
    global WINDOW_STATE_TIMEOUT_MS, WINDOW_STATE_POLL_INTERVAL_MS

    if (timeoutMs <= 0)
        timeoutMs := WINDOW_STATE_TIMEOUT_MS
    if (intervalMs <= 0)
        intervalMs := WINDOW_STATE_POLL_INTERVAL_MS

    deadline := A_TickCount + timeoutMs
    while (A_TickCount <= deadline) {
        try {
            if conditionCallback.Call()
                return true
        } catch {
            return false
        }
        Sleep(intervalMs)
    }
    return false
}

GetWindowDimensions(hwnd) {
    if (!hwnd)
        return 0
    try {
        WinGetPos(&x, &y, &w, &h, "ahk_id " . hwnd)
        return {x: x, y: y, w: w, h: h}
    } catch {
        return 0
    }
}

; Helper function to check if a string is a number
IsNumber(str) {
    try {
        Integer(str)
        return true
    } catch {
        return false
    }
}

; Detect if a window is a UWP (Universal Windows Platform) application
; Parameters: hwnd - Window handle, className - Optional window class name
; Returns: true if UWP app, false otherwise
IsUWPApp(hwnd, className := "") {
    try {
        if (className = "") {
            className := WinGetClass("ahk_id " . hwnd)
        }
        
        ; UWP apps typically use ApplicationFrameWindow as container or specific classes
        if (InStr(className, "ApplicationFrameWindow")) {
            return true
        }
        
        ; Check process name - UWP apps often run through specific hosts
        processPath := WinGetProcessPath("ahk_id " . hwnd)
        if (InStr(processPath, "WindowsApps") || InStr(processPath, "SystemApps")) {
            return true
        }
        
        ; Check extended style for WS_EX_NOREDIRECTIONBITMAP (common in UWP)
        exStyle := DllCall("GetWindowLong", "Ptr", hwnd, "Int", -20, "Int")
        WS_EX_NOREDIRECTIONBITMAP := 0x00200000
        if ((exStyle & WS_EX_NOREDIRECTIONBITMAP) = WS_EX_NOREDIRECTIONBITMAP) {
            ; Also check if it's in WindowsApps path to confirm UWP
            if (InStr(processPath, "WindowsApps")) {
                return true
            }
        }
    }
    
    return false
}

; Extract executable path from a full command string (removes parameters)
ExtractExecutablePath(command) {
    local quote
    ; Handle commands with quoted executable paths followed by parameters
    ; Examples:
    ; - "C:\Program Files\app.exe" --param value
    ; - C:\Program Files\app.exe --param value
    ; - "C:\path\app.exe"
    
    command := Trim(command)
    
    ; If command starts with a quote, find the matching closing quote
    quote := Chr(34)  ; Double quote character
    if (SubStr(command, 1, 1) = quote) {
        ; Find the closing quote
        closeQuotePos := InStr(command, quote, , 2)  ; Find second occurrence of "
        if (closeQuotePos > 1) {
            ; Extract path between quotes
            return SubStr(command, 2, closeQuotePos - 2)
        }
    }
    
    ; No quotes or single argument - check if there are spaces (parameters)
    spacePos := InStr(command, " ")
    if (spacePos > 0) {
        ; Return everything before the first space
        return SubStr(command, 1, spacePos - 1)
    }
    
    ; Single path, no parameters
    return command
}

; Auto-detect browsers and add kiosk/incognito flags if not present
; Returns the command with flags added if applicable
EnhanceBrowserCommand(command) {
    local quote
    global AUTO_BROWSER_KIOSK, BROWSER_KIOSK_FLAGS
    
    ; If auto-kiosk is disabled, return command unchanged
    if (!AUTO_BROWSER_KIOSK) {
        return command
    }
    
    ; Extract executable path to identify the browser
    exePath := ExtractExecutablePath(command)
    SplitPath(exePath, &exeName)
    exeNameLower := StrLower(exeName)
    
    ; Check if this is a known browser
    if (!BROWSER_KIOSK_FLAGS.Has(exeNameLower)) {
        return command  ; Not a browser, return unchanged
    }
    
    ; Get the flags for this browser
    browserFlags := BROWSER_KIOSK_FLAGS[exeNameLower]
    
    ; Check if kiosk-related flags are already present in the command
    commandLower := StrLower(command)
    hasKiosk := InStr(commandLower, "-kiosk") || InStr(commandLower, "--kiosk")
    hasPrivate := InStr(commandLower, "-private") || InStr(commandLower, "--inprivate") || InStr(commandLower, "--incognito")
    
    ; If browser already has ANY kiosk/private browsing flags, don't auto-enhance
    ; This prevents duplicates and respects user's explicit configuration
    if (hasKiosk || hasPrivate) {
        Log("Browser command already has kiosk or private browsing flags - skipping auto-enhancement", "DEBUG")
        return command
    }
    
    ; Add the flags after the executable path
    ; Handle both quoted and unquoted paths
    quote := Chr(34)  ; Double quote character
    if (SubStr(command, 1, 1) = quote) {
        closeQuotePos := InStr(command, quote, , 2)
        if (closeQuotePos > 0) {
            ; Get the part after the closing quote (if any)
            afterQuote := SubStr(command, closeQuotePos + 1)
            afterQuote := Trim(afterQuote)  ; Remove leading/trailing spaces
            
            ; Insert flags after the closing quote
            if (afterQuote != "") {
                ; There are existing parameters after the quoted path
                enhancedCommand := SubStr(command, 1, closeQuotePos) . " " . browserFlags . " " . afterQuote
            } else {
                ; No parameters after the quoted path
                enhancedCommand := SubStr(command, 1, closeQuotePos) . " " . browserFlags
            }
        } else {
            enhancedCommand := command . " " . browserFlags
        }
    } else {
        ; No quotes - find first space or append to end
        spacePos := InStr(command, " ")
        if (spacePos > 0) {
            ; Get the part after the first space
            afterSpace := SubStr(command, spacePos + 1)
            afterSpace := Trim(afterSpace)
            
            ; Insert flags after the executable
            if (afterSpace != "") {
                enhancedCommand := SubStr(command, 1, spacePos - 1) . " " . browserFlags . " " . afterSpace
            } else {
                enhancedCommand := SubStr(command, 1, spacePos - 1) . " " . browserFlags
            }
        } else {
            enhancedCommand := command . " " . browserFlags
        }
    }
    
    Log("Auto-enhanced browser command: " . exeName . " -> Added: " . browserFlags, "INFO")
    return enhancedCommand
}
