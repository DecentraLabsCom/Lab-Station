; ============================================================================
; DualAppMode.ahk - Dual Application Container Mode
; ============================================================================
; Functions for managing two applications in a tabbed container with RDP handling
; ============================================================================

; Helper function to wait for process GUI initialization
WaitForProcessReady(pid, timeoutMs := 10000) {
    ; Open process handle for WaitForInputIdle
    hProcess := DllCall("OpenProcess", "UInt", 0x0400 | 0x0010, "Int", 0, "UInt", pid, "Ptr")  ; PROCESS_QUERY_INFORMATION | SYNCHRONIZE
    
    if (!hProcess) {
        Log("WARNING: Could not open process handle for PID " . pid . " - skipping WaitForInputIdle", "WARNING")
        return false
    }
    
    ; Wait for the process to be ready for user input (GUI initialized)
    result := DllCall("WaitForInputIdle", "Ptr", hProcess, "UInt", timeoutMs, "UInt")
    
    ; Close process handle
    DllCall("CloseHandle", "Ptr", hProcess)
    
    if (result = 0) {
        Log("Process PID " . pid . " is ready for input (WaitForInputIdle succeeded)", "DEBUG")
        return true
    } else if (result = 0x00000102) {  ; WAIT_TIMEOUT
        Log("WaitForInputIdle timed out after " . timeoutMs . "ms for PID " . pid, "DEBUG")
        return false
    } else {
        Log("WARNING: WaitForInputIdle failed for PID " . pid . " with result " . result, "WARNING")
        return false
    }
}

; Helper to wait for a window using WinWait, with fallback for launcher processes
WaitForAppWindow(className, pid, isLauncher, startupTimeout) {
    if (startupTimeout < 1)
        startupTimeout := 1

    ; For standard executables, try waiting for GUI readiness first
    if (!isLauncher && pid) {
        ; Cap WaitForInputIdle timeout to the same startup window
        waitMs := startupTimeout * 1000
        WaitForProcessReady(pid, waitMs)
    }

    winWaitTimeout := startupTimeout * 1000
    target := isLauncher ? "ahk_class " . className : "ahk_class " . className . " ahk_pid " . pid
    Log("Waiting for window with WinWait: " . target . " (timeout: " . winWaitTimeout . "ms)", "DEBUG")

    success := WinWait(target, , winWaitTimeout / 1000)

    if (!success) {
        Log("WinWait timed out for " . target . " - falling back to polling", "DEBUG")
        return 0
    }

    hwnd := WinExist(target)
    if (!hwnd) {
        Log("WARNING: WinWait succeeded but WinExist returned null for " . target, "WARNING")
        return 0
    }

    Log("WinWait found window " . hwnd . " for target " . target, "DEBUG")
    return hwnd
}


EnsureWindowMinimized(hwnd, label := "") {
    if (!hwnd) {
        return false
    }
    attempt := 0
    condition := () => (
        DllCall("IsIconic", "Ptr", hwnd, "UInt")
        ? true
        : (
            attempt += 1,
            (!DllCall("ShowWindowAsync", "Ptr", hwnd, "Int", 6) && label != "")
                ? Log("WARNING: ShowWindowAsync(SW_MINIMIZE) attempt " . attempt . " failed for " . label, "WARNING")
                : 0,
            false
        )
    )

    if (WaitUntil(condition)) {
        return true
    }

    if (!DllCall("ShowWindow", "Ptr", hwnd, "Int", 6) && label != "") {
        Log("WARNING: ShowWindow(SW_MINIMIZE) fallback failed for " . label, "WARNING")
    }

    if (WaitUntil(() => DllCall("IsIconic", "Ptr", hwnd, "UInt"))) {
        return true
    }

    if (label != "")
        Log("WARNING: Timed out waiting for " . label . " to minimize", "WARNING")
    return false
}

EnsureWindowRestored(hwnd, label := "") {
    if (!hwnd) {
        return false
    }
    attempt := 0
    condition := () => (
        !DllCall("IsIconic", "Ptr", hwnd, "UInt")
        ? true
        : (
            attempt += 1,
            (!DllCall("ShowWindowAsync", "Ptr", hwnd, "Int", 9) && label != "")
                ? Log("WARNING: ShowWindowAsync(SW_RESTORE) attempt " . attempt . " failed for " . label, "WARNING")
                : 0,
            false
        )
    )

    if (WaitUntil(condition)) {
        return true
    }

    if (!DllCall("ShowWindow", "Ptr", hwnd, "Int", 9) && label != "") {
        Log("WARNING: ShowWindow(SW_RESTORE) fallback failed for " . label, "WARNING")
    }

    if (WaitUntil(() => !DllCall("IsIconic", "Ptr", hwnd, "UInt"))) {
        return true
    }

    if (label != "")
        Log("WARNING: Timed out waiting for " . label . " to restore", "WARNING")
    return false
}

GetWindowMinMaxState(hwnd) {
    if (!hwnd)
        return ""
    if (!WinExist("ahk_id " . hwnd))
        return ""
    try {
        return WinGetMinMax("ahk_id " . hwnd)
    } catch {
        return ""
    }
}

VerifyWindowPosition(hwnd, x, y, width, height, tolerance := 0) {
    global UWP_POSITION_TOLERANCE_PX
    if (tolerance <= 0)
        tolerance := UWP_POSITION_TOLERANCE_PX
    try {
        WinGetPos(&actualX, &actualY, &actualW, &actualH, "ahk_id " . hwnd)
    } catch {
        return false
    }
    return (Abs(actualX - x) <= tolerance)
        && (Abs(actualY - y) <= tolerance)
        && (Abs(actualW - width) <= tolerance)
        && (Abs(actualH - height) <= tolerance)
}

; Robust positioning for UWP applications (with retries)
PositionUWPApp(hwnd, x, y, width, height, maxRetries := 5) {
    global WINDOW_STATE_TIMEOUT_MS, WINDOW_STATE_POLL_INTERVAL_MS
    global UWP_POSITION_TOLERANCE_PX, UWP_POSITION_RETRY_DELAY_MS

    Loop maxRetries {
        DllCall("SetWindowPos", "Ptr", hwnd, "Ptr", 0,
            "Int", x, "Int", y, "Int", width, "Int", height, "UInt", 0x0014)

        if (WaitUntil(() => VerifyWindowPosition(hwnd, x, y, width, height), WINDOW_STATE_TIMEOUT_MS, WINDOW_STATE_POLL_INTERVAL_MS)) {
            Log("UWP app positioned successfully on attempt " . A_Index, "DEBUG")
            DllCall("RedrawWindow", "Ptr", hwnd, "Ptr", 0, "Ptr", 0, "UInt", 0x0085)
            return true
        }

        try {
            WinGetPos(&actualX, &actualY, &actualW, &actualH, "ahk_id " . hwnd)
            Log("UWP positioning attempt " . A_Index . " - Actual: " . actualX . "," . actualY . " " . actualW . "x" . actualH . " (Expected: " . x . "," . y . " " . width . "x" . height . ")", "DEBUG")
        }

        if (A_Index >= 3) {
            try {
                WinMove(x, y, width, height, "ahk_id " . hwnd)
                if (WaitUntil(() => VerifyWindowPosition(hwnd, x, y, width, height))) {
                    Log("UWP app positioned via WinMove fallback on attempt " . A_Index, "DEBUG")
                    DllCall("RedrawWindow", "Ptr", hwnd, "Ptr", 0, "Ptr", 0, "UInt", 0x0085)
                    return true
                }
            }
        }

        Sleep(UWP_POSITION_RETRY_DELAY_MS * A_Index)
    }

    Log("WARNING: Failed to position UWP app after " . maxRetries . " attempts", "WARNING")
    return false
}

CreateDualAppContainer(class1, command1, class2, command2, tab1Title := "Application 1", tab2Title := "Application 2") {
    global STARTUP_TIMEOUT, POLL_INTERVAL_MS
    
    Log("Initializing dual app container mode", "INFO")
    Log("Tab titles: '" . tab1Title . "' and '" . tab2Title . "'", "DEBUG")
    
    ; Extract executable paths for validation (commands may include parameters)
    appPath1 := ExtractExecutablePath(command1)
    appPath2 := ExtractExecutablePath(command2)
    
    ; Validate that application files exist
    if !FileExist(appPath1) {
        Log("ERROR: Application 1 executable not found: " . appPath1, "ERROR")
        MsgBox "Application 1 executable not found: " . appPath1
        ExitApp
    }
    if !FileExist(appPath2) {
        Log("ERROR: Application 2 executable not found: " . appPath2, "ERROR")
        MsgBox "Application 2 executable not found: " . appPath2
        ExitApp
    }
    
    ; Create container GUI without title bar
    container := Gui("+Resize -Caption -DPIScale")
    container.SetFont("s10", "Segoe UI")
    
    ; Show container maximized FIRST to get real dimensions
    container.Show("Maximize")
    
    ; Get actual container size after maximizing
    container.GetPos(, , &cWidth, &cHeight)
    Log("Container maximized - Actual size: " . cWidth . "x" . cHeight, "DEBUG")
    
    ; Create a child GUI container for the apps (full screen behind tabs)
    appContainer := Gui("+Parent" . container.Hwnd . " -Caption -Border -DPIScale", "AppContainer")
    appContainer.BackColor := "000000"
    appContainer.Show("x0 y0 w" . cWidth . " h" . cHeight)
    
    Log("App container created - Full screen: " . cWidth . "x" . cHeight, "DEBUG")
    
    ; Launch applications FIRST to detect their window classes
    Log("Launching Application 1: " . command1, "DEBUG")
    try {
        Run(command1, , , &pid1)
    } catch as e {
        Log("ERROR: Failed to launch App 1: " . e.message, "ERROR")
        MsgBox "Failed to launch Application 1: " . command1 . "`n`nError: " . e.message
        ExitApp
    }
    
    ; Check if App 1 is a launcher (jar, bat, script) - may spawn different process
    SplitPath(appPath1, , , &ext1)
    isLauncher1 := (StrLower(ext1) != "exe")
    if (isLauncher1) {
        Log("App 1 is a launcher file (." . ext1 . ") - will use class-only detection", "DEBUG")
    }
    
    Log("Launching Application 2: " . command2, "DEBUG")
    try {
        Run(command2, , , &pid2)
    } catch as e {
        Log("ERROR: Failed to launch App 2: " . e.message, "ERROR")
        MsgBox "Failed to launch Application 2: " . command2 . "`n`nError: " . e.message
        ExitApp
    }
    
    ; Check if App 2 is a launcher (jar, bat, script) - may spawn different process
    SplitPath(appPath2, , , &ext2)
    isLauncher2 := (StrLower(ext2) != "exe")
    if (isLauncher2) {
        Log("App 2 is a launcher file (." . ext2 . ") - will use class-only detection", "DEBUG")
    }
    
    ; Wait for windows to appear using enhanced waiting logic
    Log("Waiting for Application 1 window (Class: " . class1 . ", PID: " . pid1 . ", Launcher: " . isLauncher1 . ")...", "DEBUG")
    
    ; Try WinWait first for efficient waiting
    hwnd1 := WaitForAppWindow(class1, pid1, isLauncher1, STARTUP_TIMEOUT)
    
    ; If WinWait didn't find the window, fall back to event-driven polling
    if (!hwnd1) {
        Log("WinWait failed for App 1 - using fallback polling logic", "DEBUG")
        condition1 := () => !!(hwnd1 := FindWindowCandidate(class1, pid1, isLauncher1, "App 1"))
        if (!WaitUntil(condition1, STARTUP_TIMEOUT * 1000, APP_WINDOW_POLL_INTERVAL_MS)) {
            Log("ERROR: Application 1 window did not appear within timeout", "ERROR")
            MsgBox "Application 1 window (class: " . class1 . ") did not appear within " . STARTUP_TIMEOUT . " seconds"
            ExitApp
        }
        Log("Selected App 1 window via fallback: " . hwnd1, "DEBUG")
    } else {
        ; WinWait succeeded - log and ensure the window reaches usable dimensions
        WinGetPos(&x, &y, &w, &h, "ahk_id " . hwnd1)
        title := WinGetTitle("ahk_id " . hwnd1)
        Log("App 1 window found by WinWait - Window " . hwnd1 . ": " . w . "x" . h . " - Title: '" . title . "'", "DEBUG")
    }

    EnsureWindowSized(hwnd1, "App 1")
    
    Log("Waiting for Application 2 window (Class: " . class2 . ", PID: " . pid2 . ", Launcher: " . isLauncher2 . ")...", "DEBUG")
    
    ; Try WinWait first for efficient waiting
    hwnd2 := WaitForAppWindow(class2, pid2, isLauncher2, STARTUP_TIMEOUT)
    
    ; If WinWait didn't find the window, fall back to event-driven polling
    if (!hwnd2) {
        Log("WinWait failed for App 2 - using fallback polling logic", "DEBUG")
        condition2 := () => !!(hwnd2 := FindWindowCandidate(class2, pid2, isLauncher2, "App 2"))
        if (!WaitUntil(condition2, STARTUP_TIMEOUT * 1000, APP_WINDOW_POLL_INTERVAL_MS)) {
            Log("ERROR: Application 2 window did not appear within timeout", "ERROR")
            MsgBox "Application 2 window (class: " . class2 . ") did not appear within " . STARTUP_TIMEOUT . " seconds"
            ExitApp
        }
        Log("Selected App 2 window via fallback: " . hwnd2, "DEBUG")
    } else {
        ; WinWait succeeded - log and ensure the window reaches usable dimensions
        WinGetPos(&x, &y, &w, &h, "ahk_id " . hwnd2)
        title := WinGetTitle("ahk_id " . hwnd2)
        Log("App 2 window found by WinWait - Window " . hwnd2 . ": " . w . "x" . h . " - Title: '" . title . "'", "DEBUG")
    }

    EnsureWindowSized(hwnd2, "App 2")
    
    Log("App 1 HWND: " . hwnd1 . ", App 2 HWND: " . hwnd2)
    
    ; Detect if apps are UWP applications
    app1IsUWP := IsUWPApp(hwnd1, class1)
    app2IsUWP := IsUWPApp(hwnd2, class2)
    
    Log("App 1 is UWP: " . (app1IsUWP ? "Yes" : "No") . ", App 2 is UWP: " . (app2IsUWP ? "Yes" : "No"), "DEBUG")
    
    ; Detect if apps use custom title bars (pass className to avoid WinGetClass call)
    app1HasCustomTitleBar := HasCustomTitleBar(hwnd1, class1)
    app2HasCustomTitleBar := HasCustomTitleBar(hwnd2, class2)
        
    ; Remove minimize, maximize and close buttons ONLY for apps with standard title bars
    if (!app1HasCustomTitleBar) {
        try {
            WinSetStyle("-0x20000", "ahk_id " . hwnd1) ; WS_MINIMIZEBOX
            WinSetStyle("-0x10000", "ahk_id " . hwnd1) ; WS_MAXIMIZEBOX
            WinSetStyle("-0x80000", "ahk_id " . hwnd1) ; WS_SYSMENU
            Log("App 1 window styles modified (standard titlebar - buttons removed)", "DEBUG")
        } catch as e {
            Log("WARNING: Could not modify App 1 window styles: " . e.message, "WARNING")
        }
    } else {
        Log("App 1 uses custom titlebar - skipping style modifications (SetParent will handle it)", "DEBUG")
    }
    
    if (!app2HasCustomTitleBar) {
        try {
            WinSetStyle("-0x20000", "ahk_id " . hwnd2) ; WS_MINIMIZEBOX
            WinSetStyle("-0x10000", "ahk_id " . hwnd2) ; WS_MAXIMIZEBOX
            WinSetStyle("-0x80000", "ahk_id " . hwnd2) ; WS_SYSMENU
            Log("App 2 window styles modified (standard titlebar - buttons removed)", "DEBUG")
        } catch as e {
            Log("WARNING: Could not modify App 2 window styles: " . e.message, "WARNING")
        }
    } else {
        Log("App 2 uses custom titlebar - skipping style modifications (SetParent will handle it)", "DEBUG")
    }
    
    ; Make apps children of container (skip for UWP apps - they don't support SetParent well)
    if (!app1IsUWP) {
        Log("Setting parent for Application 1", "DEBUG")
        DllCall("SetParent", "Ptr", hwnd1, "Ptr", appContainer.Hwnd)
    } else {
        Log("App 1 is UWP - skipping SetParent", "DEBUG")
    }
    
    if (!app2IsUWP) {
        Log("Setting parent for Application 2", "DEBUG")
        DllCall("SetParent", "Ptr", hwnd2, "Ptr", appContainer.Hwnd)
    } else {
        Log("App 2 is UWP - skipping SetParent", "DEBUG")
    }
    
    ; Calculate custom title bar heights
    titleBarHeight1 := app1HasCustomTitleBar ? GetCustomTitleBarHeight(class1) : 20
    titleBarHeight2 := app2HasCustomTitleBar ? GetCustomTitleBarHeight(class2) : 20
    
    ; Tab height should match the tallest custom titlebar
    tabHeight := Max(titleBarHeight1, titleBarHeight2)
    if (tabHeight < 35) {
        tabHeight := 35  ; Minimum tab height for usability
    }
    
    Log("Title bar heights - App1: " . titleBarHeight1 . "px, App2: " . titleBarHeight2 . "px, Tab height: " . tabHeight . "px", "DEBUG")
    
    ; Now create tab control with the calculated height
    container.SetFont("s11", "Segoe UI")
    tabs := container.AddTab3("x0 y0 w" . cWidth . " h" . tabHeight, [tab1Title, tab2Title])
    
    ; Apply tab control style (TCS_BUTTONS for flat modern look)
    try {
        tabHwnd := tabs.Hwnd
        currentStyle := DllCall("GetWindowLong", "Ptr", tabHwnd, "Int", -16, "Int")
        newStyle := currentStyle | 0x0100 | 0x0008  ; TCS_BUTTONS | TCS_FLATBUTTONS
        DllCall("SetWindowLong", "Ptr", tabHwnd, "Int", -16, "Int", newStyle)
        
        ; Set tab control to be always on top (within container)
        DllCall("SetWindowPos", "Ptr", tabHwnd, "Ptr", -1,  ; HWND_TOPMOST
            "Int", 0, "Int", 0, "Int", 0, "Int", 0, "UInt", 0x0003)  ; SWP_NOMOVE | SWP_NOSIZE
        
        DllCall("InvalidateRect", "Ptr", tabHwnd, "Ptr", 0, "Int", 1)
        Log("Tab control created with height " . tabHeight . "px (floating overlay)", "DEBUG")
    } catch as e {
        Log("WARNING: Could not apply tab styling: " . e.message, "WARNING")
    }
    
    container.SetFont("s10 norm", "Segoe UI")
    
    ; Ensure app container is behind tabs
    DllCall("SetWindowPos", "Ptr", appContainer.Hwnd, "Ptr", 1,  ; HWND_BOTTOM
        "Int", 0, "Int", 0, "Int", cWidth, "Int", cHeight, "UInt", 0x0043)
    
    ; Position and size apps
    Log("Positioning applications in container", "DEBUG")
    ApplyContainerPositioningDelay()
    
    ; Get container screen position for UWP apps
    container.GetPos(&containerX, &containerY, , )
    Log("Container position for UWP: X=" . containerX . " Y=" . containerY, "DEBUG")
    
    ; Calculate position below tabs for UWP apps
    uwpY := containerY + tabHeight
    uwpHeight := cHeight - tabHeight
    
    ; Handle App 1 - Always show on start
    if (!app1IsUWP) {
        try WinMaximize("ahk_id " . hwnd1)
        DllCall("ShowWindow", "Ptr", hwnd1, "Int", 5)  ; SW_SHOW
    } else {
        ; UWP apps: Position manually below tabs with robust retry logic
        Log("Positioning UWP App 1 at screen coords - X:" . containerX . " Y:" . uwpY . " W:" . cWidth . " H:" . uwpHeight, "DEBUG")
        PositionUWPApp(hwnd1, containerX, uwpY, cWidth, uwpHeight)
        DllCall("ShowWindow", "Ptr", hwnd1, "Int", 5)  ; SW_SHOW
        Log("UWP App 1 shown at startup", "DEBUG")
    }
    
    ; Handle App 2 - Hide on start (will be shown when switching to tab 2)
    if (!app2IsUWP) {
        try WinMaximize("ahk_id " . hwnd2)
        DllCall("ShowWindow", "Ptr", hwnd2, "Int", 0)  ; SW_HIDE
    } else {
        ; UWP apps: Position first, then minimize AND move off-screen
        Log("Positioning UWP App 2 (will be hidden initially)", "DEBUG")
        PositionUWPApp(hwnd2, containerX, uwpY, cWidth, uwpHeight)
        Log("Minimizing UWP App 2", "DEBUG")
        EnsureWindowMinimized(hwnd2, "UWP App 2 (initial hide)")
        ; Then move it off-screen to ensure it's not visible
        Log("Moving UWP App 2 off-screen (-10000, -10000)", "DEBUG")
        hideFlags := 0x0001 | 0x0010 | 0x0080  ; NOSIZE | NOACTIVATE | HIDEWINDOW
        DllCall("SetWindowPos", "Ptr", hwnd2, "Ptr", 1,  ; HWND_BOTTOM
            "Int", -10000, "Int", -10000, "Int", 0, "Int", 0, "UInt", hideFlags)
        minState := GetWindowMinMaxState(hwnd2)
        Log("UWP App 2 state after minimize+move: " . (minState = "" ? "unknown" : minState) . " (-1=minimized, 0=normal, 1=maximized)", "DEBUG")
    }
    
    ; Ensure tabs are always on top (especially over UWP apps)
    tabHwnd := tabs.Hwnd
    DllCall("SetWindowPos", "Ptr", tabHwnd, "Ptr", -1,  ; HWND_TOPMOST
        "Int", 0, "Int", 0, "Int", 0, "Int", 0, "UInt", 0x0013)  ; SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE
    
    tabs.Value := 1
    
    Log("Applications embedded in dual container", "DEBUG")
    
    ; Store handles and UWP status globally
    global app1Hwnd, app2Hwnd, appPid1, appPid2, containerHwnd, appContainerHwnd, containerTabHeight
    global app1IsUWPApp, app2IsUWPApp
    app1Hwnd := hwnd1
    app2Hwnd := hwnd2
    appPid1 := pid1
    appPid2 := pid2
    containerHwnd := container.Hwnd
    appContainerHwnd := appContainer.Hwnd
    containerTabHeight := tabHeight
    app1IsUWPApp := app1IsUWP
    app2IsUWPApp := app2IsUWP
        
    ; Tab switching handler
    tabs.OnEvent("Change", (*) => SwitchTab_Container(tabs, hwnd1, hwnd2))
    
    ; Resize handler
    container.OnEvent("Size", (*) => ResizeApps_Container(tabs, hwnd1, hwnd2, container, appContainer))
    
    ; Setup WTS Session Notifications
    if DllCall("Wtsapi32\WTSRegisterSessionNotification", "ptr", container.Hwnd, "uint", 0, "int") {
        global WTS_NOTIFICATIONS_ACTIVE
        WTS_NOTIFICATIONS_ACTIVE := true
        SetTimer(CheckSessionEvents, 0)  ; Disable any residual polling
        OnMessage(0x02B1, OnSessionChange)
        OnMessage(0x0011, OnQueryEndSession)
        OnExit((*) => (
            DllCall("Wtsapi32\WTSUnRegisterSessionNotification", "ptr", container.Hwnd),
            OnMessage(0x02B1, OnSessionChange, 0),
            OnMessage(0x0011, OnQueryEndSession, 0)
        ))
        Log("Registered for WM_WTSSESSION_CHANGE / WM_QUERYENDSESSION notifications (Container) - polling disabled", "DEBUG")
    } else {
        global WTS_NOTIFICATIONS_ACTIVE
        WTS_NOTIFICATIONS_ACTIVE := false
        Log("WARNING: Could not register for session notifications (Container mode) - falling back to polling", "WARNING")
        
        ; Initialize polling as fallback
        global lastId
        lastId := 0
        SetTimer(CheckSessionEvents, POLL_INTERVAL_MS)
    }
    
    Log("Dual app container initialization complete - monitoring session events", "INFO")
    
}

; Tab switching for container mode
SwitchTab_Container(tabCtrl, hwnd1, hwnd2) {
    try {
        global app1IsUWPApp, app2IsUWPApp, containerHwnd, containerTabHeight
        local containerX := 0, containerY := 0, cWidth := 0, cHeight := 0
        local uwpY := 0, uwpHeight := 0
        
        activeTab := tabCtrl.Value
        
        Log("SwitchTab_Container called - switching to tab " . activeTab . " (App1 UWP=" . app1IsUWPApp . ", App2 UWP=" . app2IsUWPApp . ")", "DEBUG")
        
        ; Get container position for UWP apps
        if (app1IsUWPApp || app2IsUWPApp) {
            try {
                WinGetPos(&containerX, &containerY, &cWidth, &cHeight, "ahk_id " . containerHwnd)
                uwpY := containerY + containerTabHeight
                uwpHeight := cHeight - containerTabHeight
                Log("Container position for UWP: X=" . containerX . " Y=" . containerY . " W=" . cWidth . " H=" . cHeight . " (UWP Y=" . uwpY . " H=" . uwpHeight . ")", "DEBUG")
            } catch as e {
                Log("ERROR: Could not get container position: " . e.message, "ERROR")
                return
            }
        }
        
        if (activeTab = 1) {
            ; Show App 1, hide App 2
            Log("Tab 1 selected - Showing App 1 (HWND=" . hwnd1 . ", UWP=" . app1IsUWPApp . "), Hiding App 2 (HWND=" . hwnd2 . ", UWP=" . app2IsUWPApp . ")", "DEBUG")
            
            if (!app2IsUWPApp) {
                DllCall("RedrawWindow", "Ptr", hwnd2, "Ptr", 0, "Ptr", 0, "UInt", 0x0001)
                DllCall("ShowWindowAsync", "Ptr", hwnd2, "Int", 0)  ; SW_HIDE
                Log("App 2 (non-UWP) hidden", "DEBUG")
            } else {
                ; UWP: Minimize to hide
                Log("Minimizing UWP App 2", "DEBUG")
                EnsureWindowMinimized(hwnd2, "UWP App 2")
                ; Move off-screen to ensure it's not visible
                hideFlags := 0x0001 | 0x0010 | 0x0080  ; NOSIZE | NOACTIVATE | HIDEWINDOW
                DllCall("SetWindowPos", "Ptr", hwnd2, "Ptr", 1,  ; HWND_BOTTOM
                    "Int", -10000, "Int", -10000, "Int", 0, "Int", 0, "UInt", hideFlags)
                state2 := GetWindowMinMaxState(hwnd2)
                Log("App 2 (UWP) minimized and moved off-screen - state: " . (state2 = "" ? "unknown" : state2), "DEBUG")
            }
            
            if (!app1IsUWPApp) {
                Log("Showing non-UWP App 1", "DEBUG")
                DllCall("ShowWindowAsync", "Ptr", hwnd1, "Int", 5)  ; SW_SHOW
                DllCall("RedrawWindow", "Ptr", hwnd1, "Ptr", 0, "Ptr", 0, "UInt", 0x0085)
                ; Force to foreground
                DllCall("SetForegroundWindow", "Ptr", hwnd1)
                Log("App 1 (non-UWP) now visible", "DEBUG")
            } else {
                ; UWP: Restore from minimized state, position, and show
                Log("Showing UWP App 1 - restoring from minimized", "DEBUG")
                stateBefore1 := GetWindowMinMaxState(hwnd1)
                Log("App 1 state before restore: " . (stateBefore1 = "" ? "unknown" : stateBefore1), "DEBUG")
                if (!EnsureWindowRestored(hwnd1, "UWP App 1")) {
                    Log("WARNING: EnsureWindowRestored returned false for UWP App 1 - forcing ShowWindow", "WARNING")
                    DllCall("ShowWindow", "Ptr", hwnd1, "Int", 9)
                }
                DllCall("ShowWindow", "Ptr", hwnd1, "Int", 1)  ; SW_SHOWNORMAL to clear maximize state
                stateAfter1 := GetWindowMinMaxState(hwnd1)
                Log("App 1 state after restore: " . (stateAfter1 = "" ? "unknown" : stateAfter1), "DEBUG")
                PositionUWPApp(hwnd1, containerX, uwpY, cWidth, uwpHeight)
                showFlags := 0x0040  ; SHOWWINDOW
                DllCall("SetWindowPos", "Ptr", hwnd1, "Ptr", 0,  ; HWND_TOP
                    "Int", containerX, "Int", uwpY, "Int", cWidth, "Int", uwpHeight, "UInt", showFlags)
                DllCall("ShowWindowAsync", "Ptr", hwnd1, "Int", 5)  ; SW_SHOW
                DllCall("SetForegroundWindow", "Ptr", hwnd1)
                DllCall("RedrawWindow", "Ptr", hwnd1, "Ptr", 0, "Ptr", 0, "UInt", 0x0085)
                finalState1 := GetWindowMinMaxState(hwnd1)
                Log("App 1 (UWP) should now be visible - final state: " . (finalState1 = "" ? "unknown" : finalState1), "DEBUG")
            }
        } else {
            ; Show App 2, hide App 1
            Log("Tab 2 selected - Hiding App 1 (HWND=" . hwnd1 . ", UWP=" . app1IsUWPApp . "), Showing App 2 (HWND=" . hwnd2 . ", UWP=" . app2IsUWPApp . ")", "DEBUG")
            
            if (!app1IsUWPApp) {
                DllCall("RedrawWindow", "Ptr", hwnd1, "Ptr", 0, "Ptr", 0, "UInt", 0x0001)
                DllCall("ShowWindowAsync", "Ptr", hwnd1, "Int", 0)  ; SW_HIDE
                Log("App 1 (non-UWP) hidden", "DEBUG")
            } else {
                ; UWP: Minimize to hide
                Log("Minimizing UWP App 1", "DEBUG")
                EnsureWindowMinimized(hwnd1, "UWP App 1")
                hideFlags := 0x0001 | 0x0010 | 0x0080  ; NOSIZE | NOACTIVATE | HIDEWINDOW
                DllCall("SetWindowPos", "Ptr", hwnd1, "Ptr", 1,  ; HWND_BOTTOM
                    "Int", -10000, "Int", -10000, "Int", 0, "Int", 0, "UInt", hideFlags)
                state1 := GetWindowMinMaxState(hwnd1)
                Log("App 1 (UWP) minimized and moved off-screen - state: " . (state1 = "" ? "unknown" : state1), "DEBUG")
            }
            
            if (!app2IsUWPApp) {
                Log("Showing non-UWP App 2", "DEBUG")
                DllCall("ShowWindowAsync", "Ptr", hwnd2, "Int", 5)  ; SW_SHOW
                DllCall("RedrawWindow", "Ptr", hwnd2, "Ptr", 0, "Ptr", 0, "UInt", 0x0085)
                ; Force to foreground
                DllCall("SetForegroundWindow", "Ptr", hwnd2)
                Log("App 2 (non-UWP) now visible", "DEBUG")
            } else {
                ; UWP: Restore from minimized state, position, and show
                Log("Showing UWP App 2 - restoring from minimized", "DEBUG")
                stateBefore2 := GetWindowMinMaxState(hwnd2)
                Log("App 2 state before restore: " . (stateBefore2 = "" ? "unknown" : stateBefore2), "DEBUG")
                if (!EnsureWindowRestored(hwnd2, "UWP App 2")) {
                    Log("WARNING: EnsureWindowRestored returned false for UWP App 2 - forcing ShowWindow", "WARNING")
                    DllCall("ShowWindow", "Ptr", hwnd2, "Int", 9)
                }
                DllCall("ShowWindow", "Ptr", hwnd2, "Int", 1)  ; SW_SHOWNORMAL to clear maximize state
                stateAfter2 := GetWindowMinMaxState(hwnd2)
                Log("App 2 state after restore: " . (stateAfter2 = "" ? "unknown" : stateAfter2), "DEBUG")
                PositionUWPApp(hwnd2, containerX, uwpY, cWidth, uwpHeight)
                showFlags := 0x0040  ; SHOWWINDOW
                DllCall("SetWindowPos", "Ptr", hwnd2, "Ptr", 0,  ; HWND_TOP
                    "Int", containerX, "Int", uwpY, "Int", cWidth, "Int", uwpHeight, "UInt", showFlags)
                DllCall("ShowWindowAsync", "Ptr", hwnd2, "Int", 5)  ; SW_SHOW
                DllCall("SetForegroundWindow", "Ptr", hwnd2)
                DllCall("RedrawWindow", "Ptr", hwnd2, "Ptr", 0, "Ptr", 0, "UInt", 0x0085)
                finalState2 := GetWindowMinMaxState(hwnd2)
                Log("App 2 (UWP) should now be visible - final state: " . (finalState2 = "" ? "unknown" : finalState2), "DEBUG")
            }
        }
    } catch as e {
        Log("ERROR in SwitchTab_Container: " . e.message . " at line " . e.line, "ERROR")
    }
}

; Resize apps when container resizes
ResizeApps_Container(tabCtrl, hwnd1, hwnd2, container, appContainer) {
    global containerTabHeight, app1IsUWPApp, app2IsUWPApp
    
    activeTab := tabCtrl.Value
    
    container.GetPos(&containerX, &containerY, &cWidth, &cHeight)
    
    ; Apps fill entire screen
    appContainer.Move(0, 0, cWidth, cHeight)
    
    ; Update tab control to match calculated height and keep on top
    tabHwnd := tabCtrl.Hwnd
    DllCall("SetWindowPos", "Ptr", tabHwnd, "Ptr", -1,  ; Keep HWND_TOPMOST
        "Int", 0, "Int", 0, "Int", cWidth, "Int", containerTabHeight, "UInt", 0x0010)  ; SWP_NOACTIVATE
    
    ; Calculate position below tabs for UWP apps
    uwpY := containerY + containerTabHeight
    uwpHeight := cHeight - containerTabHeight
    
    ; Resize apps - only resize the currently visible app (especially important for UWP)
    if (activeTab = 1) {
        ; Tab 1 active - resize App 1
        if (!app1IsUWPApp) {
            try WinMaximize("ahk_id " . hwnd1)
        } else {
            PositionUWPApp(hwnd1, containerX, uwpY, cWidth, uwpHeight)
        }
        ; App 2 stays hidden (off-screen for UWP, hidden for normal)
    } else {
        ; Tab 2 active - resize App 2
        if (!app2IsUWPApp) {
            try WinMaximize("ahk_id " . hwnd2)
        } else {
            PositionUWPApp(hwnd2, containerX, uwpY, cWidth, uwpHeight)
        }
        ; App 1 stays hidden (off-screen for UWP, hidden for normal)
    }
}
