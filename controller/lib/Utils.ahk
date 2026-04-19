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

WindowMeetsSizeThreshold(hwnd, minWidth, minHeight, label := "", context := "") {
    dims := GetWindowDimensions(hwnd)
    if (!dims)
        return false

    if (dims.w > minWidth && dims.h > minHeight) {
        if (label != "") {
            title := ""
            try title := WinGetTitle("ahk_id " . hwnd)
            msg := label . " window candidate"
            if (context != "")
                msg .= " (" . context . ")"
            msg .= " -> HWND " . hwnd . ": " . dims.w . "x" . dims.h . " - Title: '" . title . "'"
            Log(msg, "DEBUG")
        }
        return true
    }

    return false
}

EnsureWindowSized(hwnd, label := "", minWidth := 100, minHeight := 100) {
    global APP_WINDOW_SIZE_TIMEOUT_MS, WINDOW_STATE_POLL_INTERVAL_MS
    dims := GetWindowDimensions(hwnd)
    if (dims && dims.w > minWidth && dims.h > minHeight) {
        if (label != "")
            Log(label . " window sized: " . dims.w . "x" . dims.h, "DEBUG")
        return true
    }

    sizeCondition := () => (
        dims := GetWindowDimensions(hwnd),
        dims && dims.w > minWidth && dims.h > minHeight
    )

    if (WaitUntil(sizeCondition, APP_WINDOW_SIZE_TIMEOUT_MS, WINDOW_STATE_POLL_INTERVAL_MS)) {
        dims := GetWindowDimensions(hwnd)
        if (label != "")
            Log(label . " window reached usable size: " . dims.w . "x" . dims.h, "DEBUG")
        return true
    }

    if (label != "") {
        if (dims)
            Log("WARNING: " . label . " window remained below size threshold (" . dims.w . "x" . dims.h . ")", "WARNING")
        else
            Log("WARNING: " . label . " window dimensions unavailable while waiting", "WARNING")
    }
    return false
}

FindWindowCandidate(className, pid, isLauncher, label := "") {
    minWidth := 100
    minHeight := 100

    if (!isLauncher && pid) {
        target := "ahk_class " . className . " ahk_pid " . pid
        if WinExist(target) {
            hwnd := WinGetID(target)
            if (WindowMeetsSizeThreshold(hwnd, minWidth, minHeight, label, "class+pid"))
                return hwnd
        }
    }

    targetOnlyClass := "ahk_class " . className
    wins := []
    try wins := WinGetList(targetOnlyClass)
    catch {
        return 0
    }

    for hwnd in wins {
        if !WinExist("ahk_id " . hwnd)
            continue
        if (WindowMeetsSizeThreshold(hwnd, minWidth, minHeight, label, "class-only"))
            return hwnd
    }
    return 0
}

ApplyContainerPositioningDelay() {
    global CONTAINER_POSITIONING_DELAY_MS
    if (CONTAINER_POSITIONING_DELAY_MS > 0)
        Sleep(CONTAINER_POSITIONING_DELAY_MS)
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

; Detect if a window uses a custom-drawn title bar (modern apps) or standard Windows title bar
; Parameters: hwnd - Window handle, className - Optional window class name (if already known)
; Returns: true if custom title bar, false if standard Windows title bar
HasCustomTitleBar(hwnd, className := "") {
    ; Get window styles
    style := DllCall("GetWindowLong", "Ptr", hwnd, "Int", -16, "Int")  ; GWL_STYLE
    exStyle := DllCall("GetWindowLong", "Ptr", hwnd, "Int", -20, "Int") ; GWL_EXSTYLE
    
    ; Check if window has WS_CAPTION (title bar)
    WS_CAPTION := 0x00C00000
    hasCaption := (style & WS_CAPTION) = WS_CAPTION
    
    ; If no caption at all, it's likely custom-drawn
    if (!hasCaption) {
        return true
    }
    
    ; Check for WS_EX_NOREDIRECTIONBITMAP - used by modern apps with custom rendering
    WS_EX_NOREDIRECTIONBITMAP := 0x00200000
    hasNoRedirection := (exStyle & WS_EX_NOREDIRECTIONBITMAP) = WS_EX_NOREDIRECTIONBITMAP
    
    if (hasNoRedirection) {
        return true
    }
    
    ; Check window class - use provided className or get it from hwnd
    try {
        if (className = "") {
            className := WinGetClass("ahk_id " . hwnd)
        }
        
        ; Known custom title bar apps
        customTitleBarApps := [
            "Chrome_WidgetWin_1",   ; Chrome/Edge
            "MozillaWindowClass",   ; Firefox
            "Qt5",                  ; Qt apps
            "Qt6",                  ; Qt apps
            "Electron",             ; Electron apps (VSCode, Discord, etc.)
        ]
        
        for appClass in customTitleBarApps {
            if (InStr(className, appClass)) {
                return true
            }
        }
    }
    
    ; Default: assume standard Windows title bar
    return false
}

; Get the height of a custom title bar for modern apps
; Parameters: className - The window class name (from command line args)
; Returns: Estimated height in pixels (typically 30-40px)
GetCustomTitleBarHeight(className) {
    ; Known title bar heights for common apps
    if (InStr(className, "MozillaWindowClass")) {
        Log("MozillaWindowClass detected - returning title bar height 40", "DEBUG")
        return 40  ; Firefox title bar height
    }
    else if (InStr(className, "Chrome_WidgetWin_1")) {
        return 32  ; Chrome/Edge title bar height
    }
    else if (InStr(className, "Qt5") || InStr(className, "Qt6")) {
        return 30  ; Qt apps title bar height
    }
    else if (InStr(className, "Electron")) {
        return 32  ; Electron apps (VSCode, Discord, etc.)
    }
    
    ; Default estimate for unknown custom title bar apps
    return 30
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
