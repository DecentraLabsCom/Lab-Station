; ============================================================================
; AppControl - Lab Application Controller for RDP Disconnect Handling
; ============================================================================
; Manages one application or a manifest-driven workspace with automatic closure
; on RDP disconnect or a Lab Station release request.
; ============================================================================

#SingleInstance Force
#Requires AutoHotkey v2.0
ProcessSetPriority "High"

; RemoteApp launches AppControl as a controller, so keep its own script window
; out of the published desktop while leaving the process alive to manage the lab app.
DetectHiddenWindows true
try {
    WinHide("ahk_id " A_ScriptHwnd)
} finally {
    DetectHiddenWindows false
}

; ============================================================================
; LOAD MODULES
; ============================================================================
#Include lib\Config.ahk
#Include ..\labstation\core\Json.ahk
#Include lib\WorkspaceConfig.ahk
#Include lib\Utils.ahk
#Include lib\WindowClosing.ahk
#Include lib\CloseRequest.ahk
#Include lib\RdpMonitoring.ahk
#Include lib\SingleAppMode.ahk
#Include lib\WorkspaceMode.ahk

global APP_VERSION := "3.0.0"
Log("AppControl v" . APP_VERSION . " starting")

; ============================================================================
; HELP & USAGE
; ============================================================================

; Single mode examples (CMD/Batch syntax):
; AppControl.exe "MozillaWindowClass" "\"C:\Program Files\Mozilla Firefox\firefox.exe\""
; AppControl.exe "Notepad++" "\"C:\Program Files (x86)\Notepad++\notepad++.exe\""
; AppControl.exe "Chrome_WidgetWin_1" "\"C:\Program Files\Google\Chrome\Application\chrome.exe\" --app=http://www.google.com"
; (Note: Browser auto-kiosk will add --kiosk --incognito automatically)
; AppControl.exe "Notepad++" "\"C:\Program Files (x86)\Notepad++\notepad++.exe\" test.txt" @test
;
; Workspace mode example: AppControl.exe @workspace=lab-control-room

isWorkspaceInvocation := A_Args.Length = 1 && SubStr(StrLower(A_Args[1]), 1, 11) = "@workspace="
if (A_Args.Length < 2 && !isWorkspaceInvocation) {
    infoHeader := Format("AppControl v{1}`n", APP_VERSION)
    MsgBox infoHeader . "Use: AppControl.exe [window_ahk_class] [C:\path\to\app.exe] [@options]"
    . "`n`nSingle Application Mode:"
    . "`n- AppControl.exe `"MozillaWindowClass`" `\`"C:\Program Files\Mozilla Firefox\firefox.exe\`""
    . "`n- AppControl.exe `"Chrome_WidgetWin_1`" `\`"C:\Program Files\Google\Chrome\Application\chrome.exe\`" http://127.0.0.1:8000`""
    . "`n- AppControl.exe `"Notepad++`" `\`"notepad++.exe\`" test.txt --myParam`" @test"
    . "`n- AppControl.exe `"MyAppClass`" `"myapp.exe`" @close-button=`"Button2`""
    . "`n- AppControl.exe `"LVDChild`" `"myVI.exe`" @close-coords=`"330,484`" @test"
    . "`n`nWorkspace Mode (2 to 5 applications):"
    . "`n- AppControl.exe @workspace=lab-control-room"
    . "`n- Administrators define each workspace in its protected JSON manifest."
    . "`n`nOptions (use @ prefix to avoid conflicts with app parameters):"
    . "`n  @workspace=<id>          Open the administrator-configured workspace (maximum 5 apps)"
    . "`n  @workspace-test          Show a closable local workspace test window"
    . "`n  @close-button=`"ClassNN`" Custom close button control (e.g., Button2)"
    . "`n  @close-coords=`"X,Y`"     Custom close coordinates in CLIENT space"
    . "`n  @test                    Test custom close method after 5 seconds"
    . "`n`nApplication Commands:"
    . "`n- Simple paths: C:\path\to\app.exe"
    . "`n- With spaces and parameters: `\`"C:\my path\to\app.exe\`" --param1 value1`""
    . "`n- App params can use -- freely (only @ is for AppControl options)"
    . "`n- CMD: Use \`" to escape quotes"
    . "`n- Guacamole: Chrome_WidgetWin_1 `"C:\...\chrome.exe`" --app=http://url @test"
    . "`n`nCoordinate Guidelines (use CLIENT coordinates from WindowSpy):"
    . "`n- Example: @close-coords=`"330,484`" means 330 pixels right, 484 down from client area"
    ExitApp
}

; ============================================================================
; MAIN ENTRY POINT - Argument Parsing & Mode Detection
; ============================================================================

; Helper function to determine if an argument is a full command (with parameters) or just a path
IsFullCommand(arg) {
    ; If it contains spaces and an executable extension, likely a command with parameters
    ; Examples: 
    ; - "C:\path\to\app.exe --param value"
    ; - "\"C:\path\to\app.exe\" --param value"
    ; - "C:\Program Files\app.exe" https://url.com
    if (InStr(arg, " ") && (InStr(arg, ".exe") || InStr(arg, ".bat") || InStr(arg, ".cmd"))) {
        return true
    }
    return false
}

StripOuterQuotes(value) {
    local quote
    quote := Chr(34)
    if (StrLen(value) >= 2 && SubStr(value, 1, 1) = quote && SubStr(value, -1) = quote) {
        return SubStr(value, 2, StrLen(value) - 2)
    }
    return value
}

HasOuterQuotes(value) {
    local quote
    quote := Chr(34)
    return StrLen(value) >= 2 && SubStr(value, 1, 1) = quote && SubStr(value, -1) = quote
}

; Parse AppControl options. Normal single-app parsing below remains unchanged.
workspaceId := ""
workspaceRequested := false
positionalArgs := []

global customCloseControl := ""
global customCloseX := 0
global customCloseY := 0
global TEST_MODE := false
global CUSTOM_CLOSE_METHOD := "none"
global ARGS_DUMP_PATH := ""

Log("==== RECEIVED ARGUMENTS ====")
Log("Total arguments: " . A_Args.Length)
for index, arg in A_Args {
    Log("Arg[" . index . "]: '" . arg . "'")
}
Log("============================")

for index, arg in A_Args {
    if (SubStr(arg, 1, 1) = "@") {
        argLower := StrLower(arg)
        if (argLower = "@dual") {
            Log("The @dual mode has been replaced by manifest-driven @workspace mode", "ERROR")
            if !SILENT_ERRORS
                MsgBox "The @dual mode has been removed. Configure an admin-managed workspace and use @workspace=<id>.", "AppControl", "OK Iconx"
            ExitApp(2)
        } else if (SubStr(argLower, 1, 11) = "@workspace=") {
            if (workspaceRequested) {
                Log("Only one @workspace option is allowed", "ERROR")
                ExitApp(2)
            }
            workspaceRequested := true
            workspaceId := StripOuterQuotes(SubStr(arg, 12))
            Log("Workspace selected: " . workspaceId, "INFO")
        } else if (argLower = "@workspace-test") {
            if (WORKSPACE_TEST_MODE) {
                Log("Only one @workspace-test option is allowed", "ERROR")
                ExitApp(2)
            }
            WORKSPACE_TEST_MODE := true
            Log("Local workspace test mode enabled", "INFO")
        } else if (argLower = "@test") {
            TEST_MODE := true
            Log("@test flag detected", "DEBUG")
        } else if (SubStr(argLower, 1, 14) = "@close-button=") {
            customCloseControl := SubStr(arg, 15)
            quote := Chr(34)
            if (SubStr(customCloseControl, 1, 1) = quote && SubStr(customCloseControl, -1) = quote)
                customCloseControl := SubStr(customCloseControl, 2, StrLen(customCloseControl) - 2)
            CUSTOM_CLOSE_METHOD := "control"
            Log("Custom close button: " . customCloseControl)
        } else if (SubStr(argLower, 1, 14) = "@close-coords=") {
            coordsStr := SubStr(arg, 15)
            quote := Chr(34)
            if (SubStr(coordsStr, 1, 1) = quote && SubStr(coordsStr, -1) = quote)
                coordsStr := SubStr(coordsStr, 2, StrLen(coordsStr) - 2)
            coords := StrSplit(coordsStr, ",")
            if (coords.Length = 2) {
                customCloseX := Integer(coords[1])
                customCloseY := Integer(coords[2])
                CUSTOM_CLOSE_METHOD := "coordinates"
                Log("Custom close coordinates: " . customCloseX . "," . customCloseY)
            } else {
                if !SILENT_ERRORS
                    MsgBox("Error: @close-coords must be in format X,Y (e.g., @close-coords=`"330,484`")", "Invalid Coordinates", 16)
                ExitApp(1)
            }
        } else if (SubStr(argLower, 1, 11) = "@dump-args=") {
            ARGS_DUMP_PATH := StripOuterQuotes(SubStr(arg, 12))
            if (ARGS_DUMP_PATH = "") {
                Log("@dump-args requires a file path", "ERROR")
                ExitApp(1)
            }
            Log("Argument dump requested", "DEBUG")
        } else {
            Log("WARNING: Unknown option: " . arg . " - ignoring", "WARNING")
        }
    } else {
        positionalArgs.Push(arg)
    }
}

if (customCloseControl != "" && (customCloseX > 0 || customCloseY > 0)) {
    if !SILENT_ERRORS
        MsgBox("Error: Cannot use both @close-button and @close-coords at the same time", "Invalid Parameters", 16)
    ExitApp(1)
}

if (WORKSPACE_TEST_MODE && !workspaceRequested) {
    Log("@workspace-test requires @workspace=<id>", "ERROR")
    if !SILENT_ERRORS
        MsgBox "@workspace-test can only be used with @workspace=<id>.", "AppControl", "OK Iconx"
    ExitApp(2)
}

ControllerRegisterPresence()

if (workspaceRequested) {
    if (positionalArgs.Length != 0 || CUSTOM_CLOSE_METHOD != "none" || TEST_MODE) {
        Log("Workspace mode accepts @workspace, optional @workspace-test, and optional @dump-args", "ERROR")
        ExitApp(2)
    }
    if (ARGS_DUMP_PATH != "") {
        DumpParsedArgs("workspace", Map("workspaceId", workspaceId, "testMode", WORKSPACE_TEST_MODE ? "true" : "false"))
        ExitApp(0)
    }
    try WorkspaceStart(workspaceId, WORKSPACE_TEST_MODE)
    catch as e {
        Log("Unable to start workspace '" . workspaceId . "': " . e.Message, "ERROR")
        if !SILENT_ERRORS
            MsgBox "Unable to start workspace '" . workspaceId . "'. Check the AppControl log for details.", "AppControl", "OK Iconx"
        ExitApp(1)
    }
    return
} else {
    ; Single app mode
    if (positionalArgs.Length < 2) {
        MsgBox "Error: Single mode requires at least 2 arguments: class command"
        ExitApp
    }
    
    windowClass := positionalArgs[1]
    appInput := positionalArgs[2]
    appWasQuoted := HasOuterQuotes(appInput)
    appCommand := StripOuterQuotes(appInput)
    quote := Chr(34)
    
    ; Reconstruct command if there are additional arguments (e.g., from Guacamole)
    ; Guacamole splits: Chrome_WidgetWin_1 "C:\Program Files\app.exe" https://url.com
    ; Into: Arg[1]=Chrome_WidgetWin_1, Arg[2]=C:\Program Files\app.exe, Arg[3]=https://url.com
    if (positionalArgs.Length > 2) {
        Log("Additional arguments detected - reconstructing command from " . positionalArgs.Length . " parts")
        
        ; Quote the executable path if it contains spaces
        if (InStr(appCommand, " ")) {
            appCommand := quote . appCommand . quote
            Log("Quoted executable path: " . appCommand)
        }
        
        ; Append all remaining arguments
        Loop positionalArgs.Length - 2 {
            argIndex := 2 + A_Index
            appCommand .= " " . positionalArgs[argIndex]
            Log("Added argument [" . argIndex . "]: " . positionalArgs[argIndex])
        }
        
        Log("Reconstructed full command: " . appCommand)
    }

    ; For simple two-argument invocations, Windows strips the grouping quotes.
    ; Re-wrap any spaced path so later enhancements (kiosk flags) don't break it.
    if (InStr(appCommand, " ") && SubStr(appCommand, 1, 1) != quote) {
        appCommand := quote . appCommand . quote
        Log("Auto-quoted executable path (single mode): " . appCommand)
    } else if (!InStr(appCommand, " ") && appWasQuoted && SubStr(appCommand, 1, 1) != quote) {
        appCommand := quote . appCommand . quote
        Log("Preserved executable quotes (single mode)")
    }

    ; Some options (@close-*, @test) are parsed separately, so the executable may lose quotes
    ; even when the original CLI used them. If any custom close/test option is active and the
    ; command is a bare executable path, re-wrap it to keep dumps predictable.
    if (!IsFullCommand(appCommand) && SubStr(appCommand, 1, 1) != quote && (CUSTOM_CLOSE_METHOD != "none" || TEST_MODE)) {
        appCommand := quote . appCommand . quote
        Log("Wrapped executable path due to custom close/test options", "DEBUG")
    }
    
    ; Auto-enhance browser command with kiosk/incognito flags
    appCommand := EnhanceBrowserCommand(appCommand)
    
    ; Extract executable path for validation
    appPath := IsFullCommand(appCommand) ? ExtractExecutablePath(appCommand) : appCommand
    
    Log("SINGLE APP MODE - Class: " . windowClass . ", Command: " . appCommand)
    if (CUSTOM_CLOSE_METHOD = "control") {
        Log("Custom close method: Button control '" . customCloseControl . "'")
    } else if (CUSTOM_CLOSE_METHOD = "coordinates") {
        Log("Custom close method: Coordinates (" . customCloseX . "," . customCloseY . ")")
    } else {
        Log("Custom close method: Standard cascade")
    }

    if (ARGS_DUMP_PATH != "") {
        dump := Map()
        dump["windowClass"] := windowClass
        dump["appCommand"] := appCommand
        dump["customCloseMethod"] := CUSTOM_CLOSE_METHOD
        dump["customCloseControl"] := customCloseControl
        dump["customCloseCoords"] := customCloseX . "," . customCloseY
        dump["testMode"] := TEST_MODE ? "true" : "false"
        DumpParsedArgs("single", dump)
        ExitApp
    }
    
    ; Launch single app mode
    CreateSingleApp(windowClass, appCommand)
    return  ; Single mode handles everything from here
}

; ============================================================================
; HOTKEY DIRECTIVES (Must be at file level, not inside functions)
; ============================================================================

; Block Alt+F4 on the lab window (single app mode)
#HotIf WinActive(target)
!F4::return
#HotIf

; Block Alt+F4 on application windows hosted by the workspace.
#HotIf WorkspaceHasActiveWindow() && !WorkspaceTestMode()
!F4::return
#HotIf

DumpParsedArgs(mode, data) {
    global ARGS_DUMP_PATH
    try {
        output := "mode=" . mode . "`n"
        for key, value in data {
            output .= key . "=" . value . "`n"
        }
        if (FileExist(ARGS_DUMP_PATH)) {
            FileDelete(ARGS_DUMP_PATH)
        }
        FileAppend(output, ARGS_DUMP_PATH, "UTF-8")
        Log("Argument dump saved to " . ARGS_DUMP_PATH, "DEBUG")
    } catch as e {
        Log("Failed to write argument dump: " . e.Message, "ERROR")
        if !SILENT_ERRORS
            MsgBox "Cannot write argument dump to: " . ARGS_DUMP_PATH
    }
}
