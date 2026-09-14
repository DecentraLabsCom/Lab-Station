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
        if (!this.EnsureAdmin()) {
            return false
        }
        if (A_IsCompiled) {
            executable := A_ScriptFullPath
            arguments := "service-loop"
            workingDirectory := A_ScriptDir
        } else {
            executable := A_AhkPath
            arguments := '"' . LAB_STATION_ROOT "\LabStation.ahk" . '" service-loop'
            workingDirectory := LAB_STATION_ROOT
        }
        script := this.BuildInstallScript(executable, arguments, workingDirectory)
        capture := this.RunPowerShellCapture(
            script,
            "Create Lab Station service task",
            LAB_STATION_LONG_COMMAND_TIMEOUT_MS
        )
        result := capture["exitCode"]
        if (result = 0) {
            LS_LogInfo("Lab Station background task installed")
            return true
        }
        detail := LS_CaptureDetail(capture)
        if (detail != "")
            LS_LogError("Failed to install background task (exit=" . result . "): " . detail)
        else
            LS_LogError("Failed to install background task (exit=" . result . ")")
        return false
    }

    static BuildInstallScript(executable, arguments, workingDirectory) {
        escapedExecutable := this.EscapeForPSSingleQuote(executable)
        escapedArguments := this.EscapeForPSSingleQuote(arguments)
        escapedWorkingDirectory := this.EscapeForPSSingleQuote(workingDirectory)
        template := "
        (
$ErrorActionPreference = 'Stop'
$taskPath = '\LabStation\'
$taskName = 'BackgroundService'
$execute = '__TASK_EXECUTABLE__'
$argumentList = '__TASK_ARGUMENTS__'
$workingDirectory = '__TASK_WORKING_DIRECTORY__'

if (-not (Get-Command -Name 'New-ScheduledTaskAction' -ErrorAction SilentlyContinue)) {
    throw 'ScheduledTasks PowerShell cmdlets are not available'
}

$action = New-ScheduledTaskAction -Execute $execute -Argument $argumentList -WorkingDirectory $workingDirectory
$trigger = New-ScheduledTaskTrigger -AtStartup
$principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
Register-ScheduledTask -TaskPath $taskPath -TaskName $taskName -Action $action -Trigger $trigger -Principal $principal -Force | Out-Null
Write-Output ('Registered scheduled task: ' + $taskPath + $taskName)
        )"
        template := StrReplace(template, "__TASK_EXECUTABLE__", escapedExecutable)
        template := StrReplace(template, "__TASK_ARGUMENTS__", escapedArguments)
        return StrReplace(template, "__TASK_WORKING_DIRECTORY__", escapedWorkingDirectory)
    }

    static EscapeForPSSingleQuote(value) {
        return StrReplace(value, "'", "''")
    }

    static Uninstall() {
        if (!this.EnsureAdmin()) {
            return false
        }
        cmd := Format('schtasks /delete /TN "{1}" /F', this.TaskName)
        result := this.RunCommand(cmd, "Delete Lab Station service task")
        if (result = 0) {
            LS_LogInfo("Background task removed")
            return true
        }
        LS_LogWarning("Failed to delete background task (exit=" . result . ")")
        return false
    }

    static Start() {
        cmd := Format('schtasks /run /TN "{1}"', this.TaskName)
        result := this.RunCommand(cmd, "Start Lab Station task")
        return result = 0
    }

    static Stop() {
        cmd := Format('schtasks /end /TN "{1}"', this.TaskName)
        result := this.RunCommand(cmd, "Stop Lab Station task")
        return result = 0
    }

    static StatusText() {
        cmd := Format('schtasks /query /TN "{1}" /FO LIST /V', this.TaskName)
        capture := this.RunCommandCapture(cmd, "Query Lab Station task")
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
        capture := this.RunPowerShellCapture(script, "Query Lab Station scheduled task")
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

    static EnsureAdmin() {
        return LS_EnsureAdmin()
    }

    static RunCommand(command, description) {
        return LS_RunCommand(command, description)
    }

    static RunCommandCapture(command, description) {
        return LS_RunCommandCapture(command, description)
    }

    static RunPowerShellCapture(script, description, timeoutMs := 0) {
        return LS_RunPowerShellCapture(script, description, timeoutMs)
    }
}
