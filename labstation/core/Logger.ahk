; ============================================================================
; Lab Station - Logging helpers
; ============================================================================
#Requires AutoHotkey v2.0
#Include Config.ahk

LS_Log(message, level := "INFO") {
    global LAB_STATION_LOG
    timestamp := FormatTime(A_Now, "yyyy-MM-dd HH:mm:ss")
    entry := Format("{1} [{2}] {3}`n", timestamp, level, message)
    try {
        FileAppend(entry, LAB_STATION_LOG, "UTF-8")
    } catch {
        ; Swallow logging errors to avoid breaking workflows
    }
    OutputDebug("LabStation - " . entry)
}

LS_LogInfo(message) {
    LS_Log(message, "INFO")
}

LS_LogWarning(message) {
    LS_Log(message, "WARNING")
}

LS_LogError(message) {
    LS_Log(message, "ERROR")
}
