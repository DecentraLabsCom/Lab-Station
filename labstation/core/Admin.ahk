; ============================================================================
; Lab Station - Administrative helpers
; ============================================================================
#Requires AutoHotkey v2.0
#Include Config.ahk
#Include Logger.ahk

LS_EnsureAdmin(prompt := true) {
    if (A_IsAdmin) {
        return true
    }
    if (prompt) {
        LS_ShowMessage("Lab Station requires administrator privileges for this action." . "`n" .
            "Run the executable or script with 'Run as administrator'.", "Lab Station", "OK Icon!")
    }
    LS_LogWarning("Administrative privileges required but not granted")
    return false
}

LS_EscapeCliArgument(value) {
    quote := Chr(34)
    if (value = "") {
        return quote quote
    }
    if !RegExMatch(value, "[\s" . quote . "]") {
        return value
    }
    escaped := StrReplace(value, quote, "\" . quote)
    return quote . escaped . quote
}
