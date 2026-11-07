; ============================================================================
; Lab Station - Protected RemoteApp workspace configuration store
; ============================================================================
#Requires AutoHotkey v2.0
#Include ..\core\Config.ahk
#Include ..\core\Admin.ahk
#Include ..\core\Shell.ahk
#Include ..\core\Logger.ahk
#Include ..\..\remote-app\lib\WorkspaceConfig.ahk

class LS_RemoteAppWorkspaceStore {
    static Ensure() {
        global APP_WORKSPACE_CONFIG_ROOT

        if (!LS_EnsureAdmin())
            return false

        script := this.BuildEnsureScript(APP_WORKSPACE_CONFIG_ROOT)

        capture := LS_RunPowerShellCapture(script, "Protect RemoteApp workspace configuration", LAB_STATION_LONG_COMMAND_TIMEOUT_MS)
        ready := capture["exitCode"] = 0 && InStr(capture["stdout"], "LABSTATION_REMOTEAPP_WORKSPACE_STORE_READY") > 0
        if (ready) {
            LS_LogInfo("Protected RemoteApp workspace store is ready: " . APP_WORKSPACE_CONFIG_ROOT)
            return true
        }

        detail := LS_CaptureDetail(capture)
        LS_LogError("Unable to prepare the protected RemoteApp workspace store" . (detail != "" ? ": " . detail : ""))
        return false
    }

    static BuildEnsureScript(workspaceRoot) {
        root := StrReplace(workspaceRoot, "'", "''")
        script := ""
            . "`$ErrorActionPreference = 'Stop'`n"
            . "`$workspaceRoot = '" . root . "'`n"
            . "`$workspaceParent = Split-Path `$workspaceRoot -Parent`n"
            . "New-Item -Path `$workspaceRoot -ItemType Directory -Force | Out-Null`n"
            . "foreach (`$path in @(`$workspaceParent, `$workspaceRoot)) {`n"
            . "  & icacls.exe `$path /reset /T /C 2>&1 | Out-Null`n"
            . "  if (`$LASTEXITCODE -ne 0) { throw 'Unable to reset workspace directory permissions' }`n"
            . "  & icacls.exe `$path /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)(F)' '*S-1-5-32-544:(OI)(CI)(F)' '*S-1-5-32-545:(OI)(CI)(RX)' /T /C 2>&1 | Out-Null`n"
            . "  if (`$LASTEXITCODE -ne 0) { throw 'Unable to apply protected workspace directory permissions' }`n"
            . "}`n"
            . "`$manifestFiles = @(Get-ChildItem -LiteralPath `$workspaceRoot -Filter '*.json' -File -Recurse)`n"
            . "foreach (`$manifest in `$manifestFiles) {`n"
            . "  & icacls.exe `$manifest.FullName /grant:r '*S-1-5-32-545:(R)' /C /Q | Out-Null`n"
            . "  if (`$LASTEXITCODE -ne 0) { throw 'Unable to grant read access to workspace manifest' }`n"
            . "}`n"
            . "Write-Output 'LABSTATION_REMOTEAPP_WORKSPACE_STORE_READY'`n"
        return script
    }
}
