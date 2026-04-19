; ============================================================================
; Lab Station - Autostart configuration
; ============================================================================
#Requires AutoHotkey v2.0
#Include ..\core\Config.ahk
#Include ..\core\Logger.ahk
#Include ..\core\Admin.ahk
#Include RegistryManager.ahk

class LS_Autostart {
    static Configure(appPath := "", onlyUser := "") {
        if (!appPath || appPath = "") {
            exePath := LAB_STATION_CONTROLLER_DIR "\AppControl.exe"
            ahkPath := LAB_STATION_CONTROLLER_DIR "\AppControl.ahk"
            appPath := FileExist(exePath) ? Format('"{1}"', exePath) : Format('"{1}" "{2}"', A_AhkPath, ahkPath)
        }
        command := appPath
        if (onlyUser && onlyUser != "") {
            command := Format('cmd /c if /i "%USERNAME%"=="{1}" ( {2} )', onlyUser, command)
        }
        return LS_RegistryManager.SetRunEntry("LabStationAppControl", command)
    }
}
