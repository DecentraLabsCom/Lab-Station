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
            if TryCoordinateGracefulClose(target, customCloseX, customCloseY, timeoutSec)
                return true
    }
    
    Log("Custom graceful close failed, will use standard closing methods", "DEBUG")
    return false
}

; Coordinate close shared by single-app and workspace modes. A callback can
; supply a host-aware physical click; PostMessage always targets the supplied
; window and uses that window's client coordinates.
TryCoordinateGracefulClose(target, x, y, timeoutSec := 3, performClick := true, clickCallback := 0) {
    if !WinExist(target)
        return false

    Log("Attempting X,Y close at coordinates: " . x . "," . y, "DEBUG")
    if (performClick) {
        try {
            if IsObject(clickCallback) {
                clickSucceeded := clickCallback.Call()
                if (clickSucceeded)
                    Log("Clicked at coordinates: " . x . "," . y)
                else
                    Log("Physical coordinate click could not be performed; trying PostMessage", "DEBUG")
            } else {
                WinActivate(target)
                Sleep(300)
                Click(x, y)
                Log("Clicked at coordinates: " . x . "," . y)
            }
        } catch as e {
            Log("Coordinate click failed; trying PostMessage: " . e.Message, "WARNING")
        }
    } else {
        Log("Skipping physical coordinate click because target is not active and visible", "DEBUG")
    }

    if WinExist(target) {
        Log("First click may not have worked - trying PostMessage click", "DEBUG")
        try {
            PostMessage(0x0201, 0, (y << 16) | x, , target) ; WM_LBUTTONDOWN
            PostMessage(0x0202, 0, (y << 16) | x, , target) ; WM_LBUTTONUP
        } catch as e {
            Log("PostMessage coordinate close failed: " . e.Message, "WARNING")
        }
    }

    return WinWaitClose(target, , timeoutSec)
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
