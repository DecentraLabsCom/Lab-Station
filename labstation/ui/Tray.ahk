; ============================================================================
; Lab Station - Tray UI
; ============================================================================
#Requires AutoHotkey v2.0
#Include ..\core\Config.ahk
#Include ..\core\Logger.ahk
#Include ..\core\Admin.ahk
#Include ..\diagnostics\Status.ahk
#Include ..\setup\Wizard.ahk

LS_StartTrayUI() {
    TraySetIcon("shell32.dll", 44)
    A_IconTip := "Lab Station"
    A_TrayMenu.Delete()
    A_TrayMenu.Add("Show status", LS_Tray_ShowStatus)
    A_TrayMenu.Add("Export report", LS_Tray_ExportStatus)
    A_TrayMenu.Add("Run wizard", LS_RunSetupWizard)
    A_TrayMenu.Add("Open log", LS_Tray_OpenLog)
    A_TrayMenu.Add() ; separator
    A_TrayMenu.Add("Exit", LS_Tray_Exit)
    SetTimer(LS_Tray_UpdateTooltip, 60000)
    LS_Tray_UpdateTooltip()
    Persistent(True)
}

LS_Tray_ShowStatus(*) {
    summary := LS_Status.SummaryText()
    MsgBox summary, "Lab Station"
}

LS_Tray_ExportStatus(*) {
    if (LS_Status.ExportJson(LAB_STATION_STATUS_FILE)) {
        MsgBox "Report saved to: " . LAB_STATION_STATUS_FILE, "Lab Station"
    } else {
        MsgBox "Unable to export report.", "Lab Station", "OK Iconx"
    }
}

LS_Tray_OpenLog(*) {
    if (!FileExist(LAB_STATION_LOG)) {
        MsgBox "Log file not found at " . LAB_STATION_LOG, "Lab Station"
        return
    }
    Run Format('notepad.exe "{1}"', LAB_STATION_LOG)
}

LS_Tray_UpdateTooltip(*) {
    summary := LS_Status.SummaryText()
    A_IconTip := "Lab Station`n" . summary
}

LS_Tray_Exit(*) {
    ExitApp
}
