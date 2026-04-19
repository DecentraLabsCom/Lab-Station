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
    global PRODUCTION_MODE
    PRODUCTION_MODE := false  ; ensure INFO/DEBUG logs are written

    class1 := "SmokeAppClassOne"
    class2 := "SmokeAppClassTwo"
    tab1 := "Smoke App 1"
    tab2 := "Smoke App 2"

    fakeAppPath := A_ScriptDir "\FakeApp.ahk"
    if !FileExist(fakeAppPath) {
        MsgBox "FakeApp.ahk not found at " . fakeAppPath
        ExitApp 1
    }

    appCommand1 := BuildFakeAppCommand(fakeAppPath, class1, tab1, "0x2B5797", "App 1 placeholder", 20)
    appCommand2 := BuildFakeAppCommand(fakeAppPath, class2, tab2, "0x6441A5", "App 2 placeholder", 20)

    ResetSmokeLog()

    Log("=== SMOKE TEST: DualAppMode ===", "INFO")
    Log("App1 Command: " . appCommand1, "DEBUG")
    Log("App2 Command: " . appCommand2, "DEBUG")

    SetTimer(SmokeTestComplete, -8000)
    CreateDualAppContainer(class1, appCommand1, class2, appCommand2, tab1, tab2)
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
