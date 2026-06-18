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
            candidates := [
                LAB_STATION_CONTROLLER_DIR,
                LAB_STATION_ROOT,
                LAB_STATION_PROJECT_ROOT,
                LAB_STATION_PROJECT_ROOT "\dist"
            ]

            resolved := false
            for base in candidates {
                exePath := base "\AppControl.exe"
                ahkPath := base "\AppControl.ahk"

                if (FileExist(exePath)) {
                    appPath := Format('"{1}"', exePath)
                    resolved := true
                    break
                }

                if (FileExist(ahkPath)) {
                    appPath := Format('"{1}" "{2}"', A_AhkPath, ahkPath)
                    resolved := true
                    break
                }
            }

            if (!resolved) {
                LS_LogError("Autostart: AppControl executable/script not found in known locations")
                return false
            }
        }

        command := appPath
        if (onlyUser && onlyUser != "") {
            command := Format('cmd /c if /i "%USERNAME%"=="{1}" ( {2} )', onlyUser, command)
        }
        return LS_RegistryManager.SetRunEntry("LabStationAppControl", command)
    }
}
