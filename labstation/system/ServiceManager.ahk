; ============================================================================
; Lab Station - Background service via Task Scheduler
; ============================================================================
#Requires AutoHotkey v2.0
#Include ..\core\Config.ahk
#Include ..\core\Logger.ahk
#Include ..\core\Admin.ahk
#Include ..\core\Shell.ahk
#Include ..\core\Json.ahk

class LS_ServiceManager {
    static TaskName := "LabStation\BackgroundService"

    static Install() {
        if (!LS_EnsureAdmin()) {
            return false
        }
        if (A_IsCompiled) {
            exe := Format('"{1}" service-loop', A_ScriptFullPath)
        } else {
            exe := Format('"{1}" "{2}" service-loop', A_AhkPath, LAB_STATION_ROOT "\LabStation.ahk")
        }
        cmd := Format('schtasks /create /TN "{1}" /TR "{2}" /SC ONSTART /RL HIGHEST /RU SYSTEM /F', this.TaskName, exe)
        result := LS_RunCommand(cmd, "Create Lab Station service task")
        if (result = 0) {
            LS_LogInfo("Lab Station background task installed")
            return true
        }
        LS_LogError("Failed to install background task (exit=" . result . ")")
        return false
    }

    static Uninstall() {
        if (!LS_EnsureAdmin()) {
            return false
        }
        cmd := Format('schtasks /delete /TN "{1}" /F', this.TaskName)
        result := LS_RunCommand(cmd, "Delete Lab Station service task")
        if (result = 0) {
            LS_LogInfo("Background task removed")
            return true
        }
        LS_LogWarning("Failed to delete background task (exit=" . result . ")")
        return false
    }

    static Start() {
        cmd := Format('schtasks /run /TN "{1}"', this.TaskName)
        result := LS_RunCommand(cmd, "Start Lab Station task")
        return result = 0
    }

    static Stop() {
        cmd := Format('schtasks /end /TN "{1}"', this.TaskName)
        result := LS_RunCommand(cmd, "Stop Lab Station task")
        return result = 0
    }

    static StatusText() {
        cmd := Format('schtasks /query /TN "{1}" /FO LIST /V', this.TaskName)
        capture := LS_RunCommandCapture(cmd, "Query Lab Station task")
        return capture["stdout"] ? capture["stdout"] : capture["stderr"]
    }

    static GetStatus() {
        script := "
        (
$taskPath = '\LabStation\'
$taskName = 'BackgroundService'
try {
    $task = Get-ScheduledTask -TaskPath $taskPath -TaskName $taskName -ErrorAction Stop
    [pscustomobject]@{
        installed = $true
        state = [string]$task.State
        running = ([string]$task.State -eq 'Running')
        restartable = $true
    } | ConvertTo-Json -Compress
} catch {
    [pscustomobject]@{
        installed = $false
        state = 'Not installed'
        running = $false
        restartable = $false
    } | ConvertTo-Json -Compress
}
        )"
        capture := LS_RunPowerShellCapture(script, "Query Lab Station scheduled task")
        if (capture["exitCode"] != 0 || Trim(capture["stdout"]) = "") {
            return Map("installed", false, "state", "Unknown", "running", false, "restartable", false)
        }
        try {
            parsed := LS_ParseJson(capture["stdout"])
            return Map(
                "installed", parsed.Has("installed") && parsed["installed"],
                "state", parsed.Has("state") ? parsed["state"] : "Unknown",
                "running", parsed.Has("running") && parsed["running"],
                "restartable", parsed.Has("restartable") && parsed["restartable"]
            )
        } catch {
            return Map("installed", false, "state", "Unknown", "running", false, "restartable", false)
        }
    }
}
