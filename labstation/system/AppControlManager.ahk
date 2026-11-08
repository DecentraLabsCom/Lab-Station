; ============================================================================
; Lab Station - AppControl launcher
; ============================================================================
#Requires AutoHotkey v2.0
#Include ..\core\Config.ahk
#Include ..\core\Admin.ahk

LS_LaunchAppControl(args) {
    controllerExe := LAB_STATION_REMOTE_APP_DIR "\AppControl.exe"
    controllerScript := LAB_STATION_REMOTE_APP_DIR "\AppControl.ahk"
    if (FileExist(controllerExe)) {
        Run Format('"{1}" {2}', controllerExe, LS_BuildCliFromArgs(args))
        return true
    }
    if (!FileExist(controllerScript)) {
        LS_ShowMessage("AppControl was not found next to Lab Station.", "Lab Station", "OK Iconx")
        LS_LogError("AppControl.* not available")
        return false
    }
    Run Format('"{1}" "{2}" {3}', A_AhkPath, controllerScript, LS_BuildCliFromArgs(args))
    return true
}

LS_BuildCliFromArgs(args) {
    cli := ""
    for arg in args
        cli .= (cli = "" ? "" : " ") . LS_EscapeCliArgument(arg)
    return cli
}
