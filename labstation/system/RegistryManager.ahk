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
        basePath := "HKLM\\SOFTWARE\\Policies\\Microsoft\\Windows NT\\Terminal Services"
        try {
            RegWrite(1, "REG_DWORD", basePath, "fAllowUnlistedRemotePrograms")
            LS_LogInfo("RemoteApp policy 'fAllowUnlistedRemotePrograms' set to 1")
            return true
        } catch as e {
            LS_LogError("Cannot set RemoteApp policy: " . e.Message)
            return false
        }
    }

    static SetRunEntry(valueName, command) {
        if (!LS_EnsureAdmin()) {
            return false
        }
        basePath := "HKLM\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Run"
        try {
            RegWrite(command, "REG_SZ", basePath, valueName)
            LS_LogInfo("Run entry '" . valueName . "' configured")
            return true
        } catch as e {
            LS_LogError("Cannot configure Run entry '" . valueName . "': " . e.Message)
            return false
        }
    }
}
