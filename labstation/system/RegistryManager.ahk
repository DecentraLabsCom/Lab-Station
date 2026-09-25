; ============================================================================
; Lab Station - Registry helpers
; ============================================================================
#Requires AutoHotkey v2.0
#Include ..\core\Config.ahk
#Include ..\core\Logger.ahk
#Include ..\core\Admin.ahk

class LS_RegistryManager {
    static SetRemoteAppPolicy() {
        if (!LS_EnsureAdmin()) {
            return false
        }
        basePath := "HKLM\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services"
        try {
            RegWrite(1, "REG_DWORD", basePath, "fAllowUnlistedRemotePrograms")
            LS_LogInfo("RemoteApp policy 'fAllowUnlistedRemotePrograms' set to 1")
            return true
        } catch as e {
            LS_LogError("Cannot set RemoteApp policy: " . e.Message)
            return false
        }
    }

    static RemoveRunEntry(valueName) {
        if (!LS_EnsureAdmin()) {
            return false
        }
        basePath := "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Run"
        try {
            RegDelete(basePath, valueName)
            LS_LogInfo("Run entry '" . valueName . "' removed")
            return true
        } catch as e {
            ; Removing an already absent migration entry is idempotent.
            try {
                RegRead(basePath, valueName)
                LS_LogError("Cannot remove Run entry '" . valueName . "': " . e.Message)
                return false
            } catch {
                LS_LogInfo("Run entry '" . valueName . "' was already absent")
                return true
            }
        }
    }
}
