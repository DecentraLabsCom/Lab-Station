; ============================================================================
; WindowClosing.ahk - Window Closing Functions
; ============================================================================
; Functions for gracefully closing windows with multiple fallback methods
; ============================================================================

; Universal graceful close for any desktop application with custom close buttons
TryCustomGracefulClose(target, timeoutSec := 3) {
    global CUSTOM_CLOSE_METHOD, customCloseControl, customCloseX, customCloseY

    if !WinExist(target) {
        return false
    }
    
    Log("Attempting custom graceful close using method: " . CUSTOM_CLOSE_METHOD)
    
    switch CUSTOM_CLOSE_METHOD {
        case "control":
            try {
                Log("Attempting control click in (pre)disconnected session", "DEBUG")
                ControlClick(customCloseControl, target)
                Log("Clicked custom close button via control: " . customCloseControl)
                
                Sleep(500)
                if WinExist(target) {
                    Log("Control click may not have worked - trying ControlSend {Enter}", "DEBUG")
                    ControlSend("{Enter}", customCloseControl, target)
                }
                
                if WinWaitClose(target, , timeoutSec) {
                    return true
                }
            }
        
        case "coordinates":
            try {                
                Log("Attempting X,Y click in (pre)disconnected session", "DEBUG")
                WinActivate(target)
                Sleep(300)
                Click(customCloseX, customCloseY)
                Log("Clicked at coordinates: " . customCloseX . "," . customCloseY)
                
                if WinExist(target) {
                    Log("First click may not have worked - trying PostMessage click", "DEBUG")
                    PostMessage(0x0201, 0, (customCloseY << 16) | customCloseX, , target) ; WM_LBUTTONDOWN
                    PostMessage(0x0202, 0, (customCloseY << 16) | customCloseX, , target) ; WM_LBUTTONUP
                }
                
                if WinWaitClose(target, , timeoutSec) {
                    return true
                }
            }
    }
    
    Log("Custom graceful close failed, will use standard closing methods", "DEBUG")
    return false
}

; Universal close cascade for any window (single app, dual app, or container)
CloseWindowCascade(target, closeWait := 2, isEmbedded := false) {
    global CUSTOM_CLOSE_METHOD
    
    logPrefix := isEmbedded ? "  Embedded app " : ""
    
    ; 0) Try custom graceful close first (only if method is configured and not embedded)
    if (!isEmbedded && WinExist(target) && (CUSTOM_CLOSE_METHOD != "none")) {
        if TryCustomGracefulClose(target, closeWait) {
            Log(logPrefix . "Custom graceful close succeeded")
            return true
        }
    }
    
    ; 1) Gentle close
    if WinExist(target) {
        WinClose(target)
        if WinWaitClose(target, , closeWait) {
            Log(logPrefix . "Gentle close succeeded")
            return true
        }
    }
    
    ; 2) System command message (WM_SYSCOMMAND / SC_CLOSE)
    if WinExist(target) {
        PostMessage(0x0112, 0xF060, 0, , target)
        if WinWaitClose(target, , closeWait) {
            Log(logPrefix . "System command close succeeded")
            return true
        }
    }
    
    ; 3) Direct close message (WM_CLOSE)
    if WinExist(target) {
        PostMessage(0x0010, 0, 0, , target)
        if WinWaitClose(target, , closeWait) {
            Log(logPrefix . "Direct close succeeded")
            return true
        }
    }
    
    ; 4) Kill process (hard)
    if WinExist(target) {
        pid := WinGetPID(target)
        try {
            ProcessClose(pid)
            ProcessWaitClose(pid, closeWait)
        } catch {
            RunWait(A_ComSpec . ' /C taskkill /PID ' . pid . ' /T /F', , 'Hide')
            try ProcessWaitClose(pid, closeWait)
        }
        Log(logPrefix . "Kill process")
        return !WinExist(target)
    }
    return true
}

; Main close window function - handles container detection for dual mode
ForceCloseWindow(targetWin, closeWait := 2) {
    global CUSTOM_CLOSE_METHOD, DUAL_APP_MODE
    
    ; SPECIAL HANDLING: If closing container in dual mode, close embedded apps FIRST
    if (DUAL_APP_MODE && WinExist(targetWin)) {
        targetClass := WinGetClass(targetWin)
        if (targetClass = "AutoHotkeyGUI") {
            Log("Dual mode container close detected - closing embedded apps first", "DEBUG")
            
            global app1Hwnd, app2Hwnd
            Log("App1Hwnd=" . app1Hwnd . ", App2Hwnd=" . app2Hwnd)
            
            ; Close App 1
            if (app1Hwnd != 0) {
                if (WinExist("ahk_id " . app1Hwnd)) {
                    Log("Closing embedded App 1 (hwnd: " . app1Hwnd . ")")
                    CloseWindowCascade("ahk_id " . app1Hwnd, closeWait, true)
                } else {
                    Log("WARNING: App 1 window (hwnd: " . app1Hwnd . ") does not exist - may have already closed")
                }
            }
            
            ; Close App 2
            if (app2Hwnd != 0) {
                if (WinExist("ahk_id " . app2Hwnd)) {
                    Log("Closing embedded App 2 (hwnd: " . app2Hwnd . ")")
                    CloseWindowCascade("ahk_id " . app2Hwnd, closeWait, true)
                } else {
                    Log("WARNING: App 2 window (hwnd: " . app2Hwnd . ") does not exist - may have already closed")
                }
            }
            
            Sleep(500)  ; Delay for resource cleanup
            Log("Embedded apps closed - now closing container", "DEBUG")
        }
    }
    
    ; Close the window using standard cascade
    return CloseWindowCascade(targetWin, closeWait, false)
}
