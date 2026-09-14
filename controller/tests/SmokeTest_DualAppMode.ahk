#Requires AutoHotkey v2.0
#SingleInstance Force

#Include ..\lib\Config.ahk
#Include ..\lib\Utils.ahk
#Include ..\lib\WindowClosing.ahk
#Include ..\lib\RdpMonitoring.ahk
#Include ..\lib\DualAppMode.ahk

SmokeTestMain()
return

SmokeTestMain() {
    global PRODUCTION_MODE, SILENT_ERRORS, STARTUP_TIMEOUT
    PRODUCTION_MODE := false  ; ensure INFO/DEBUG logs are written
    SILENT_ERRORS := true      ; CI must receive failures through the exit code

    ; AHK v2 Gui() creates windows with the runtime class AutoHotkeyGUI. The
    ; PID qualifier keeps the two test windows distinct without relying on
    ; titles or custom classes which Gui() does not provide.
    class1 := "AutoHotkeyGUI"
    class2 := "AutoHotkeyGUI"
    tab1 := "Smoke App 1"
    tab2 := "Smoke App 2"

    fakeAppPath := A_ScriptDir "\FakeApp.ahk"
    if !FileExist(fakeAppPath) {
        MsgBox "FakeApp.ahk not found at " . fakeAppPath
        ExitApp 1
    }

    ; Keep the fake windows alive longer than the controller's complete
    ; startup budget, including slow CI/desktop sessions.
    fakeLifetime := STARTUP_TIMEOUT * 4
    appCommand1 := BuildFakeAppCommand(fakeAppPath, class1, tab1, "0x2B5797", "App 1 placeholder", fakeLifetime)
    appCommand2 := BuildFakeAppCommand(fakeAppPath, class2, tab2, "0x6441A5", "App 2 placeholder", fakeLifetime)

    ResetSmokeLog()

    Log("=== SMOKE TEST: DualAppMode ===", "INFO")
    Log("App1 Command: " . appCommand1, "DEBUG")
    Log("App2 Command: " . appCommand2, "DEBUG")

    CreateDualAppContainer(class1, appCommand1, class2, appCommand2, tab1, tab2)
    ; CreateDualAppContainer returns only after both windows and the
    ; container have been initialized. Verify that lifecycle boundary rather
    ; than racing it with a fixed-duration timer.
    SmokeTestComplete()
}

BuildFakeAppCommand(path, className, title, color, message, lifetimeSec := 0) {
    quote := Chr(34)
    cmd := Format("{1}{2}{1} /ErrorStdOut {1}{3}{1} --class {1}{4}{1} --title {1}{5}{1} --color {1}{6}{1} --message {1}{7}{1}",
        quote, A_AhkPath, path, className, title, color, message)
    if (lifetimeSec > 0)
        cmd .= " --lifetime " . lifetimeSec
    return cmd
}

ResetSmokeLog() {
    global SMOKE_LOG
    SMOKE_LOG := A_ScriptDir "\AppControl.log"
    try FileDelete(SMOKE_LOG)
}

SmokeTestComplete(*) {
    global appPid1, appPid2
    success := VerifySmokeLog()

    for pid in [appPid1, appPid2] {
        if (pid && ProcessExist(pid)) {
            try ProcessClose(pid)
        }
    }

    ExitApp(success ? 0 : 1)
}

VerifySmokeLog() {
    global SMOKE_LOG
    if !FileExist(SMOKE_LOG) {
        Log("Smoke test failed - log file not created: " . SMOKE_LOG, "ERROR")
        return false
    }

    logText := FileRead(SMOKE_LOG, "UTF-8")
    requiredMarkers := [
        "Initializing dual app container mode",
        "Waiting for Application 1 window",
        "Waiting for Application 2 window",
        "Dual app container initialization complete"
    ]

    missing := []
    for marker in requiredMarkers {
        if !InStr(logText, marker)
            missing.Push(marker)
    }

    if (missing.Length) {
        detail := "Smoke test missing log markers: "
        for item in missing
            detail .= item . "; "
        Log(detail, "ERROR")
        return false
    }

    Log("DualAppMode smoke test passed", "INFO")
    return true
}
