; ============================================================================
; Lab Station - Wake-on-LAN configuration
; ============================================================================
#Requires AutoHotkey v2.0
#Include ..\core\Config.ahk
#Include ..\core\Logger.ahk
#Include ..\core\Admin.ahk
#Include ..\core\Shell.ahk

class LS_WakeOnLan {
    static Configure() {
        if (!LS_EnsureAdmin()) {
            return false
        }
        script := "
        (
$adapters = Get-NetAdapter -Physical | Where-Object { `$_.Status -eq 'Up' }
if (-not `$adapters) {
    Write-Output 'No adapters detected'
    exit 0
}
foreach (`$adapter in `$adapters) {
    try {
        powercfg /deviceenablewake "`$(`$adapter.Name)" | Out-Null
    } catch {
    }
    try {
        Set-NetAdapterAdvancedProperty -Name `$adapter.Name -DisplayName 'Wake on Magic Packet' -DisplayValue 'Enabled' -ErrorAction SilentlyContinue
        Set-NetAdapterAdvancedProperty -Name `$adapter.Name -DisplayName 'Wake on pattern match' -DisplayValue 'Enabled' -ErrorAction SilentlyContinue
    } catch {
    }
}
# Configure global power plan to avoid sleep on AC
powercfg /change standby-timeout-ac 0 | Out-Null
powercfg /change hibernate-timeout-ac 0 | Out-Null
        )"
        exitCode := LS_RunPowerShell(script, "Configure Wake-on-LAN")
        if (exitCode = 0) {
            LS_LogInfo("Wake-on-LAN configuration applied")
            return true
        }
        LS_LogError("Wake-on-LAN configuration failed (ExitCode=" . exitCode . ")")
        return false
    }
}
