; ============================================================================
; WindowClosing.ahk - Window Closing Functions
; ============================================================================
; Functions for gracefully closing windows with multiple fallback methods
; ============================================================================
#Include Config.ahk
#Include Utils.ahk

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

; Universal close cascade for a single application window
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

; Main close window function for the unchanged single-app mode
ForceCloseWindow(targetWin, closeWait := 2) {
    return CloseWindowCascade(targetWin, closeWait, false)
}
