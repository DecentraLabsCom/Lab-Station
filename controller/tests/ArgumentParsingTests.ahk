#Requires AutoHotkey v2.0
#SingleInstance Force

; Argument parsing regression tests for AppControl

global ROOT_DIR := A_ScriptDir "\.."
global DLAB_APP := ROOT_DIR "\AppControl.ahk"
global AHK_EXE := A_AhkPath
global OUTPUT_DIR := A_ScriptDir "\argdump"
global TEST_FAILURES := 0
global FAIL_LOG := []

overview := []
overview.Push({
    name: "SingleSimpleBrowser",
    cli: '"Chrome_WidgetWin_1" "C:\\Program Files\\Google\\Chrome\\Application\\chrome.exe"',
    expect: Map(
        "mode", "single",
        "windowClass", "Chrome_WidgetWin_1",
        "appCommand", '"C:\\Program Files\\Google\\Chrome\\Application\\chrome.exe" --kiosk --incognito'
    )
})
overview.Push({
    name: "SingleBrowserWithUrl",
    cli: '"Chrome_WidgetWin_1" "C:\\Program Files\\Google\\Chrome\\Application\\chrome.exe" http://127.0.0.1:8000',
    expect: Map(
        "mode", "single",
        "windowClass", "Chrome_WidgetWin_1",
        "appCommand", '"C:\\Program Files\\Google\\Chrome\\Application\\chrome.exe" --kiosk --incognito http://127.0.0.1:8000'
    )
})
overview.Push({
    name: "SingleBrowserKeepFlags",
    cli: '"Chrome_WidgetWin_1" "\"C:\\Program Files\\Google\\Chrome\\Application\\chrome.exe\" --kiosk http://lab.local"',
    expect: Map(
        "mode", "single",
        "windowClass", "Chrome_WidgetWin_1",
        "appCommand", '"C:\\Program Files\\Google\\Chrome\\Application\\chrome.exe" --kiosk http://lab.local'
    )
})
overview.Push({
    name: "SingleCustomCloseCoords",
    cli: '"LVWindow" "C:\\LabApps\\Control.exe" @close-coords="330,484" @test',
    expect: Map(
        "mode", "single",
        "windowClass", "LVWindow",
        "appCommand", '"C:\\LabApps\\Control.exe"',
        "customCloseMethod", "coordinates",
        "customCloseCoords", "330,484",
        "testMode", "true"
    )
})
overview.Push({
    name: "SingleCustomCloseCoordsNoTest",
    cli: '"LVWindow" "C:\\LabApps\\Control.exe" @close-coords="100,200"',
    expect: Map(
        "mode", "single",
        "windowClass", "LVWindow",
        "appCommand", '"C:\\LabApps\\Control.exe"',
        "customCloseMethod", "coordinates",
        "customCloseCoords", "100,200",
        "testMode", "false"
    )
})
overview.Push({
    name: "SingleCustomCloseButton",
    cli: '"Notepad" notepad.exe @close-button="Button2" @test',
    expect: Map(
        "mode", "single",
        "windowClass", "Notepad",
        "appCommand", '"notepad.exe"',
        "customCloseMethod", "control",
        "customCloseControl", "Button2",
        "customCloseCoords", "0,0",
        "testMode", "true"
    )
})
overview.Push({
    name: "SingleCmdShellBrowser",
    cli: '"Chrome_WidgetWin_1" "C:\\Program Files\\Google\\Chrome\\Application\\chrome.exe" --app=http://cmdtest.local',
    launcher: "cmd",
    expect: Map(
        "mode", "single",
        "windowClass", "Chrome_WidgetWin_1",
        "appCommand", '"C:\\Program Files\\Google\\Chrome\\Application\\chrome.exe" --kiosk --incognito --app=http://cmdtest.local'
    )
})
overview.Push({
    name: "SingleUncPath",
    cli: '"RemoteApp" "\\\\labserver\\Shared\\Control Suite\\controller.exe"',
    expect: Map(
        "mode", "single",
        "windowClass", "RemoteApp",
        "appCommand", '"\\\\labserver\\Shared\\Control Suite\\controller.exe"'
    )
})
overview.Push({
    name: "SingleBatchCommand",
    cli: '"Launcher" "\"C:\\Lab Scripts\\startup.cmd\" sensor1 --fast"',
    expect: Map(
        "mode", "single",
        "windowClass", "Launcher",
        "appCommand", '"C:\\Lab Scripts\\startup.cmd" sensor1 --fast'
    )
})
overview.Push({
    name: "SingleBrowserWithAtLiteral",
    args: [
        "Chrome_WidgetWin_1",
        "C:\\Program Files\\Google\\Chrome\\Application\\chrome.exe",
        "--profile=@lab",
        "https://lab.local"
    ],
    expect: Map(
        "mode", "single",
        "windowClass", "Chrome_WidgetWin_1",
        "appCommand", '"C:\\Program Files\\Google\\Chrome\\Application\\chrome.exe" --kiosk --incognito --profile=@lab https://lab.local'
    )
})
overview.Push({
    name: "InvalidCustomCloseMix",
    cli: '"LVWindow" "C:\\LabApps\\Control.exe" @close-coords="1,2" @close-button="Button1"',
    expectFailure: true,
    expectedExitCode: 1
})
overview.Push({
    name: "InvalidCustomCloseCoordsFormat",
    cli: '"LVWindow" "C:\\LabApps\\Control.exe" @close-coords="330"',
    expectFailure: true,
    expectedExitCode: 1
})
overview.Push({
    name: "SingleNonBrowserNoSpaces",
    cli: '"Notepad" notepad.exe',
    expect: Map(
        "mode", "single",
        "windowClass", "Notepad",
        "appCommand", "notepad.exe"
    )
})
overview.Push({
    name: "DualSimple",
    cli: '@dual "ClassOne" "C:\\Program Files\\App One.exe" "ClassTwo" app2.exe',
    expect: Map(
        "mode", "dual",
        "windowClass", "ClassOne",
        "windowClass2", "ClassTwo",
        "appCommand", '"C:\\Program Files\\App One.exe"',
        "appCommand2", "app2.exe",
        "tab1Title", "Application 1",
        "tab2Title", "Application 2"
    )
})
overview.Push({
    name: "DualWithTabs",
    cli: '@dual "Chrome_WidgetWin_1" "\"C:\\Program Files\\Google\\Chrome\\Application\\chrome.exe\" --app=http://127.0.0.1:8000" "MozillaWindowClass" "\"C:\\Program Files\\Mozilla Firefox\\firefox.exe\" --private-window" @tab1="Web App" @tab2="Private Browser"',
    expect: Map(
        "mode", "dual",
        "windowClass", "Chrome_WidgetWin_1",
        "windowClass2", "MozillaWindowClass",
        "appCommand", '"C:\\Program Files\\Google\\Chrome\\Application\\chrome.exe" --app=http://127.0.0.1:8000',
        "appCommand2", '"C:\\Program Files\\Mozilla Firefox\\firefox.exe" --private-window',
        "tab1Title", "Web App",
        "tab2Title", "Private Browser"
    )
})
overview.Push({
    name: "DualQuotedTabTitles",
    cli: '@dual "ClassOne" app1.exe "ClassTwo" app2.exe @tab1="Main \"Camera\"" @tab2="Viewer Suite"',
    expect: Map(
        "mode", "dual",
        "windowClass", "ClassOne",
        "windowClass2", "ClassTwo",
        "appCommand", "app1.exe",
        "appCommand2", "app2.exe",
        "tab1Title", 'Main "Camera"',
        "tab2Title", "Viewer Suite"
    )
})
overview.Push({
    name: "DualGuacExtraArgs",
    args: [
        "@dual",
        "CamClass",
        "C:\\Program Files\\Camera\\cam.exe",
        "ViewerClass",
        "C:\\Program Files\\Viewer\\viewer.exe",
        "--url=http://viewer.local",
        "--mode=view",
        '@tab1="Camera"',
        '@tab2="Viewer"'
    ],
    expect: Map(
        "mode", "dual",
        "windowClass", "CamClass",
        "windowClass2", "ViewerClass",
        "appCommand", '"C:\\Program Files\\Camera\\cam.exe"',
        "appCommand2", '"C:\\Program Files\\Viewer\\viewer.exe" --url=http://viewer.local --mode=view',
        "tab1Title", "Camera",
        "tab2Title", "Viewer"
    )
})

Main()
return

Main() {
    global OUTPUT_DIR, overview, TEST_FAILURES, FAIL_LOG
    if !DirExist(OUTPUT_DIR) {
        DirCreate(OUTPUT_DIR)
    }

    failLogFile := OUTPUT_DIR "\failures.log"
    if FileExist(failLogFile) {
        FileDelete(failLogFile)
    }

    for scenario in overview {
        try {
            RunCase(scenario)
        } catch as err {
            FailCase(scenario.name, "Unhandled exception: " . err.Message)
        }
    }

    if (TEST_FAILURES > 0) {
        details := ""
        for entry in FAIL_LOG {
            details .= "- " . entry.name . ": " . entry.message . "`n"
        }
        Msg := Format("Argument parsing tests failed: {1} case(s)`n`n{2}", TEST_FAILURES, details)
        try {
            FileAppend(Msg . "`n", failLogFile, "UTF-8")
        } catch as err {
            FileAppend("Failed to write fail log: " . err.Message . "`n", OUTPUT_DIR "\failures-progress.log", "UTF-8")
        }
        MsgBox Msg, "Argument Parsing Tests", 16
        ExitApp(1)
    }

    ExitApp(0)
}

RunCase(scenario) {
    global OUTPUT_DIR, DLAB_APP, AHK_EXE, TEST_FAILURES
    expectFailure := ObjHasOwnProp(scenario, "expectFailure") ? scenario.expectFailure : false
    expectedExitCode := ObjHasOwnProp(scenario, "expectedExitCode") ? scenario.expectedExitCode : (expectFailure ? 1 : 0)
    launcher := ObjHasOwnProp(scenario, "launcher") ? StrLower(StrTrim(scenario.launcher)) : "direct"
    dumpFile := expectFailure ? "" : Format("{1}\\{2}.txt", OUTPUT_DIR, scenario.name)
    if (dumpFile != "" && FileExist(dumpFile)) {
        FileDelete(dumpFile)
    }

    cli := ""
    if ObjHasOwnProp(scenario, "args") {
        cli := BuildCliFromArgs(scenario.args)
    } else if ObjHasOwnProp(scenario, "cli") {
        cli := StrTrim(scenario.cli)
    }

    if (cli = "") {
        FailCase(scenario.name, "Scenario did not provide cli/args")
        return
    }

    if (dumpFile != "") {
        dumpArg := Format('@dump-args="{1}"', dumpFile)
        fullCli := StrLen(cli) ? cli . " " . dumpArg : dumpArg
    } else {
        fullCli := cli
    }

    ahkCmd := QuoteArg(AHK_EXE)
    scriptArg := QuoteArg(DLAB_APP)
    baseCommand := Format('{1} /ErrorStdOut {2} {3}', ahkCmd, scriptArg, fullCli)
    cmdScript := ""
    if (launcher = "cmd") {
        cmdScript := OUTPUT_DIR "\" . scenario.name . ".cmd"
        if FileExist(cmdScript) {
            FileDelete(cmdScript)
        }
        FileAppend("@echo off`r`n" . baseCommand . "`r`n", cmdScript, "UTF-8-RAW")
        command := Format('cmd.exe /c ""{1}""', cmdScript)
    } else {
        command := baseCommand
    }
    exitCode := RunWait(command, , "Hide")
    if (cmdScript != "" && FileExist(cmdScript)) {
        FileDelete(cmdScript)
    }

    if (exitCode != expectedExitCode) {
        FailCase(scenario.name, Format("Unexpected exit code (expected {1}, actual {2})", expectedExitCode, exitCode))
        return
    }

    if (expectFailure) {
        return
    }

    if !FileExist(dumpFile) {
        FailCase(scenario.name, "Argument dump file was not created")
        return
    }

    parsed := ParseDumpFile(dumpFile)
    ValidateCase(scenario.name, parsed, scenario.expect)
    FileDelete(dumpFile)
}

ValidateCase(name, actual, expected) {
    for key, expectedValue in expected {
        if !actual.Has(key) {
            FailCase(name, "Missing key '" . key . "'")
            continue
        }
        actualValue := actual[key]
        if (actualValue != expectedValue) {
            FailCase(name, Format("Value mismatch for '{1}' (expected: {2} | actual: {3})", key, expectedValue, actualValue))
        }
    }
}

ParseDumpFile(path) {
    result := Map()
    content := FileRead(path, "UTF-8")
    lines := StrSplit(content, "`n")
    for line in lines {
        line := Trim(line, "`r`n")
        if (line = "") {
            continue
        }
        sep := InStr(line, "=")
        if (sep = 0) {
            continue
        }
        key := SubStr(line, 1, sep - 1)
        value := SubStr(line, sep + 1)
        result[key] := value
    }
    return result
}

BuildCliFromArgs(args) {
    cli := ""
    quote := Chr(34)
    for arg in args {
        part := arg
        if (arg = "" || RegExMatch(arg, "[\s" . quote . "]")) {
            part := QuoteArg(arg)
        }
        cli .= (cli = "" ? "" : " ") . part
    }
    return cli
}

QuoteArg(value) {
    quote := Chr(34)
    escaped := StrReplace(value, quote, Chr(92) . quote)
    return quote . escaped . quote
}

StrTrim(value) {
    return Trim(value, " `t`r`n")
}

FailCase(name, message) {
    global TEST_FAILURES, FAIL_LOG, OUTPUT_DIR
    TEST_FAILURES += 1
    FAIL_LOG.Push({
        name: name,
        message: message
    })
    try {
        FileAppend(Format("{1}: {2}`n", name, message), OUTPUT_DIR "\failures-progress.log", "UTF-8")
    } catch {
        ; Ignore logging failures
    }
    OutputDebug(Format("[ArgumentParsingTests] {1}: {2}", name, message))
}
