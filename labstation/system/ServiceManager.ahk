; ============================================================================
; Lab Station - Background service via Task Scheduler
; ============================================================================
#Requires AutoHotkey v2.0
#Include ..\core\Config.ahk
#Include ..\core\Logger.ahk
#Include ..\core\Admin.ahk
#Include ..\core\Shell.ahk

class LS_ServiceManager {
    static TaskName := "LabStation\\BackgroundService"

    static Install() {
        if (!LS_EnsureAdmin()) {
            return false
        }
        exe := Format('"{1}" "{2}" service-loop', A_AhkPath, LAB_STATION_ROOT "\LabStation.ahk")
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
}
