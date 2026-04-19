; ============================================================================
; AppControl - Lab Application Controller for RDP Disconnect Handling
; ============================================================================
; Manages single or dual applications with automatic closure on RDP disconnect
; Supports custom close methods and embedded app containers
; ============================================================================

#SingleInstance Force
#Requires AutoHotkey v2.0
ProcessSetPriority "High"

; ============================================================================
; LOAD MODULES
; ============================================================================
#Include lib\Config.ahk
#Include lib\Utils.ahk
#Include lib\WindowClosing.ahk
#Include lib\RdpMonitoring.ahk
#Include lib\SingleAppMode.ahk
#Include lib\DualAppMode.ahk

global APP_VERSION := "2.4.0"
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
; Dual mode example (CMD/Batch syntax):
; AppControl.exe @dual "MozillaWindowClass" "\"C:\Program Files\Mozilla Firefox\firefox.exe\"" "Notepad++" "\"C:\Program Files (x86)\Notepad++\notepad++.exe\"" @tab1="Firefox" @tab2="Notepad++"
; (Note: Browser auto-kiosk is disabled in dual mode)

if (A_Args.Length < 2) {
    infoHeader := Format("AppControl v{1}`n", APP_VERSION)
    MsgBox infoHeader . "Use: AppControl.exe [window_ahk_class] [C:\path\to\app.exe] [@options]"
    . "`n`nSingle Application Mode:"
    . "`n- AppControl.exe `"MozillaWindowClass`" `\`"C:\Program Files\Mozilla Firefox\firefox.exe\`""
    . "`n- AppControl.exe `"Chrome_WidgetWin_1`" `\`"C:\Program Files\Google\Chrome\Application\chrome.exe\`" http://127.0.0.1:8000`""
    . "`n- AppControl.exe `"Notepad++`" `\`"notepad++.exe\`" test.txt --myParam`" @test"
    . "`n- AppControl.exe `"MyAppClass`" `"myapp.exe`" @close-button=`"Button2`""
    . "`n- AppControl.exe `"LVDChild`" `"myVI.exe`" @close-coords=`"330,484`" @test"
    . "`n`nDual Application Mode (Tabbed Container):"
    . "`n- AppControl.exe @dual `"Class1`" `"App1.exe`" `"Class2`" `"App2.exe`""
    . "`n- AppControl.exe @dual `"Class1`" `\`"App1.exe\`" --param1 value1`" `"Class2`" `\`"App2.exe\`" --param2 value2`" @tab1=`"Camera`" @tab2=`"Viewer`""
    . "`n- Both apps shown in tabs within a single container window"
    . "`n`nOptions (use @ prefix to avoid conflicts with app parameters):"
    . "`n  @dual                    Enable dual app mode (tabbed container)"
    . "`n  @tab1=`"Title`"           Custom title for first tab (dual mode only)"
    . "`n  @tab2=`"Title`"           Custom title for second tab (dual mode only)"
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
    quote := Chr(34)
    if (StrLen(value) >= 2 && SubStr(value, 1, 1) = quote && SubStr(value, -1) = quote) {
        return SubStr(value, 2, StrLen(value) - 2)
    }
    return value
}

HasOuterQuotes(value) {
    quote := Chr(34)
    return StrLen(value) >= 2 && SubStr(value, 1, 1) = quote && SubStr(value, -1) = quote
}

; Parse optional parameters
DUAL_APP_MODE := false
tab1Title := "Application 1"  ; Default title
tab2Title := "Application 2"  ; Default title
positionalArgs := []  ; Non-option arguments

; Global variables for custom close (accessed by Utils.ahk and WindowClosing.ahk)
global customCloseControl := ""
global customCloseX := 0
global customCloseY := 0
global TEST_MODE := false
global CUSTOM_CLOSE_METHOD := "none"
global ARGS_DUMP_PATH := ""

; Log all received arguments for debugging
Log("==== RECEIVED ARGUMENTS ====")
Log("Total arguments: " . A_Args.Length)
for index, arg in A_Args {
    Log("Arg[" . index . "]: '" . arg . "'")
}
Log("============================")

; First pass: extract options (prefixed with @) and collect positional arguments
for index, arg in A_Args {
    if (SubStr(arg, 1, 1) = "@") {
        ; This is a AppControl option (prefixed with @)
        argLower := StrLower(arg)
        
        if (argLower = "@dual") {
            DUAL_APP_MODE := true
            Log("@dual flag detected - Dual app mode enabled")
        } else if (argLower = "@test") {
            TEST_MODE := true
            Log("@test flag detected - Test mode enabled")
        } else if (SubStr(argLower, 1, 6) = "@tab1=") {
            tab1Title := SubStr(arg, 7)
            quote := Chr(34)
            if (SubStr(tab1Title, 1, 1) = quote && SubStr(tab1Title, -1) = quote) {
                tab1Title := SubStr(tab1Title, 2, StrLen(tab1Title) - 2)
            }
            Log("Custom tab 1 title: " . tab1Title)
        } else if (SubStr(argLower, 1, 6) = "@tab2=") {
            tab2Title := SubStr(arg, 7)
            quote := Chr(34)
            if (SubStr(tab2Title, 1, 1) = quote && SubStr(tab2Title, -1) = quote) {
                tab2Title := SubStr(tab2Title, 2, StrLen(tab2Title) - 2)
            }
            Log("Custom tab 2 title: " . tab2Title)
        } else if (SubStr(argLower, 1, 14) = "@close-button=") {
            customCloseControl := SubStr(arg, 15)
            quote := Chr(34)
            if (SubStr(customCloseControl, 1, 1) = quote && SubStr(customCloseControl, -1) = quote) {
                customCloseControl := SubStr(customCloseControl, 2, StrLen(customCloseControl) - 2)
            }
            CUSTOM_CLOSE_METHOD := "control"
            Log("Custom close button: " . customCloseControl)
        } else if (SubStr(argLower, 1, 14) = "@close-coords=") {
            coordsStr := SubStr(arg, 15)
            quote := Chr(34)
            if (SubStr(coordsStr, 1, 1) = quote && SubStr(coordsStr, -1) = quote) {
                coordsStr := SubStr(coordsStr, 2, StrLen(coordsStr) - 2)
            }
            ; Parse X,Y coordinates
            coords := StrSplit(coordsStr, ",")
            if (coords.Length = 2) {
                customCloseX := Integer(coords[1])
                customCloseY := Integer(coords[2])
                CUSTOM_CLOSE_METHOD := "coordinates"
                Log("Custom close coordinates: " . customCloseX . "," . customCloseY)
            } else {
                if !SILENT_ERRORS {
                    MsgBox("Error: @close-coords must be in format X,Y (e.g., @close-coords=`"330,484`")", "Invalid Coordinates", 16)
                }
                ExitApp(1)
            }
        } else if (SubStr(argLower, 1, 11) = "@dump-args=") {
            ARGS_DUMP_PATH := StripOuterQuotes(SubStr(arg, 12))
            if (ARGS_DUMP_PATH = "") {
                MsgBox("Error: @dump-args requires a valid file path", "Invalid @dump-args", 16)
                ExitApp(1)
            }
            Log("Argument dump will be written to: " . ARGS_DUMP_PATH)
        } else {
            Log("WARNING: Unknown option: " . arg . " - ignoring")
        }
    } else {
        ; This is a positional argument (window class, app command, or app parameters)
        positionalArgs.Push(arg)
    }
}

; Validate custom close parameters
if (customCloseControl != "" && (customCloseX > 0 || customCloseY > 0)) {
    if !SILENT_ERRORS {
        MsgBox("Error: Cannot use both @close-button and @close-coords at the same time", "Invalid Parameters", 16)
    }
    ExitApp(1)
}

; Parse arguments based on mode
if (DUAL_APP_MODE) {
    ; Dual app mode: class1 command1 class2 command2
    if (positionalArgs.Length < 4) {
        MsgBox "Error: Dual mode requires 4 arguments: class1 command1 class2 command2"
        ExitApp
    }
    
    windowClass := positionalArgs[1]
    appInput := positionalArgs[2]
    appWasQuoted := HasOuterQuotes(appInput)
    appCommand := StripOuterQuotes(appInput)
    windowClass2 := positionalArgs[3]
    appInput2 := positionalArgs[4]
    appWasQuoted2 := HasOuterQuotes(appInput2)
    appCommand2 := StripOuterQuotes(appInput2)
    quote := Chr(34)
    
    ; Reconstruct commands if there are additional arguments beyond the basic 4
    ; This handles cases where Guacamole might split application parameters
    if (positionalArgs.Length > 4) {
        Log("Additional arguments in dual mode - may need reconstruction")

        ; Wrap executables before appending any extra parameters so spaces stay intact
        if (SubStr(appCommand, 1, 1) != quote) {
            appCommand := quote . appCommand . quote
            Log("Wrapped app1 executable path for reconstruction")
        }
        if (SubStr(appCommand2, 1, 1) != quote) {
            appCommand2 := quote . appCommand2 . quote
            Log("Wrapped app2 executable path for reconstruction")
        }
        
        ; Collect extra arguments - they could belong to either app
        ; Strategy: Assume extra args belong to app2 if we can't determine otherwise
        Loop positionalArgs.Length - 4 {
            argIndex := 4 + A_Index
            appCommand2 .= " " . positionalArgs[argIndex]
            Log("Added argument to App2 [" . argIndex . "]: " . positionalArgs[argIndex])
        }
        
        Log("Reconstructed App2 command: " . appCommand2)
    }

    ; Ensure simple paths with spaces stay quoted when no extra parameters were provided
    if (InStr(appCommand, " ") && SubStr(appCommand, 1, 1) != quote) {
        appCommand := quote . appCommand . quote
        Log("Auto-quoted App1 executable path (dual mode): " . appCommand)
    } else if (!InStr(appCommand, " ") && appWasQuoted && SubStr(appCommand, 1, 1) != quote) {
        appCommand := quote . appCommand . quote
        Log("Preserved App1 quotes (dual mode)")
    }
    if (InStr(appCommand2, " ") && SubStr(appCommand2, 1, 1) != quote) {
        appCommand2 := quote . appCommand2 . quote
        Log("Auto-quoted App2 executable path (dual mode): " . appCommand2)
    } else if (!InStr(appCommand2, " ") && appWasQuoted2 && SubStr(appCommand2, 1, 1) != quote) {
        appCommand2 := quote . appCommand2 . quote
        Log("Preserved App2 quotes (dual mode)")
    }
    
    ; NOTE: Browser kiosk mode is NOT applied in dual mode
    ; Kiosk mode would prevent apps from being embedded in the tab container
    
    ; Extract executable paths for validation and logging
    appPath := IsFullCommand(appCommand) ? ExtractExecutablePath(appCommand) : appCommand
    appPath2 := IsFullCommand(appCommand2) ? ExtractExecutablePath(appCommand2) : appCommand2
    
    Log("App 1: Class=" . windowClass . ", Command=" . appCommand . ", Tab Title=" . tab1Title)
    Log("App 2: Class=" . windowClass2 . ", Command=" . appCommand2 . ", Tab Title=" . tab2Title)
    Log("DUAL MODE: Browser kiosk auto-enhancement is disabled (apps must be embeddable)", "INFO")

    if (ARGS_DUMP_PATH != "") {
        dump := Map()
        dump["windowClass"] := windowClass
        dump["windowClass2"] := windowClass2
        dump["appCommand"] := appCommand
        dump["appCommand2"] := appCommand2
        dump["tab1Title"] := tab1Title
        dump["tab2Title"] := tab2Title
        DumpParsedArgs("dual", dump)
        ExitApp
    }
    
    ; Launch dual app container with custom tab titles
    CreateDualAppContainer(windowClass, appCommand, windowClass2, appCommand2, tab1Title, tab2Title)
    return  ; Container handles everything from here
    
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

; Block Alt+F4 on both embedded applications (dual app mode)
; Check if app1Hwnd is set (non-zero) to ensure we're in dual mode
#HotIf (app1Hwnd != 0) && (WinActive("ahk_id " . app1Hwnd) || WinActive("ahk_id " . app2Hwnd))
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
