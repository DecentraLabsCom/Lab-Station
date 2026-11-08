#Requires AutoHotkey v2.0
#SingleInstance Force

#Include ..\lib\WorkspaceMode.ahk

global TEST_ROOT := A_Temp . "\LabStationWorkspaceTests-" . DllCall("GetCurrentProcessId", "UInt") . "-" . A_TickCount
global TEST_FAILURES := 0
global TEST_ASSERTIONS := 0
global PRODUCTION_MODE := false
global SILENT_ERRORS := true
global APP_WORKSPACE_CONFIG_ROOT := TEST_ROOT . "\manifests"
global CONTROLLER_DATA_DIR := TEST_ROOT . "\controller-data"
global CONTROLLER_CLOSE_REQUEST_START_TICK := A_TickCount
global CONTROLLER_CLOSE_REQUEST_POLL_MS := 25
global CONTROLLER_PRESENCE_FILE := CONTROLLER_DATA_DIR . "\controller-presence.txt"
global CONTROLLER_CLOSE_REQUEST_FILE := CONTROLLER_DATA_DIR . "\controller-close.request"
global CONTROLLER_CLOSE_RESULT_FILE := CONTROLLER_DATA_DIR . "\controller-close.result"

DirCreate(TEST_ROOT)
DirCreate(APP_WORKSPACE_CONFIG_ROOT)
DirCreate(CONTROLLER_DATA_DIR)

RunWorkspaceModeTests()
FileAppend("[WorkspaceModeTests] exit status " . TEST_FAILURES . "`n", "*")
if (TEST_FAILURES > 0)
    ExitApp(1)
ExitApp(0)

RunWorkspaceModeTests() {
    global TEST_FAILURES, TEST_ASSERTIONS, TEST_ROOT, WORKSPACE_MODE, WORKSPACE_SHUTTING_DOWN, WORKSPACE_GUI

    try {
        RunManifestValidationTests()
        RunCommandLineTests()
        RunWorkspaceLifecycleSmokeTest()
    } catch as e {
        TestFail("Unhandled exception", e.Message)
    } finally {
        if (WORKSPACE_MODE && !WORKSPACE_SHUTTING_DOWN) {
            try ControllerCloseWorkspace("workspace test cleanup")
            catch as cleanupError
                TestFail("Workspace cleanup", cleanupError.Message)
        }
        if (IsObject(WORKSPACE_GUI)) {
            try WORKSPACE_GUI.Destroy()
        }
        if (InStr(TEST_ROOT, A_Temp . "\LabStationWorkspaceTests-") = 1 && DirExist(TEST_ROOT))
            DirDelete(TEST_ROOT, true)
    }

    summary := Format("[WorkspaceModeTests] {1} assertions, {2} failures", TEST_ASSERTIONS, TEST_FAILURES)
    OutputDebug(summary)
    FileAppend(summary . "`n", "*")
}

RunManifestValidationTests() {
    global APP_WORKSPACE_CONFIG_ROOT, TEST_ROOT

    validApps := [
        TestAppJson("alpha", A_AhkPath, "[]", 30, "Alpha"),
        TestAppJson("beta", A_AhkPath, "[]", 30, "Beta")
    ]
    WriteTestManifest("valid", BuildManifestJson("valid", validApps))
    loaded := WorkspaceLoadManifest("valid")
    TestAssert(loaded.Length = 2, "valid manifest loads both applications")
    TestAssert(loaded[1]["id"] = "alpha", "valid manifest preserves app order")
    TestAssert(loaded[1]["startupTimeoutSeconds"] = 30, "valid manifest applies its startup timeout")
    TestAssert(loaded[1]["workingDirectory"] != "", "missing working directory defaults to executable directory")
    TestAssert(loaded[1]["windowExecutable"] = A_AhkPath,
        "window executable defaults to the launched executable")

    launcherApps := [TestAppJson("launcher", A_WinDir . "\System32\cmd.exe", "[]", 30,
        "Launcher", "", "", A_AhkPath), TestAppJson("other", A_AhkPath)]
    WriteTestManifest("separate-window-executable", BuildManifestJson("separate-window-executable", launcherApps))
    loadedLauncher := WorkspaceLoadManifest("separate-window-executable")
    TestAssert(loadedLauncher[1]["executable"] = A_WinDir . "\System32\cmd.exe",
        "manifest keeps the launcher executable")
    TestAssert(loadedLauncher[1]["windowExecutable"] = A_AhkPath,
        "manifest accepts a separate target window executable")

    maxApps := []
    Loop 5
        maxApps.Push(TestAppJson("max" . A_Index, A_AhkPath))
    WriteTestManifest("five-apps", BuildManifestJson("five-apps", maxApps))
    loadedMax := WorkspaceLoadManifest("five-apps")
    TestAssert(loadedMax.Length = 5, "manifest accepts the configured five-app maximum")

    TestExpectError("../outside", "Workspace id", "workspace id rejects path traversal")
    TestExpectError("missing", "manifest not found", "missing manifest is rejected")

    WriteTestManifest("invalid-json", "{not-json")
    TestExpectError("invalid-json", "invalid JSON", "malformed JSON is rejected")

    WriteTestManifest("wrong-schema", BuildManifestJson("wrong-schema", validApps, 2))
    TestExpectError("wrong-schema", "schemaVersion must be 1", "unsupported schema version is rejected")

    WriteTestManifest("wrong-id", BuildManifestJson("another-id", validApps))
    TestExpectError("wrong-id", "does not match", "manifest id mismatch is rejected")

    WriteTestManifest("one-app", BuildManifestJson("one-app", [TestAppJson("only", A_AhkPath)]))
    TestExpectError("one-app", "between 2 and 5", "workspace with fewer than two apps is rejected")

    tooManyApps := []
    Loop 6
        tooManyApps.Push(TestAppJson("app" . A_Index, A_AhkPath))
    WriteTestManifest("six-apps", BuildManifestJson("six-apps", tooManyApps))
    TestExpectError("six-apps", "between 2 and 5", "workspace above the five-app limit is rejected")

    duplicateApps := [TestAppJson("same", A_AhkPath), TestAppJson("same", A_AhkPath)]
    WriteTestManifest("duplicate-apps", BuildManifestJson("duplicate-apps", duplicateApps))
    TestExpectError("duplicate-apps", "must be unique", "duplicate app ids are rejected")

    relativeApps := [TestAppJson("relative", "fake.exe"), TestAppJson("other", A_AhkPath)]
    WriteTestManifest("relative-exe", BuildManifestJson("relative-exe", relativeApps))
    TestExpectError("relative-exe", "absolute Windows path", "relative executable paths are rejected")

    missingExeApps := [TestAppJson("missing-exe", TEST_ROOT . "\missing.exe"), TestAppJson("other", A_AhkPath)]
    WriteTestManifest("missing-exe", BuildManifestJson("missing-exe", missingExeApps))
    TestExpectError("missing-exe", "existing .exe file", "nonexistent executable is rejected")

    missingWindowExeApps := [TestAppJson("missing-window-exe", A_AhkPath, "[]", 30,
        "Missing window executable", "AutoHotkeyGUI", "", TEST_ROOT . "\missing-window.exe"),
        TestAppJson("other", A_AhkPath)]
    WriteTestManifest("missing-window-exe", BuildManifestJson("missing-window-exe", missingWindowExeApps))
    TestExpectError("missing-window-exe", "windowExecutable", "nonexistent window executable is rejected")

    invalidArgsApps := [TestAppJson("bad-args", A_AhkPath, JsonQuote("not-an-array")), TestAppJson("other", A_AhkPath)]
    WriteTestManifest("invalid-args", BuildManifestJson("invalid-args", invalidArgsApps))
    TestExpectError("invalid-args", "arguments must be an array", "non-array arguments are rejected")

    invalidArgValueApps := [TestAppJson("bad-arg-value", A_AhkPath, "[42]"), TestAppJson("other", A_AhkPath)]
    WriteTestManifest("invalid-arg-value", BuildManifestJson("invalid-arg-value", invalidArgValueApps))
    TestExpectError("invalid-arg-value", "arguments must be strings", "non-string arguments are rejected")

    invalidTimeoutApps := [TestAppJson("bad-timeout", A_AhkPath, "[]", 121), TestAppJson("other", A_AhkPath)]
    WriteTestManifest("invalid-timeout", BuildManifestJson("invalid-timeout", invalidTimeoutApps))
    TestExpectError("invalid-timeout", "between 5 and 120", "out-of-range startup timeout is rejected")
}

RunCommandLineTests() {
    executable := "C:\Program Files\Fake App\fake.exe"
    app := Map("id", "command", "executable", executable, "arguments", ["--title", "Lab control room"])
    expected := Chr(34) . executable . Chr(34) . " "
        . Chr(34) . "--title" . Chr(34) . " "
        . Chr(34) . "Lab control room" . Chr(34)
    TestAssert(WorkspaceBuildCommandLine(app) = expected, "command-line builder quotes executable and spaced arguments")

    currentPid := DllCall("GetCurrentProcessId", "UInt")
    delegatedApp := Map("launchPid", currentPid, "processHandle", 0,
        "preexistingPids", Map(currentPid, true))
    TestAssert(!WorkspaceLaunchProcessIsRunning(delegatedApp),
        "pre-existing single-instance process is not treated as owned by the workspace")
}

RunWorkspaceLifecycleSmokeTest() {
    global APP_WORKSPACE_CONFIG_ROOT
    global WORKSPACE_APPS, WORKSPACE_PANEL, WORKSPACE_TABS

    fakeAppPath := A_ScriptDir . "\FakeApp.ahk"
    fakeLauncherPath := A_ScriptDir . "\FakeLauncher.ahk"
    delayedLauncherPath := A_ScriptDir . "\FakeLauncher.ps1"
    if (!FileExist(fakeAppPath))
        throw Error("FakeApp.ahk was not found: " . fakeAppPath)
    if (!FileExist(fakeLauncherPath))
        throw Error("FakeLauncher.ahk was not found: " . fakeLauncherPath)
    if (!FileExist(delayedLauncherPath))
        throw Error("FakeLauncher.ps1 was not found: " . delayedLauncherPath)
    minimizedMarker := A_Temp . Chr(92) . "Workspace Smoke Alpha Minimized.txt"
    if (FileExist(minimizedMarker))
        FileDelete(minimizedMarker)

    apps := [
        TestAppJson("alpha", A_AhkPath, JsonArray([
            fakeAppPath, "--class", "AutoHotkeyGUI", "--title", "Workspace Smoke Alpha",
            "--color", "0x2B5797", "--extra-title", "Workspace Smoke Alpha Secondary",
            "--extra-delay", "8500", "--helper-title", "Workspace Smoke Alpha Helper",
            "--minimized", "true", "--minimized-marker", minimizedMarker, "--lifetime", "120"
        ]), 15, "Smoke Alpha", "AutoHotkeyGUI", "Workspace Smoke Alpha"),
        TestAppJson("beta", A_AhkPath, JsonArray([
            fakeAppPath, "--class", "AutoHotkeyGUI", "--title", "Workspace Smoke Beta",
            "--color", "0x6441A5", "--lifetime", "120"
        ]), 15, "Smoke Beta", "AutoHotkeyGUI", "Workspace Smoke Beta"),
        TestAppJson("gamma", A_AhkPath, JsonArray([
            fakeLauncherPath, fakeAppPath, "Workspace Smoke Gamma"
        ]), 15, "Smoke Gamma", "AutoHotkeyGUI", "Workspace Smoke Gamma"),
        TestAppJson("delta", A_WinDir . "\System32\WindowsPowerShell\v1.0\powershell.exe", JsonArray([
            "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", delayedLauncherPath,
            A_AhkPath, fakeAppPath, "Workspace Launcher Splash", "Workspace Smoke Delta", "7000"
        ]), 20, "Smoke Delta", "AutoHotkeyGUI", "Workspace Smoke Delta", A_AhkPath)
    ]
    WriteTestManifest("smoke", BuildManifestJson("smoke", apps))

    TestAssert(WorkspaceStart("smoke"), "workspace smoke starts")
    TestAssert(WORKSPACE_APPS.Length = 4, "workspace stores all app records")
    TestAssert(FileExist(minimizedMarker) && FileRead(minimizedMarker, "UTF-8") = "minimized",
        "smoke app confirms it launched minimized")
    TestAssert(!DllCall("IsIconic", "Ptr", WORKSPACE_APPS[1]["hwnd"], "Int"),
        "initial workspace tab restores its minimized main window")
    TestAssert(WORKSPACE_APPS[1]["hwnds"].Length >= 1, "workspace embeds the primary app window")
    hasSmallHelper := false
    for hwnd in WORKSPACE_APPS[1]["hwnds"] {
        if InStr(WinGetTitle("ahk_id " . hwnd), "Workspace Smoke Alpha Helper")
            hasSmallHelper := true
    }
    TestAssert(!hasSmallHelper, "startup ignores small helper windows")
    hostDpiContext := DllCall("GetWindowDpiAwarenessContext", "Ptr", WORKSPACE_GUI.Hwnd, "Ptr")
    panelDpiContext := DllCall("GetWindowDpiAwarenessContext", "Ptr", WORKSPACE_PANEL.Hwnd, "Ptr")
    TestAssert(DllCall("AreDpiAwarenessContextsEqual", "Ptr", hostDpiContext, "Ptr", panelDpiContext, "Int"),
        "workspace host and panel use the same DPI context")
    if (WORKSPACE_APPS.Length != 4)
        return

    for app in WORKSPACE_APPS {
        TestAssert(app["state"] = "running", "fake app reaches running state: " . app["id"])
        TestAssert(WorkspaceProcessIsRunning(app), "fake app window or launcher is supervised: " . app["id"])
        TestAssert(DllCall("GetParent", "Ptr", app["hwnd"], "Ptr") = WORKSPACE_PANEL.Hwnd,
            "fake app is parented to workspace panel: " . app["id"])
    }

    TestAssert(WORKSPACE_APPS[3]["windowPid"] != WORKSPACE_APPS[3]["pid"],
        "workspace adopts a window delegated to another process")
    TestAssert(!WorkspaceLaunchProcessIsRunning(WORKSPACE_APPS[3]),
        "delegated launcher can exit while its workspace window remains active")
    TestAssert(WORKSPACE_APPS[4]["windowPid"] != WORKSPACE_APPS[4]["pid"],
        "delayed launcher target is adopted from its own process")
    TestAssert(WORKSPACE_APPS[4]["windowExecutable"] = A_AhkPath,
        "workspace matches the configured target executable")
    TestAssert(!WorkspaceLaunchProcessIsRunning(WORKSPACE_APPS[4]),
        "delayed target remains usable after its launcher exits")
    deltaTitle := WinGetTitle("ahk_id " . WORKSPACE_APPS[4]["hwnd"])
    TestAssert(InStr(deltaTitle, "Workspace Smoke Delta") && !InStr(deltaTitle, "Splash"),
        "startup ignores the launcher's splash and waits for the main window")
    TestAssert(WORKSPACE_APPS[4]["hwnds"].Length = 1,
        "transient splash is not attached as a workspace application window")

    lateWindowDeadline := A_TickCount + 5000
    while (WORKSPACE_APPS[1]["hwnds"].Length < 2 && A_TickCount < lateWindowDeadline) {
        Sleep(100)
        WorkspaceMonitor()
    }
    TestAssert(WORKSPACE_APPS[1]["hwnds"].Length = 2,
        "workspace adopts a secondary application window created after startup")
    if (WORKSPACE_APPS[1]["hwnds"].Length >= 2) {
        TestAssert(DllCall("GetParent", "Ptr", WORKSPACE_APPS[1]["hwnds"][2], "Ptr") = WORKSPACE_PANEL.Hwnd,
            "late secondary window is parented to workspace panel")
    }

    WorkspaceSelectTab(1)
    Sleep(50)
    TestAssert(DllCall("IsWindowVisible", "Ptr", WORKSPACE_APPS[1]["hwnd"], "Int"), "first tab shows its app")
    if (WORKSPACE_APPS[1]["hwnds"].Length >= 2)
        TestAssert(DllCall("IsWindowVisible", "Ptr", WORKSPACE_APPS[1]["hwnds"][2], "Int"), "first tab shows its secondary window")
    TestAssert(!DllCall("IsWindowVisible", "Ptr", WORKSPACE_APPS[2]["hwnd"], "Int"), "first tab hides the other app")

    DllCall("ShowWindow", "Ptr", WORKSPACE_APPS[1]["hwnd"], "Int", 6) ; SW_MINIMIZE
    TestAssert(DllCall("IsIconic", "Ptr", WORKSPACE_APPS[1]["hwnd"], "Int"),
        "smoke app can enter the minimized state")
    WorkspaceSelectTab(1)
    Sleep(50)
    TestAssert(!DllCall("IsIconic", "Ptr", WORKSPACE_APPS[1]["hwnd"], "Int"),
        "selecting a tab restores its minimized main window")

    WORKSPACE_TABS.Value := 2
    WorkspaceSelectTab(2)
    Sleep(50)
    TestAssert(DllCall("IsWindowVisible", "Ptr", WORKSPACE_APPS[2]["hwnd"], "Int"), "second tab shows its app")
    TestAssert(!DllCall("IsWindowVisible", "Ptr", WORKSPACE_APPS[1]["hwnd"], "Int"), "second tab hides the other app")
    if (WORKSPACE_APPS[1]["hwnds"].Length >= 2)
        TestAssert(!DllCall("IsWindowVisible", "Ptr", WORKSPACE_APPS[1]["hwnds"][2], "Int"), "second tab hides the secondary window")

    TestAssert(ControllerCloseWorkspace("workspace smoke test"), "workspace close handler shuts down the apps")
    for app in WORKSPACE_APPS {
        TestAssert(!ProcessExist(app["pid"]), "workspace close stops fake app: " . app["id"])
        TestAssert(!WorkspaceHasAttachedWindow(app), "workspace close removes all app windows: " . app["id"])
    }

    if (IsObject(WORKSPACE_GUI))
        WORKSPACE_GUI.Destroy()
    if (FileExist(minimizedMarker))
        FileDelete(minimizedMarker)
}

TestAppJson(id, executable, argumentsJson := "[]", timeout := 10, title := "", windowClass := "AutoHotkeyGUI", titleContains := "", windowExecutable := "") {
    if (title = "")
        title := id
    appJson := "{" . JsonQuote("id") . ":" . JsonQuote(id)
        . "," . JsonQuote("title") . ":" . JsonQuote(title)
        . "," . JsonQuote("executable") . ":" . JsonQuote(executable)
        . "," . JsonQuote("arguments") . ":" . argumentsJson
        . "," . JsonQuote("windowClass") . ":" . JsonQuote(windowClass)
    if (windowExecutable != "")
        appJson .= "," . JsonQuote("windowExecutable") . ":" . JsonQuote(windowExecutable)
    if (titleContains != "")
        appJson .= "," . JsonQuote("windowTitleContains") . ":" . JsonQuote(titleContains)
    return appJson . "," . JsonQuote("startupTimeoutSeconds") . ":" . timeout . "}"
}

BuildManifestJson(workspaceId, appJsons, schemaVersion := 1) {
    appsJson := ""
    for appJson in appJsons
        appsJson .= (appsJson = "" ? "" : ",") . appJson
    return "{" . JsonQuote("schemaVersion") . ":" . schemaVersion
        . "," . JsonQuote("workspaceId") . ":" . JsonQuote(workspaceId)
        . "," . JsonQuote("apps") . ":[" . appsJson . "]}"
}

WriteTestManifest(workspaceId, contents) {
    global APP_WORKSPACE_CONFIG_ROOT
    path := APP_WORKSPACE_CONFIG_ROOT . "\" . workspaceId . ".json"
    FileAppend(contents, path, "UTF-8")
    return path
}

JsonArray(values) {
    output := "["
    for value in values
        output .= (output = "[" ? "" : ",") . JsonQuote(value)
    return output . "]"
}

JsonQuote(value) {
    quote := Chr(34)
    value := StrReplace(value, "\", "\\")
    value := StrReplace(value, quote, "\" . quote)
    value := StrReplace(value, "`r", "\r")
    value := StrReplace(value, "`n", "\n")
    return quote . value . quote
}

TestExpectError(workspaceId, expectedText, description) {
    didThrow := false
    try WorkspaceLoadManifest(workspaceId)
    catch as e {
        didThrow := true
        TestAssert(InStr(e.Message, expectedText), description . " (error: " . e.Message . ")")
    }
    if (!didThrow)
        TestAssert(false, description . " (expected validation error)")
}

TestAssert(condition, description) {
    global TEST_ASSERTIONS
    TEST_ASSERTIONS += 1
    if (!condition)
        TestFail(description, "assertion failed")
}

TestFail(description, message) {
    global TEST_FAILURES
    TEST_FAILURES += 1
    failure := Format("[WorkspaceModeTests] FAIL: {1}: {2}", description, message)
    OutputDebug(failure)
    FileAppend(failure . "`n", "*")
}
