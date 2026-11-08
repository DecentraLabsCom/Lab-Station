; ============================================================================
; WorkspaceMode.ahk - Manifest-driven RemoteApp workspace (2-5 applications)
; ============================================================================
#Include Config.ahk
#Include ..\..\labstation\core\Json.ahk
#Include WorkspaceConfig.ahk
#Include Utils.ahk
#Include WindowClosing.ahk
#Include CloseRequest.ahk
#Include RdpMonitoring.ahk

WorkspaceStart(workspaceId, testMode := false) {
    global WORKSPACE_MODE, WORKSPACE_ID, WORKSPACE_GUI, WORKSPACE_PANEL
    global WORKSPACE_TABS, WORKSPACE_STATUS_TEXT, WORKSPACE_APPS
    global WORKSPACE_TAB_HEIGHT, WORKSPACE_SHUTTING_DOWN, WORKSPACE_CLOSE_HANDLER, WORKSPACE_TEST_MODE

    apps := WorkspaceLoadManifest(workspaceId)
    WORKSPACE_MODE := true
    WORKSPACE_ID := workspaceId
    WORKSPACE_TEST_MODE := testMode
    WORKSPACE_APPS := apps
    WORKSPACE_SHUTTING_DOWN := false
    WORKSPACE_CLOSE_HANDLER := WorkspaceCloseAll

    try {
        if (testMode)
            WORKSPACE_GUI := Gui("+Resize +MinSize640x480 -DPIScale", "Lab Station Workspace Test")
        else
            WORKSPACE_GUI := Gui("+Resize -Caption +MinSize640x480 -DPIScale", "Lab Station Workspace")
        WORKSPACE_GUI.SetFont("s10", "Segoe UI")
        if (!WorkspaceAddClipChildren(WORKSPACE_GUI.Hwnd))
            throw Error("Could not configure the workspace host window")
        WORKSPACE_GUI.Show("Maximize")

        WORKSPACE_TABS := WORKSPACE_GUI.AddTab3("x0 y0 w800 h" . WORKSPACE_TAB_HEIGHT, WorkspaceTabTitles(apps))
        WORKSPACE_PANEL := Gui("+Parent" . WORKSPACE_GUI.Hwnd . " -Caption -Border -DPIScale", "WorkspaceContent")
        if (!WorkspaceAddClipChildren(WORKSPACE_PANEL.Hwnd))
            throw Error("Could not configure the workspace application panel")
        WORKSPACE_PANEL.Show("NoActivate")
        WORKSPACE_PANEL.BackColor := "202020"
        WORKSPACE_STATUS_TEXT := WORKSPACE_PANEL.AddText("x24 y24 w640 h60 cFFFFFF", "")

        WORKSPACE_GUI.OnEvent("Size", (*) => WorkspaceResize())
        WORKSPACE_GUI.OnEvent("Close", (*) => WorkspaceOnGuiClose())
        WORKSPACE_TABS.OnEvent("Change", (*) => WorkspaceSelectTab(WORKSPACE_TABS.Value))

        WorkspaceResize()
        ControllerSetupCloseRequestMonitoring()
        SetupRdpMonitoring(WORKSPACE_GUI.Hwnd)
        OnExit(WorkspaceOnExit)

        for app in apps
            WorkspaceLaunchApp(app)

        ; Catch popups that were created while the other applications started.
        for app in apps
            WorkspaceAdoptNewWindows(app, false)

        WorkspaceResize()
        WORKSPACE_TABS.Value := 1
        WorkspaceSelectTab(1)
        SetTimer(WorkspaceMonitor, WORKSPACE_MONITOR_INTERVAL_MS)
        Log("Workspace '" . WORKSPACE_ID . "' started with " . apps.Length . " applications", "INFO")
        return true
    } catch as e {
        Log("Workspace '" . workspaceId . "' startup failed: " . e.Message, "ERROR")
        WorkspaceCloseAll("workspace startup failure")
        if (IsObject(WORKSPACE_GUI)) {
            try WORKSPACE_GUI.Destroy()
        }
        throw e
    }
}

WorkspaceLoadManifest(workspaceId) {
    global APP_WORKSPACE_CONFIG_ROOT, APP_WORKSPACE_MAX_APPS

    if (!RegExMatch(workspaceId, "^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$"))
        throw Error("Workspace id must use 1-64 letters, numbers, hyphens or underscores")

    manifestPath := APP_WORKSPACE_CONFIG_ROOT . "\" . workspaceId . ".json"
    if (!FileExist(manifestPath))
        throw Error("Workspace manifest not found: " . manifestPath)
    if (FileGetSize(manifestPath) > 1048576)
        throw Error("Workspace manifest exceeds the 1 MiB limit")

    try manifest := LS_ParseJson(FileRead(manifestPath, "UTF-8"))
    catch as e
        throw Error("Workspace manifest is invalid JSON: " . e.Message)

    if !(manifest is Map)
        throw Error("Workspace manifest root must be a JSON object")
    if (!manifest.Has("schemaVersion") || manifest["schemaVersion"] != 1)
        throw Error("Workspace manifest schemaVersion must be 1")
    if (!manifest.Has("workspaceId") || manifest["workspaceId"] != workspaceId)
        throw Error("Workspace manifest id does not match the requested workspace")
    if (!manifest.Has("apps") || !(manifest["apps"] is Array))
        throw Error("Workspace manifest apps must be an array")

    if (manifest["apps"].Length < 2 || manifest["apps"].Length > APP_WORKSPACE_MAX_APPS)
        throw Error("A workspace must contain between 2 and " . APP_WORKSPACE_MAX_APPS . " applications")

    apps := []
    seenIds := Map()
    for appIndex, source in manifest["apps"] {
        app := WorkspaceValidateApp(source, appIndex)
        if (seenIds.Has(StrLower(app["id"])))
            throw Error("Workspace application ids must be unique: " . app["id"])
        seenIds[StrLower(app["id"])] := true
        apps.Push(app)
    }
    return apps
}

WorkspaceValidateApp(source, appIndex) {
    if !(source is Map)
        throw Error("Application " . appIndex . " must be a JSON object")

    id := WorkspaceRequiredString(source, "id", appIndex, 64)
    if (!RegExMatch(id, "^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$"))
        throw Error("Application " . appIndex . " id contains unsupported characters")

    title := WorkspaceRequiredString(source, "title", appIndex, 48)
    executable := WorkspaceRequiredString(source, "executable", appIndex, 1024)
    if (!RegExMatch(executable, "i)^(?:[A-Z]:\\|\\\\)"))
        throw Error("Application '" . id . "' executable must be an absolute Windows path")
    SplitPath(executable, , , &extension)
    if (StrLower(extension) != "exe" || !FileExist(executable))
        throw Error("Application '" . id . "' must reference an existing .exe file")

    windowExecutable := source.Has("windowExecutable") ? source["windowExecutable"] : executable
    if (Type(windowExecutable) != "String" || StrLen(windowExecutable) > 1024
        || !RegExMatch(windowExecutable, "i)^(?:[A-Z]:\\|\\\\)"))
        throw Error("Application '" . id . "' windowExecutable must be an absolute Windows path")
    SplitPath(windowExecutable, , , &windowExtension)
    if (StrLower(windowExtension) != "exe" || !FileExist(windowExecutable))
        throw Error("Application '" . id . "' windowExecutable must reference an existing .exe file")

    windowClass := source.Has("windowClass") ? source["windowClass"] : ""
    if (Type(windowClass) != "String" || StrLen(windowClass) > 128)
        throw Error("Application '" . id . "' windowClass must be a string of at most 128 characters")
    windowClass := Trim(windowClass)
    titleContains := source.Has("windowTitleContains") ? source["windowTitleContains"] : ""
    if (Type(titleContains) != "String" || StrLen(titleContains) > 256)
        throw Error("Application '" . id . "' windowTitleContains must be a string of at most 256 characters")

    arguments := source.Has("arguments") ? source["arguments"] : []
    if !(arguments is Array)
        throw Error("Application '" . id . "' arguments must be an array of strings")
    if (arguments.Length > 128)
        throw Error("Application '" . id . "' has more than 128 arguments")
    for argument in arguments {
        if (Type(argument) != "String" || StrLen(argument) > 8192)
            throw Error("Application '" . id . "' arguments must be strings no longer than 8192 characters")
    }

    workingDirectory := source.Has("workingDirectory") ? source["workingDirectory"] : ""
    if (Type(workingDirectory) != "String" || StrLen(workingDirectory) > 1024)
        throw Error("Application '" . id . "' workingDirectory must be a path string")
    if (workingDirectory != "") {
        if (!RegExMatch(workingDirectory, "i)^(?:[A-Z]:\\|\\\\)") || !DirExist(workingDirectory))
            throw Error("Application '" . id . "' workingDirectory must be an existing absolute directory")
    } else {
        SplitPath(executable, , &workingDirectory)
    }

    startupTimeout := source.Has("startupTimeoutSeconds") ? source["startupTimeoutSeconds"] : 30
    if (!IsNumber(startupTimeout) || Floor(startupTimeout) != startupTimeout)
        throw Error("Application '" . id . "' startupTimeoutSeconds must be an integer")
    startupTimeout := Integer(startupTimeout)
    if (startupTimeout < 5 || startupTimeout > 120)
        throw Error("Application '" . id . "' startupTimeoutSeconds must be between 5 and 120")

    return Map(
        "id", id,
        "title", title,
        "executable", executable,
        "windowExecutable", windowExecutable,
        "arguments", arguments,
        "workingDirectory", workingDirectory,
        "windowClass", windowClass,
        "windowTitleContains", titleContains,
        "startupTimeoutSeconds", startupTimeout,
        "pid", 0,
        "launchPid", 0,
        "windowPid", 0,
        "processHandle", 0,
        "hwnd", 0,
        "hwnds", [],
        "trackedWindows", Map(),
        "windowRoles", Map(),
        "preexistingWindows", Map(),
        "preexistingPids", Map(),
        "windowPids", Map(),
        "noWindowSinceTick", 0,
        "state", "pending"
    )
}

WorkspaceRequiredString(source, key, appIndex, maxLength) {
    if (!source.Has(key) || Type(source[key]) != "String")
        throw Error("Application " . appIndex . " requires string field '" . key . "'")
    value := Trim(source[key])
    if (value = "" || StrLen(value) > maxLength)
        throw Error("Application " . appIndex . " field '" . key . "' is empty or too long")
    return value
}

WorkspaceTabTitles(apps) {
    titles := []
    for app in apps
        titles.Push(app["title"])
    return titles
}

WorkspaceLaunchApp(app) {
    commandLine := WorkspaceBuildCommandLine(app)
    Log("Launching workspace application '" . app["id"] . "'", "INFO")
    app["preexistingWindows"] := WorkspaceSnapshotExistingWindows(app)

    try Run(commandLine, app["workingDirectory"], , &pid)
    catch as e
        throw Error("Could not launch application '" . app["id"] . "': " . e.Message)

    app["pid"] := pid
    app["launchPid"] := pid
    app["processHandle"] := DllCall("OpenProcess", "UInt", 0x00100000, "Int", 0, "UInt", pid, "Ptr") ; SYNCHRONIZE
    if (!app["processHandle"])
        Log("The launcher process for '" . app["id"] . "' exited before it could be supervised; waiting for its window", "WARNING")
    Log("Workspace application '" . app["id"] . "' launched as PID " . pid, "DEBUG")

    windows := WorkspaceWaitForWindows(app)
    for hwnd in windows
        WorkspaceAttachWindow(hwnd, app)
    WorkspaceAdoptNewWindows(app, false)
    app["state"] := "running"
}

WorkspaceBuildCommandLine(app) {
    commandLine := WorkspaceQuoteArgument(app["executable"])
    for argument in app["arguments"]
        commandLine .= " " . WorkspaceQuoteArgument(argument)
    if (StrLen(commandLine) > 30000)
        throw Error("Application '" . app["id"] . "' command line exceeds the Windows limit")
    return commandLine
}

WorkspaceQuoteArgument(argument) {
    quote := Chr(34)
    slash := Chr(92)
    output := quote
    backslashCount := 0

    for character in StrSplit(argument) {
        if (character = slash) {
            backslashCount += 1
            continue
        }
        if (character = quote) {
            output .= WorkspaceRepeat(slash, backslashCount * 2 + 1) . quote
            backslashCount := 0
            continue
        }
        output .= WorkspaceRepeat(slash, backslashCount) . character
        backslashCount := 0
    }

    output .= WorkspaceRepeat(slash, backslashCount * 2) . quote
    return output
}

WorkspaceRepeat(character, count) {
    output := ""
    Loop count
        output .= character
    return output
}

WorkspaceWaitForWindows(app) {
    timeoutMs := app["startupTimeoutSeconds"] * 1000
    deadline := A_TickCount + timeoutMs
    launchTick := A_TickCount
    delegationGraceMs := 1500
    while (A_TickCount <= deadline) {
        ; A launcher may expose a visible splash or helper window before its
        ; actual application window. Startup is complete only when a main
        ; window matches the configured target, so auxiliaries cannot satisfy
        ; this wait even though they are tracked after the main window attaches.
        ownCandidates := WorkspaceFindMatchingWindows(app, true, false)
        if (ownCandidates.Length > 0) {
            ; Prefer a primary app window over startup dialogs and popups.
            ; Remaining windows are attached after the primary candidate.
            selected := WorkspaceSelectPrimaryWindow(ownCandidates, app)
            WorkspaceLogTestCandidate(app, selected)
            return [selected]
        }

        if (!WorkspaceLaunchProcessIsRunning(app) || A_TickCount - launchTick >= delegationGraceMs) {
            delegatedCandidates := WorkspaceFindMatchingWindows(app, false, false)
            if (delegatedCandidates.Length > 0) {
                selected := WorkspaceSelectPrimaryWindow(delegatedCandidates, app)
                WorkspaceLogTestCandidate(app, selected)
                return [selected]
            }
        }
        Sleep(100)
    }
    matchDescription := app["windowClass"] != "" ? "class '" . app["windowClass"] . "'"
        : (app["windowTitleContains"] != "" ? "a title containing '" . app["windowTitleContains"] . "'"
            : "a main window from " . app["windowExecutable"])
    throw Error("Application '" . app["id"] . "' did not create a new visible window matching "
        . matchDescription . " within " . app["startupTimeoutSeconds"] . " seconds")
}

WorkspaceLogTestCandidate(app, hwnd) {
    if (WorkspaceTestMode()) {
        className := WinGetClass("ahk_id " . hwnd)
        dims := WorkspaceGetCandidateWindowDimensions(hwnd)
        sizeText := dims ? dims.w . "x" . dims.h : "unavailable"
        Log("Workspace test selected '" . app["id"] . "' HWND " . hwnd
            . " from PID " . WorkspaceGetWindowProcessId(hwnd) . ", class=" . className
            . ", size=" . sizeText, "WARNING")
    }
}

WorkspaceSelectPrimaryWindow(hwnds, app) {
    selected := hwnds[1]
    selectedRole := WorkspaceWindowRole(selected, app)
    selectedDims := WorkspaceGetCandidateWindowDimensions(selected)
    selectedArea := selectedDims ? selectedDims.w * selectedDims.h : 0
    for hwnd in hwnds {
        role := WorkspaceWindowRole(hwnd, app)
        dims := WorkspaceGetCandidateWindowDimensions(hwnd)
        area := dims ? dims.w * dims.h : 0
        if ((selectedRole = "auxiliary" && role = "main") || (selectedRole = role && area > selectedArea)) {
            selected := hwnd
            selectedRole := role
            selectedArea := area
        }
    }
    return selected
}

WorkspaceGetCandidateWindowDimensions(hwnd) {
    if (!DllCall("IsIconic", "Ptr", hwnd, "Int"))
        return GetWindowDimensions(hwnd)

    ; A minimized window's current rectangle is its icon-sized minimized area.
    ; Use the restored rectangle from WINDOWPLACEMENT so real application
    ; windows still pass the usable-size filter while splash/helper windows do not.
    placement := Buffer(44, 0) ; sizeof(WINDOWPLACEMENT)
    NumPut("UInt", placement.Size, placement, 0)
    if (DllCall("GetWindowPlacement", "Ptr", hwnd, "Ptr", placement, "Int")) {
        left := NumGet(placement, 28, "Int")
        top := NumGet(placement, 32, "Int")
        right := NumGet(placement, 36, "Int")
        bottom := NumGet(placement, 40, "Int")
        if (right > left && bottom > top)
            return {x: left, y: top, w: right - left, h: bottom - top}
    }
    return GetWindowDimensions(hwnd)
}

WorkspaceFindMatchingWindows(app, launchPidOnly := false, includeAuxiliary := true) {
    wins := []
    try wins := launchPidOnly && app["launchPid"]
        ? WinGetList("ahk_pid " . app["launchPid"])
        : WinGetList()
    catch
        return []

    matches := []
    for hwnd in wins {
        if (!WorkspaceWindowMatchesApp(app, hwnd, includeAuxiliary))
            continue
        className := WinGetClass("ahk_id " . hwnd)
        dims := WorkspaceGetCandidateWindowDimensions(hwnd)
        sizeText := dims ? dims.w . "x" . dims.h : "unavailable"
        Log("Workspace main-window candidate '" . app["id"] . "' -> HWND " . hwnd . " (" . sizeText . ")", "DEBUG")
        if (IsUWPApp(hwnd, className))
            throw Error("Application '" . app["id"] . "' uses a UWP window, which is not supported in a workspace")
        matches.Push(hwnd)
    }
    return matches
}

WorkspaceSnapshotExistingWindows(app) {
    existingWindows := Map()
    try windows := WinGetList()
    catch
        return existingWindows

    for hwnd in windows {
        if (WorkspaceWindowUsesExecutable(hwnd, app["windowExecutable"])) {
            existingWindows[hwnd] := true
            pid := WorkspaceGetWindowProcessId(hwnd)
            if (pid)
                app["preexistingPids"][pid] := true
        }
        if (WorkspaceWindowUsesExecutable(hwnd, app["executable"])) {
            pid := WorkspaceGetWindowProcessId(hwnd)
            if (pid)
                app["preexistingPids"][pid] := true
        }
    }
    return existingWindows
}

WorkspaceWindowMatchesApp(app, hwnd, includeAuxiliary := true) {
    if (!hwnd || !DllCall("IsWindowVisible", "Ptr", hwnd, "UInt"))
        return false
    if (DllCall("GetAncestor", "Ptr", hwnd, "UInt", 2, "Ptr") != hwnd) ; GA_ROOT
        return false
    if (app["preexistingWindows"].Has(hwnd) || app["trackedWindows"].Has(hwnd))
        return false

    try className := WinGetClass("ahk_id " . hwnd)
    catch
        return false
    isAuxiliary := WorkspaceWindowIsAuxiliary(hwnd, app)
    if (isAuxiliary && !includeAuxiliary)
        return false
    if (app["windowClass"] != "" && className != app["windowClass"] && !isAuxiliary)
        return false
    if (app["windowTitleContains"] != "") {
        try title := WinGetTitle("ahk_id " . hwnd)
        catch
            return false
        if (!InStr(StrLower(title), StrLower(app["windowTitleContains"])) && !isAuxiliary)
            return false
    }

    ; Reject splash screens and hidden timing/helper windows that may carry
    ; WS_VISIBLE while having no usable application surface.
    dims := WorkspaceGetCandidateWindowDimensions(hwnd)
    if (!dims || dims.w < 100 || dims.h < 100)
        return false
    if (!WorkspaceWindowUsesExecutable(hwnd, app["windowExecutable"]))
        return false

    if (IsUWPApp(hwnd, className))
        throw Error("Application '" . app["id"] . "' uses a UWP window, which is not supported in a workspace")
    return true
}

WorkspaceWindowUsesExecutable(hwnd, executable) {
    pid := WorkspaceGetWindowProcessId(hwnd)
    if (!pid)
        return false
    actualPath := WorkspaceGetProcessImagePath(pid)
    return actualPath != "" && StrLower(RTrim(actualPath, "\")) = StrLower(RTrim(executable, "\"))
}

WorkspaceGetWindowProcessId(hwnd) {
    pid := 0
    DllCall("GetWindowThreadProcessId", "Ptr", hwnd, "UInt*", &pid, "UInt")
    return pid
}

WorkspaceGetProcessImagePath(pid) {
    if (!pid)
        return ""
    processHandle := DllCall("OpenProcess", "UInt", 0x1000, "Int", 0, "UInt", pid, "Ptr") ; PROCESS_QUERY_LIMITED_INFORMATION
    if (!processHandle)
        return ""

    bufferLength := 32768
    imagePathBuffer := Buffer(bufferLength * 2, 0)
    succeeded := DllCall("QueryFullProcessImageNameW", "Ptr", processHandle, "UInt", 0,
        "Ptr", imagePathBuffer, "UInt*", &bufferLength, "Int")
    DllCall("CloseHandle", "Ptr", processHandle, "Int")
    return succeeded ? StrGet(imagePathBuffer, bufferLength, "UTF-16") : ""
}

WorkspaceAttachWindow(hwnd, app, showAfterAttach := false) {
    if (app["trackedWindows"].Has(hwnd) || !WinExist("ahk_id " . hwnd))
        return false
    pid := WorkspaceGetWindowProcessId(hwnd)
    if (!pid)
        throw Error("Could not identify the process that owns application '" . app["id"] . "' window " . hwnd)

    role := WorkspaceWindowRole(hwnd, app)
    originalState := WorkspaceCaptureWindowState(hwnd)
    try {
        ; Hide the external window before changing its native style/parent. This
        ; is required by applications such as PuTTY while their first frame is shown.
        DllCall("ShowWindow", "Ptr", hwnd, "Int", 0)
        if (role = "auxiliary") {
            ; Keep the app's owner relationship intact. It controls modal behavior
            ; and Windows keeps an owned popup above its owner.
            Log("Tracking auxiliary popup '" . app["id"] . "' HWND " . hwnd . " without resizing or reparenting it", "DEBUG")
        } else {
            Log("Embedding application '" . app["id"] . "' window " . hwnd, "DEBUG")
            WorkspaceEmbedWindow(hwnd, WORKSPACE_PANEL.Hwnd, app)
        }
    } catch as attachError {
        try WorkspaceRestoreOriginalWindowState(hwnd, originalState)
        catch as rollbackError
            throw Error("Could not attach window for '" . app["id"] . "': " . attachError.Message
                . ". Rollback also failed: " . rollbackError.Message)
        throw attachError
    }

    app["trackedWindows"][hwnd] := true
    app["hwnds"].Push(hwnd)
    app["windowRoles"][hwnd] := role
    app["windowPids"][pid] := true
    if (role = "main" && !app["hwnd"]) {
        app["hwnd"] := hwnd
        app["windowPid"] := pid
    }
    if (showAfterAttach && role = "main")
        WorkspaceRestoreHostedWindow(hwnd)
    else
        DllCall("ShowWindow", "Ptr", hwnd, "Int", showAfterAttach ? 5 : 0)
    Log("Attached " . role . " window for '" . app["id"] . "' HWND " . hwnd . " from PID " . pid, "INFO")
    return true
}

WorkspaceWindowRole(hwnd, app) {
    return WorkspaceWindowIsAuxiliary(hwnd, app) ? "auxiliary" : "main"
}

WorkspaceWindowIsAuxiliary(hwnd, app) {
    owner := DllCall("GetWindow", "Ptr", hwnd, "UInt", 4, "Ptr") ; GW_OWNER
    if (owner && ((IsObject(WORKSPACE_GUI) && owner = WORKSPACE_GUI.Hwnd) || app["trackedWindows"].Has(owner)
        || (!app["preexistingWindows"].Has(owner) && WorkspaceWindowUsesExecutable(owner, app["windowExecutable"]))))
        return true

    getStyleApi := A_PtrSize = 8 ? "GetWindowLongPtrW" : "GetWindowLongW"
    exStyle := DllCall(getStyleApi, "Ptr", hwnd, "Int", -20, "Ptr") ; GWL_EXSTYLE
    if (exStyle & 0x00000080) ; WS_EX_TOOLWINDOW
        return true
    try className := WinGetClass("ahk_id " . hwnd)
    catch
        return false
    if (className = "#32770")
        return true
    return false
}

WorkspaceCaptureWindowState(hwnd) {
    getStyleApi := A_PtrSize = 8 ? "GetWindowLongPtrW" : "GetWindowLongW"
    rect := Buffer(16, 0)
    if (!DllCall("GetWindowRect", "Ptr", hwnd, "Ptr", rect, "Int"))
        throw Error("Could not read the original position of window " . hwnd)

    return Map(
        "parent", WorkspaceGetWindowParent(hwnd),
        "owner", DllCall("GetWindow", "Ptr", hwnd, "UInt", 4, "Ptr"), ; GW_OWNER
        "style", DllCall(getStyleApi, "Ptr", hwnd, "Int", -16, "Ptr"), ; GWL_STYLE
        "exStyle", DllCall(getStyleApi, "Ptr", hwnd, "Int", -20, "Ptr"), ; GWL_EXSTYLE
        "x", NumGet(rect, 0, "Int"),
        "y", NumGet(rect, 4, "Int"),
        "width", NumGet(rect, 8, "Int") - NumGet(rect, 0, "Int"),
        "height", NumGet(rect, 12, "Int") - NumGet(rect, 4, "Int"),
        "visible", DllCall("IsWindowVisible", "Ptr", hwnd, "Int"),
        "minimized", DllCall("IsIconic", "Ptr", hwnd, "Int"),
        "maximized", DllCall("IsZoomed", "Ptr", hwnd, "Int")
    )
}

WorkspaceRestoreOriginalWindowState(hwnd, state) {
    if (!hwnd || !WinExist("ahk_id " . hwnd))
        return

    DllCall("ShowWindow", "Ptr", hwnd, "Int", 0)
    currentParent := WorkspaceGetWindowParent(hwnd)
    if (currentParent != state["parent"]) {
        DllCall("SetLastError", "UInt", 0)
        DllCall("SetParent", "Ptr", hwnd, "Ptr", state["parent"], "Ptr")
        parentError := DllCall("GetLastError", "UInt")
        if (parentError)
            throw Error("Could not restore the original window parent (Win32 " . parentError . ")")
    }

    WorkspaceSetWindowLongValue(hwnd, -16, state["style"], "style") ; GWL_STYLE
    WorkspaceSetWindowLongValue(hwnd, -20, state["exStyle"], "extended style") ; GWL_EXSTYLE
    currentOwner := DllCall("GetWindow", "Ptr", hwnd, "UInt", 4, "Ptr") ; GW_OWNER
    if (currentOwner != state["owner"])
        WorkspaceSetWindowLongValue(hwnd, -8, state["owner"], "owner") ; GWLP_HWNDPARENT
    if (WorkspaceGetWindowParent(hwnd) != state["parent"])
        throw Error("The original window parent was not restored")
    if (!DllCall("SetWindowPos", "Ptr", hwnd, "Ptr", 0, "Int", state["x"], "Int", state["y"],
        "Int", state["width"], "Int", state["height"], "UInt", 0x0034, "Int")) ; SWP_NOZORDER | SWP_NOACTIVATE | SWP_FRAMECHANGED
        throw Error("Could not restore the original window position and frame")

    if (state["visible"]) {
        showCommand := state["minimized"] ? 6 : (state["maximized"] ? 3 : 5)
        DllCall("ShowWindow", "Ptr", hwnd, "Int", showCommand)
    } else {
        DllCall("ShowWindow", "Ptr", hwnd, "Int", 0)
    }
}

WorkspaceGetWindowParent(hwnd) {
    parent := DllCall("GetAncestor", "Ptr", hwnd, "UInt", 1, "Ptr") ; GA_PARENT, excludes owner
    if (parent = DllCall("GetDesktopWindow", "Ptr"))
        return 0
    return parent
}

WorkspaceSetWindowLongValue(hwnd, index, value, description) {
    setStyleApi := A_PtrSize = 8 ? "SetWindowLongPtrW" : "SetWindowLongW"
    DllCall("SetLastError", "UInt", 0)
    previousValue := DllCall(setStyleApi, "Ptr", hwnd, "Int", index, "Ptr", value, "Ptr")
    styleError := DllCall("GetLastError", "UInt")
    if (!previousValue && styleError != 0)
        throw Error("Could not restore window " . description . " (Win32 " . styleError . ")")
    return previousValue
}

WorkspaceAppIsSelected(app) {
    global WORKSPACE_APPS, WORKSPACE_TABS
    if (!IsObject(WORKSPACE_TABS))
        return false
    for index, candidate in WORKSPACE_APPS {
        if (candidate["id"] = app["id"])
            return WORKSPACE_TABS.Value = index
    }
    return false
}

WorkspaceRestoreHostedWindow(hwnd) {
    ; Normalize the hosted main window's state before fitting it to the tab area.
    ; SW_RESTORE also shows an initially minimized window.
    DllCall("ShowWindow", "Ptr", hwnd, "Int", 9)
}

WorkspaceAdoptNewWindows(app, showSelectedWindows := true) {
    added := false
    for hwnd in WorkspaceFindMatchingWindows(app) {
        if (WorkspaceWindowTrackedByOtherApp(hwnd, app))
            continue
        pid := WorkspaceGetWindowProcessId(hwnd)
        if (!app["windowPids"].Has(pid)) {
            if (WorkspaceLaunchProcessIsRunning(app) || WorkspaceCountMatchingAppsForWindow(hwnd) > 1)
                continue
        }
        if (WorkspaceAttachWindow(hwnd, app, showSelectedWindows && WorkspaceAppIsSelected(app)))
            added := true
    }
    return added
}

WorkspaceWindowTrackedByOtherApp(hwnd, app) {
    global WORKSPACE_APPS
    for otherApp in WORKSPACE_APPS {
        if (otherApp["id"] != app["id"] && otherApp["trackedWindows"].Has(hwnd))
            return true
    }
    return false
}

WorkspaceCountMatchingAppsForWindow(hwnd) {
    global WORKSPACE_APPS
    count := 0
    for app in WORKSPACE_APPS {
        if (WorkspaceWindowMatchesApp(app, hwnd))
            count += 1
    }
    return count
}

WorkspaceEmbedWindow(hwnd, parentHwnd, app) {
    hostContext := DllCall("GetWindowDpiAwarenessContext", "Ptr", parentHwnd, "Ptr")
    appContext := DllCall("GetWindowDpiAwarenessContext", "Ptr", hwnd, "Ptr")
    if (!DllCall("AreDpiAwarenessContextsEqual", "Ptr", hostContext, "Ptr", appContext, "Int")) {
        hostAwareness := DllCall("GetAwarenessFromDpiAwarenessContext", "Ptr", hostContext, "Int")
        appAwareness := DllCall("GetAwarenessFromDpiAwarenessContext", "Ptr", appContext, "Int")
        Log("Embedding application '" . app["id"] . "' across DPI awareness contexts (host="
            . WorkspaceDpiAwarenessName(hostAwareness) . ", app=" . WorkspaceDpiAwarenessName(appAwareness)
            . "). Windows resets the child process DPI awareness for cross-process SetParent", "WARNING")
    }

    WorkspaceApplyEmbeddedWindowStyle(hwnd, app)

    DllCall("SetLastError", "UInt", 0)
    Log("Setting workspace parent for '" . app["id"] . "' window " . hwnd, "DEBUG")
    previousParent := DllCall("SetParent", "Ptr", hwnd, "Ptr", parentHwnd, "Ptr")
    parentError := DllCall("GetLastError", "UInt")
    if (!previousParent && parentError != 0)
        throw Error("Could not embed application '" . app["id"] . "' (Win32 " . parentError . ")")

    if (WorkspaceGetWindowParent(hwnd) != parentHwnd)
        throw Error("Windows did not attach application '" . app["id"] . "' to the workspace panel")

    Log("Workspace parent set for '" . app["id"] . "' window " . hwnd, "DEBUG")
    ; Reapply after reparenting: some applications rebuild their non-client frame
    ; while processing the parent change.
    WorkspaceApplyEmbeddedWindowStyle(hwnd, app, true)
}

WorkspaceApplyEmbeddedWindowStyle(hwnd, app, forceFrameRefresh := false) {
    getStyleApi := A_PtrSize = 8 ? "GetWindowLongPtrW" : "GetWindowLongW"
    setStyleApi := A_PtrSize = 8 ? "SetWindowLongPtrW" : "SetWindowLongW"
    style := DllCall(getStyleApi, "Ptr", hwnd, "Int", -16, "Ptr") ; GWL_STYLE
    newStyle := (style & ~0x80000000) | 0x40000000 ; clear WS_POPUP, set WS_CHILD
    newStyle := newStyle & ~(0x00C00000 | 0x00040000 | 0x00800000) ; remove caption, thick frame and border
    newStyle := newStyle & ~(0x00020000 | 0x00010000 | 0x00080000) ; remove minimize, maximize and system menu
    styleChanged := newStyle != style

    if (styleChanged) {
        DllCall("SetLastError", "UInt", 0)
        previousStyle := DllCall(setStyleApi, "Ptr", hwnd, "Int", -16, "Ptr", newStyle, "Ptr")
        styleError := DllCall("GetLastError", "UInt")
        if (!previousStyle && styleError != 0)
            throw Error("Could not configure child-window style for application '" . app["id"] . "' (Win32 " . styleError . ")")
    }

    if ((styleChanged || forceFrameRefresh)
        && !DllCall("SetWindowPos", "Ptr", hwnd, "Ptr", 0, "Int", 0, "Int", 0, "Int", 0, "Int", 0, "UInt", 0x0027, "Int")) ; SWP_FRAMECHANGED | SWP_NOZORDER | SWP_NOMOVE | SWP_NOSIZE
        throw Error("Could not refresh the embedded window frame for application '" . app["id"] . "'")

    return style
}

WorkspaceWindowHasNativeFrame(hwnd) {
    getStyleApi := A_PtrSize = 8 ? "GetWindowLongPtrW" : "GetWindowLongW"
    style := DllCall(getStyleApi, "Ptr", hwnd, "Int", -16, "Ptr") ; GWL_STYLE
    nativeFrameMask := 0x00C00000 | 0x00040000 | 0x00800000 | 0x00020000 | 0x00010000 | 0x00080000 | 0x80000000
    return (style & nativeFrameMask) != 0
}

WorkspaceDpiAwarenessName(awareness) {
    switch awareness {
        case 0: return "unaware"
        case 1: return "system-aware"
        case 2: return "per-monitor-aware"
        default: return "unknown (" . awareness . ")"
    }
}

WorkspaceAddClipChildren(hwnd) {
    getStyleApi := A_PtrSize = 8 ? "GetWindowLongPtrW" : "GetWindowLongW"
    setStyleApi := A_PtrSize = 8 ? "SetWindowLongPtrW" : "SetWindowLongW"
    style := DllCall(getStyleApi, "Ptr", hwnd, "Int", -16, "Ptr")
    if (style & 0x02000000) ; WS_CLIPCHILDREN
        return true

    DllCall("SetLastError", "UInt", 0)
    previousStyle := DllCall(setStyleApi, "Ptr", hwnd, "Int", -16, "Ptr", style | 0x02000000, "Ptr")
    styleError := DllCall("GetLastError", "UInt")
    return previousStyle != 0 || styleError = 0
}

WorkspaceSelectTab(index) {
    global WORKSPACE_APPS, WORKSPACE_STATUS_TEXT, WORKSPACE_PANEL
    if (index < 1 || index > WORKSPACE_APPS.Length)
        return

    selected := WORKSPACE_APPS[index]
    for appIndex, app in WORKSPACE_APPS {
        for hwnd in app["hwnds"] {
            if (!hwnd || !WinExist("ahk_id " . hwnd))
                continue
            role := app["windowRoles"].Has(hwnd) ? app["windowRoles"][hwnd] : "main"
            if (role = "auxiliary")
                DllCall("ShowWindow", "Ptr", hwnd, "Int", 0)
            else if (appIndex = index)
                WorkspaceRestoreHostedWindow(hwnd)
            else
                DllCall("ShowWindow", "Ptr", hwnd, "Int", 0)
        }
    }
    WorkspaceResize()
    ; Show popups only after their app's primary window has been restored.
    for hwnd in selected["hwnds"] {
        if (selected["windowRoles"].Has(hwnd) && selected["windowRoles"][hwnd] = "auxiliary"
            && WinExist("ahk_id " . hwnd))
            DllCall("ShowWindow", "Ptr", hwnd, "Int", 5)
    }
    if (selected["state"] = "running") {
        focusHwnd := selected["hwnd"]
        if (!focusHwnd || !WinExist("ahk_id " . focusHwnd)) {
            for hwnd in selected["hwnds"] {
                if (selected["windowRoles"].Has(hwnd) && selected["windowRoles"][hwnd] = "auxiliary"
                    && WinExist("ahk_id " . hwnd)) {
                    focusHwnd := hwnd
                    break
                }
            }
        }
        if (focusHwnd && WinExist("ahk_id " . focusHwnd)) {
            WORKSPACE_STATUS_TEXT.Visible := false
            if (!DllCall("IsWindowEnabled", "Ptr", focusHwnd, "Int")) {
                for hwnd in selected["hwnds"] {
                    if (selected["windowRoles"].Has(hwnd) && selected["windowRoles"][hwnd] = "auxiliary"
                        && WinExist("ahk_id " . hwnd) && DllCall("IsWindowEnabled", "Ptr", hwnd, "Int")) {
                        focusHwnd := hwnd
                        break
                    }
                }
            }
            try WinActivate("ahk_id " . focusHwnd)
            return
        }
    }

    WORKSPACE_STATUS_TEXT.Text := "Application '" . selected["title"] . "' is no longer running. Reconnect to restart the workspace."
    WORKSPACE_STATUS_TEXT.Visible := true
}

WorkspaceResize() {
    global WORKSPACE_GUI, WORKSPACE_PANEL, WORKSPACE_TABS, WORKSPACE_TAB_HEIGHT, WORKSPACE_APPS
    if (!IsObject(WORKSPACE_GUI) || !IsObject(WORKSPACE_PANEL) || !IsObject(WORKSPACE_TABS))
        return

    WORKSPACE_GUI.GetClientPos(&clientX, &clientY, &clientWidth, &clientHeight)
    panelHeight := Max(1, clientHeight - WORKSPACE_TAB_HEIGHT)
    WORKSPACE_TABS.Move(0, 0, clientWidth, WORKSPACE_TAB_HEIGHT)
    WORKSPACE_PANEL.Move(0, WORKSPACE_TAB_HEIGHT, clientWidth, panelHeight)

    for app in WORKSPACE_APPS {
        for hwnd in app["hwnds"] {
            if (hwnd && WinExist("ahk_id " . hwnd) && app["windowRoles"].Has(hwnd)
                && app["windowRoles"][hwnd] = "main")
                DllCall("MoveWindow", "Ptr", hwnd, "Int", 0, "Int", 0, "Int", clientWidth, "Int", panelHeight, "Int", 1, "Int")
        }
    }
    WORKSPACE_STATUS_TEXT.Move(24, 24, Max(1, clientWidth - 48), 60)
}

WorkspaceMonitor(*) {
    global WORKSPACE_MODE, WORKSPACE_SHUTTING_DOWN, WORKSPACE_APPS, WORKSPACE_TABS, WORKSPACE_PANEL
    if (!WORKSPACE_MODE || WORKSPACE_SHUTTING_DOWN)
        return

    for index, app in WORKSPACE_APPS {
        if (app["state"] != "running")
            continue
        try {
            adopted := WorkspaceAdoptNewWindows(app)
            WorkspacePruneAttachedWindows(app)
            for hwnd in app["hwnds"] {
                if (!app["windowRoles"].Has(hwnd) || app["windowRoles"][hwnd] != "main")
                    continue
                ; Applications may restore their native title bar after startup.
                ; Keep every hosted top-level window borderless for its lifetime.
                if (WorkspaceWindowHasNativeFrame(hwnd)) {
                    Log("Application '" . app["id"] . "' restored native frame styles; removing them", "WARNING")
                    WorkspaceApplyEmbeddedWindowStyle(hwnd, app, true)
                }
            }
            if (adopted)
                WorkspaceResize()
        } catch as e {
            Log("Could not maintain workspace windows for '" . app["id"] . "': " . e.Message, "ERROR")
        }

        if (WorkspaceHasAttachedWindow(app)) {
            app["noWindowSinceTick"] := 0
            continue
        }

        if (WorkspaceLaunchProcessIsRunning(app)) {
            if (!app["noWindowSinceTick"])
                app["noWindowSinceTick"] := A_TickCount
            if (A_TickCount - app["noWindowSinceTick"] < 3000)
                continue
            ; The application has been running in the workspace but no hosted
            ; window remains. Give brief window-recreation transitions a chance,
            ; then clean up only the process AppControl originally launched.
            WorkspaceTerminateProcessTree(app["launchPid"])
        }

        Log("Workspace application stopped: " . app["id"], "WARNING")
        app["state"] := "closed"
        WorkspaceCloseProcessHandle(app)
        if (WORKSPACE_TABS.Value = index)
            WorkspaceSelectTab(index)
    }

    allClosed := true
    for app in WORKSPACE_APPS {
        if (app["state"] = "running") {
            allClosed := false
            break
        }
    }
    if (allClosed) {
        Log("All workspace applications have exited", "INFO")
        WorkspaceCloseAll("all applications exited")
        ExitApp(0)
    }
}

WorkspaceProcessIsRunning(app) {
    return WorkspaceHasAttachedWindow(app) || WorkspaceLaunchProcessIsRunning(app)
}

WorkspaceLaunchProcessIsRunning(app) {
    ; ShellExecute-based launchers can return the PID of an already-running
    ; single-instance app. Do not supervise or terminate a process that owned
    ; matching windows before this workspace launched it.
    if (app["preexistingPids"].Has(app["launchPid"]))
        return false
    handle := app["processHandle"]
    if (handle)
        return DllCall("WaitForSingleObject", "Ptr", handle, "UInt", 0, "UInt") = 0x00000102 ; WAIT_TIMEOUT
    return app["launchPid"] && ProcessExist(app["launchPid"])
}

WorkspaceHasAttachedWindow(app) {
    for hwnd in app["hwnds"] {
        if (hwnd && WinExist("ahk_id " . hwnd))
            return true
    }
    return false
}

WorkspacePruneAttachedWindows(app) {
    hwnds := []
    trackedWindows := Map()
    windowRoles := Map()
    windowPids := Map()
    primaryHwnd := 0
    for hwnd in app["hwnds"] {
        if (!hwnd || !WinExist("ahk_id " . hwnd) || !WorkspaceWindowUsesExecutable(hwnd, app["windowExecutable"]))
            continue
        pid := WorkspaceGetWindowProcessId(hwnd)
        if (!pid)
            continue
        hwnds.Push(hwnd)
        trackedWindows[hwnd] := true
        role := app["windowRoles"].Has(hwnd) ? app["windowRoles"][hwnd] : "main"
        windowRoles[hwnd] := role
        if (role = "main" && !primaryHwnd)
            primaryHwnd := hwnd
        windowPids[pid] := true
    }
    app["hwnds"] := hwnds
    app["trackedWindows"] := trackedWindows
    app["windowRoles"] := windowRoles
    app["windowPids"] := windowPids
    app["hwnd"] := primaryHwnd
    app["windowPid"] := primaryHwnd ? WorkspaceGetWindowProcessId(primaryHwnd) : 0
}

WorkspaceCloseAll(reason := "workspace close") {
    global WORKSPACE_APPS, WORKSPACE_SHUTTING_DOWN
    if (WORKSPACE_SHUTTING_DOWN)
        return true

    WORKSPACE_SHUTTING_DOWN := true
    SetTimer(WorkspaceMonitor, 0)
    Log("Closing workspace applications (" . reason . ")", "INFO")
    success := true

    Loop WORKSPACE_APPS.Length {
        index := WORKSPACE_APPS.Length - A_Index + 1
        app := WORKSPACE_APPS[index]
        Loop app["hwnds"].Length {
            hwnd := app["hwnds"][app["hwnds"].Length - A_Index + 1]
            if (hwnd && WinExist("ahk_id " . hwnd))
                PostMessage(0x0010, 0, 0, , "ahk_id " . hwnd) ; WM_CLOSE
        }

        if (!WaitUntil(() => !WorkspaceHasAttachedWindow(app) && !WorkspaceLaunchProcessIsRunning(app), 4000, 100)) {
            ; Only terminate the process AppControl started. A browser window may
            ; belong to a pre-existing shared browser process, which must survive.
            if (WorkspaceLaunchProcessIsRunning(app))
                WorkspaceTerminateProcessTree(app["launchPid"])
            if (!WaitUntil(() => !WorkspaceHasAttachedWindow(app) && !WorkspaceLaunchProcessIsRunning(app), 3000, 100)) {
                Log("Workspace application did not close cleanly: " . app["id"] . " (launcher PID " . app["launchPid"] . ")", "ERROR")
                success := false
            }
        }
        app["state"] := "closed"
        WorkspaceCloseProcessHandle(app)
    }
    return success
}

WorkspaceTerminateProcessTree(pid) {
    if (!pid || !ProcessExist(pid))
        return true
    taskkill := A_WinDir . "\System32\taskkill.exe"
    try RunWait('"' . taskkill . '" /PID ' . Integer(pid) . " /T /F", , "Hide")
    catch as e
        Log("Unable to terminate workspace process tree PID " . pid . ": " . e.Message, "ERROR")
    return !ProcessExist(pid)
}

WorkspaceCloseProcessHandle(app) {
    if (app["processHandle"])
        DllCall("CloseHandle", "Ptr", app["processHandle"], "Int")
    app["processHandle"] := 0
}

WorkspaceOnGuiClose() {
    WorkspaceCloseAll("workspace window closed")
    ExitApp(0)
}

WorkspaceOnExit(exitReason, exitCode) {
    global WORKSPACE_MODE, WORKSPACE_SHUTTING_DOWN
    if (WORKSPACE_MODE && !WORKSPACE_SHUTTING_DOWN)
        WorkspaceCloseAll("AppControl exit: " . exitReason)
}

WorkspaceHasActiveWindow() {
    global WORKSPACE_MODE, WORKSPACE_GUI
    return WORKSPACE_MODE && IsObject(WORKSPACE_GUI) && WinActive("ahk_id " . WORKSPACE_GUI.Hwnd)
}

WorkspaceTestMode() {
    global WORKSPACE_TEST_MODE
    return WORKSPACE_TEST_MODE
}
