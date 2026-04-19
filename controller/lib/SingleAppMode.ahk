; ============================================================================
; SingleAppMode.ahk - Single Application Mode
; ============================================================================
; Functions for managing a single application with RDP disconnect handling
; ============================================================================

CreateSingleApp(windowClass, appCommand) {
    global target, STARTUP_TIMEOUT, ACTIVATION_RETRIES, SILENT_ERRORS, TEST_MODE, CUSTOM_CLOSE_METHOD
    global WINDOW_STATE_TIMEOUT_MS, WINDOW_STATE_POLL_INTERVAL_MS
    
    Log("Initializing single app mode", "INFO")
    
    ; Extract executable path for window identification
    appPath := ExtractExecutablePath(appCommand)
    
    ; Precise window identification - handle both executables and scripts
    SplitPath(appPath, &exeName, , &ext)
    if (StrLower(ext) = "exe") {
        target := "ahk_class " . windowClass . " ahk_exe " . exeName
    } else {
        ; For non-exe files (scripts, batch, etc.), use only class name
        ; as the actual process name might be different (cmd.exe, java.exe, etc.)
        target := "ahk_class " . windowClass
    }
    
    ; --- App launch/activation ---
    Log("Target window specification: " . target)
    if !WinExist(target) {
        Log("Target window not found, attempting to launch application...", "DEBUG")
        ; Validate that the application file exists before trying to run it
        if !FileExist(appPath) {
            Log("ERROR: Application executable not found: " . appPath)
            if !SILENT_ERRORS
                MsgBox "Application executable not found: " . appPath
            ExitApp
        }
        
        Log("Launching app: " . appCommand)
        startTime := A_TickCount
        Run(appCommand)
        Log("Waiting for window to appear (timeout: " . STARTUP_TIMEOUT . "s)...")
        if !WinWait(target, , STARTUP_TIMEOUT) {
            elapsedTime := (A_TickCount - startTime) / 1000
            Log("ERROR: Window did not appear within timeout (waited " . Format("{:.1f}", elapsedTime) . "s)")
            if !SILENT_ERRORS
                MsgBox "Couldn't open lab app at: " . appCommand . "`n`nWindow class '" . windowClass . "' not found after " . Format("{:.1f}", elapsedTime) . "s"
            ExitApp
        }
        
        elapsedTime := (A_TickCount - startTime) / 1000
        Log("Window appeared successfully after " . Format("{:.1f}", elapsedTime) . "s")
    } else {
        Log("Target window already exists, activating it", "DEBUG")
    }
    
    ; Ensure foreground and maximized (with retry logic)
    Log("Activating and maximizing window...", "DEBUG")
    activationSuccess := false
    
    Loop ACTIVATION_RETRIES {
        attempt := A_Index
        ; Check if window still exists before each operation
        if !WinExist(target) {
            if (attempt < ACTIVATION_RETRIES) {
                Log("Window temporarily unavailable (attempt " . attempt . "/" . ACTIVATION_RETRIES . ") - waiting for it to return", "DEBUG")
                if (!WaitUntil(() => WinExist(target), WINDOW_STATE_TIMEOUT_MS, WINDOW_STATE_POLL_INTERVAL_MS)) {
                    Log("Window still missing after wait period (attempt " . attempt . ")", "WARNING")
                }
                continue
            } else {
                Log("ERROR: Window disappeared and did not reappear after " . ACTIVATION_RETRIES . " attempts")
                if !SILENT_ERRORS
                    MsgBox "Window '" . windowClass . "' disappeared unexpectedly.`n`nThis may happen if Groupy is processing the window."
                ExitApp
            }
        }
        
        ; Try to activate
        try {
            WinActivate(target)
            active := WaitUntil(() => WinActive(target), WINDOW_STATE_TIMEOUT_MS, WINDOW_STATE_POLL_INTERVAL_MS)
            
            if (active || WinExist(target)) {
                try {
                    WinMaximize(target)
                    activationSuccess := true
                    Log("Window activated and maximized successfully (attempt " . attempt . ")")
                    break
                } catch as e {
                    Log("Maximize failed on attempt " . attempt . ": " . e.message)
                }
            } else {
                Log("Activation did not complete on attempt " . attempt, "WARNING")
            }
        } catch as e {
            Log("WinActivate failed on attempt " . attempt . ": " . e.message)
        }
    }
    
    if !activationSuccess {
        Log("WARNING: Could not reliably activate/maximize window after " . ACTIVATION_RETRIES . " attempts - continuing anyway...")
        ; Don't exit - the window exists, we just couldn't activate it perfectly
    }
    
    ; Additional maximization attempt for apps like Firefox that don't respond to WinMaximize immediately
    ; This is done after the window styles are modified
    WaitUntil(() => WinExist(target), WINDOW_STATE_TIMEOUT_MS, WINDOW_STATE_POLL_INTERVAL_MS)
    try {
        WinMaximize(target)
        Log("Additional maximization attempt completed", "DEBUG")
    } catch as e {
        Log("Additional maximization attempt failed: " . e.message)
    }
    
    ; Remove minimize and close buttons (but keep title bar)
    ; Use try/catch to handle cases where window style cannot be modified
    try {
        WinSetStyle("-0x20000", target) ; WS_MINIMIZEBOX
        WinSetStyle("-0x80000", target) ; WS_SYSMENU (removes close button and system menu)
        Log("Window styles modified successfully (minimize/close buttons removed)", "DEBUG")
    } catch as e {
        Log("WARNING: Could not modify window styles: " . e.message)
    }
    
    ; Setup RDP monitoring using unified function
    SetupRdpMonitoring(A_ScriptHwnd)
    
    ; TEST MODE: Simulate custom close after 5 seconds (for coordinate testing)
    if (TEST_MODE && CUSTOM_CLOSE_METHOD != "none") {
        Log("TEST MODE ENABLED - Will test custom close in 5 seconds...", "DEBUG")
        SetTimer(TestCustomClose, 5000, -1)  ; Run once after 5 seconds
    }
    
    Log("Single app mode initialization complete - monitoring session events", "INFO")
}

; TEST FUNCTION: Test custom close coordinates/control
TestCustomClose() {
    global target, CUSTOM_CLOSE_METHOD
    
    Log("TEST MODE: Testing custom close method: " . CUSTOM_CLOSE_METHOD)
    
    if !WinExist(target) {
        Log("TEST MODE: Target window no longer exists - cannot test", "DEBUG")
        return
    }
    
    ; Try the custom close method
    if TryCustomGracefulClose(target, 3) {
        Log("TEST MODE: ✅ Custom close SUCCESSFUL - coordinates/control work correctly!", "DEBUG")
        ExitApp  ; Exit after successful test
    } else {
        Log("TEST MODE: ❌ Custom close FAILED - check coordinates/control name", "DEBUG")
        ; Don't exit, let user see the result
    }
}
