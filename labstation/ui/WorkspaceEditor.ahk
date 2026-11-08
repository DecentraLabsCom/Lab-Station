; ============================================================================
; Lab Station - Remote App workspace manifest editor
; ============================================================================
#Requires AutoHotkey v2.0
#Include ..\core\Admin.ahk
#Include ..\core\Json.ahk
#Include ..\system\RemoteAppWorkspaceStore.ahk
#Include ..\system\AppControlManager.ahk

global LS_WORKSPACE_EDITOR_GUI := 0

LS_ShowWorkspaceEditor(*) {
    global LS_WORKSPACE_EDITOR_GUI, APP_WORKSPACE_CONFIG_ROOT

    if (!A_IsAdmin) {
        LS_EnsureAdmin()
        return
    }
    if (!LS_RemoteAppWorkspaceStore.Ensure()) {
        MsgBox "The protected workspace folder could not be prepared. Check the Lab Station log.",
            "Workspace editor", "OK Iconx"
        return
    }

    if (IsObject(LS_WORKSPACE_EDITOR_GUI)) {
        try {
            LS_WORKSPACE_EDITOR_GUI.Show()
            WinActivate("ahk_id " . LS_WORKSPACE_EDITOR_GUI.Hwnd)
            return
        } catch {
            LS_WORKSPACE_EDITOR_GUI := 0
        }
    }

    editor := Gui("-Resize -MaximizeBox", "Remote App Workspace Editor")
    editor.BackColor := "0F1419"
    editor.SetFont("s10", "Segoe UI")
    editor.Apps := []
    editor.LoadedWorkspaceId := ""

    editor.SetFont("s16 Bold cFFFFFF", "Bahnschrift")
    editor.AddText("x24 y16 w650", "Remote App workspaces")
    editor.SetFont("s9 c9CA3AF", "Segoe UI")
    editor.AddText("x24 y47 w870", "Create a tabbed AppControl workspace with two to five applications. For a single application, call AppControl with parameters directly from the Guacamole connection configuration instead.")

    editor.SetFont("s9 Bold c9CA3AF")
    editor.AddText("x24 y82 w90", "Workspace ID")
    editor.WorkspaceIdEdit := editor.AddEdit("x24 y103 w285 h28")
    editor.WorkspaceIdEdit.OnEvent("Change", LS_WorkspaceEditorIdChanged_Handler)
    editor.AddText("x326 y82 w450", "Saved as")
    editor.ManifestPathText := editor.AddText("x326 y105 w450 h31 cD1FAE5", APP_WORKSPACE_CONFIG_ROOT . "\<id>.json")
    editor.SetFont("s9 cFFFFFF", "Segoe UI")
    editor.NewButton := editor.AddButton("x786 y77 w110 h28", "New")
    editor.OpenButton := editor.AddButton("x786 y109 w110 h28", "Open...")

    editor.SetFont("s9 Bold c9CA3AF")
    editor.AddText("x24 y146 w870", "Applications (the list order becomes the tab order)")
    editor.SetFont("s9 c6B7280")
    editor.AppList := editor.AddListView("x24 y169 w872 h292 -Multi", ["Tab", "Application", "Window selection"])
    editor.AppList.ModifyCol(1, 170)
    editor.AppList.ModifyCol(2, 480)
    editor.AppList.ModifyCol(3, 190)

    editor.SetFont("s9 cFFFFFF")
    editor.AddAppButton := editor.AddButton("x24 y477 w90 h30", "Add app")
    editor.EditAppButton := editor.AddButton("x122 y477 w90 h30", "Edit app")
    editor.RemoveAppButton := editor.AddButton("x220 y477 w90 h30", "Remove app")
    editor.SetFont("s14 cFFFFFF", "Segoe UI Symbol")
    editor.MoveUpButton := editor.AddButton("x318 y477 w38 h30", "↑")
    editor.MoveDownButton := editor.AddButton("x364 y477 w38 h30", "↓")
    editor.SetFont("s9 cFFFFFF", "Segoe UI")
    editor.SaveButton := editor.AddButton("x742 y477 w82 h30 Default", "Save")
    editor.CloseButton := editor.AddButton("x834 y477 w62 h30", "Close")

    editor.SetFont("s8 c9CA3AF")
    editor.StatusText := editor.AddText("x24 y523 w748 h46", "Add two to five apps. Leave window matching on Automatic for most programs.")
    editor.SetFont("s9 cFFFFFF", "Segoe UI")
    editor.LaunchTestButton := editor.AddButton("x788 y523 w108 h30", "Launch test")

    editor.NewButton.OnEvent("Click", LS_WorkspaceEditorNew_Handler)
    editor.OpenButton.OnEvent("Click", LS_WorkspaceEditorOpen_Handler)
    editor.AddAppButton.OnEvent("Click", LS_WorkspaceEditorAddApp_Handler)
    editor.EditAppButton.OnEvent("Click", LS_WorkspaceEditorEditApp_Handler)
    editor.RemoveAppButton.OnEvent("Click", LS_WorkspaceEditorRemoveApp_Handler)
    editor.MoveUpButton.OnEvent("Click", LS_WorkspaceEditorMoveUp_Handler)
    editor.MoveDownButton.OnEvent("Click", LS_WorkspaceEditorMoveDown_Handler)
    editor.SaveButton.OnEvent("Click", LS_WorkspaceEditorSave_Handler)
    editor.LaunchTestButton.OnEvent("Click", LS_WorkspaceEditorLaunchTest_Handler)
    editor.CloseButton.OnEvent("Click", (*) => editor.Destroy())
    editor.OnEvent("Close", LS_WorkspaceEditorClose_Handler)

    LS_WORKSPACE_EDITOR_GUI := editor
    editor.Show("w920 h590 Center")
    LS_WorkspaceEditorNew(editor)
}

LS_WorkspaceEditorClose_Handler(guiObj) {
    global LS_WORKSPACE_EDITOR_GUI
    if (IsObject(LS_WORKSPACE_EDITOR_GUI) && LS_WORKSPACE_EDITOR_GUI.Hwnd = guiObj.Hwnd)
        LS_WORKSPACE_EDITOR_GUI := 0
}

LS_WorkspaceEditorNew_Handler(ctrl, info) {
    LS_WorkspaceEditorNew(ctrl.Gui)
}

LS_WorkspaceEditorNew(editor) {
    global APP_WORKSPACE_CONFIG_ROOT
    editor.WorkspaceIdEdit.Value := "workspace-" . FormatTime(A_Now, "yyyyMMdd-HHmmss")
    editor.LoadedWorkspaceId := ""
    editor.Apps := []
    editor.ManifestPathText.Text := "New manifest in " . APP_WORKSPACE_CONFIG_ROOT
    editor.StatusText.Text := "New workspace. Add at least two applications, then save."
    LS_WorkspaceEditorRefreshApps(editor)
}

LS_WorkspaceEditorIdChanged_Handler(ctrl, info) {
    global APP_WORKSPACE_CONFIG_ROOT
    workspaceId := LS_WorkspaceEditorNormalizeId(ctrl.Value)
    if (workspaceId = "")
        workspaceId := "<id>"
    ctrl.Gui.ManifestPathText.Text := APP_WORKSPACE_CONFIG_ROOT . "\" . workspaceId . ".json"
}

LS_WorkspaceEditorOpen_Handler(ctrl, info) {
    global APP_WORKSPACE_CONFIG_ROOT
    editor := ctrl.Gui
    if (!LS_RemoteAppWorkspaceStore.Ensure()) {
        MsgBox "The workspace folder permissions could not be repaired. Check the Lab Station log.",
            "Workspace editor", "OK Iconx"
        return
    }

    path := FileSelect("1", APP_WORKSPACE_CONFIG_ROOT, "Open workspace manifest", "JSON files (*.json)")
    if (path = "")
        return

    SplitPath(path, &fileName, &directory, &extension, &workspaceId)
    if (StrLower(RTrim(directory, "\")) != StrLower(RTrim(APP_WORKSPACE_CONFIG_ROOT, "\"))
        || StrLower(extension) != "json") {
        MsgBox "Choose a .json manifest from the protected workspace folder.", "Workspace editor", "OK Iconx"
        return
    }

    try {
        if (FileGetSize(path) > 1048576)
            throw Error("Manifest exceeds the 1 MiB limit")
        manifest := LS_ParseJson(FileRead(path, "UTF-8"))
        if !(manifest is Map)
            throw Error("Manifest root must be a JSON object")
        if (!manifest.Has("schemaVersion") || manifest["schemaVersion"] != 1)
            throw Error("Only workspace manifest schema version 1 is supported")
        if (!manifest.Has("workspaceId") || manifest["workspaceId"] != workspaceId)
            throw Error("The manifest workspaceId must match its filename")
        if (!manifest.Has("apps") || !(manifest["apps"] is Array))
            throw Error("Manifest apps must be an array")
        if (manifest["apps"].Length < 2 || manifest["apps"].Length > 5)
            throw Error("A workspace must contain between two and five applications")

        apps := []
        for index, source in manifest["apps"]
            apps.Push(LS_WorkspaceEditorNormalizeApp(source, index))

        editor.WorkspaceIdEdit.Value := workspaceId
        editor.LoadedWorkspaceId := workspaceId
        editor.ManifestPathText.Text := path
        editor.Apps := apps
        editor.StatusText.Text := "Loaded " . workspaceId . ". Edit the applications and save when ready."
        LS_WorkspaceEditorRefreshApps(editor)
    } catch as e {
        MsgBox "Could not open this workspace:`n" . e.Message, "Workspace editor", "OK Iconx"
    }
}

LS_WorkspaceEditorNormalizeApp(source, index) {
    if !(source is Map)
        throw Error("Application " . index . " must be a JSON object")
    if (!source.Has("title") || Type(source["title"]) != "String" || Trim(source["title"]) = "")
        throw Error("Application " . index . " has no tab title")
    if (!source.Has("executable") || Type(source["executable"]) != "String")
        throw Error("Application " . index . " has no executable path")

    arguments := source.Has("arguments") ? source["arguments"] : []
    if !(arguments is Array)
        throw Error("Application " . index . " arguments must be an array")
    for argument in arguments {
        if (Type(argument) != "String")
            throw Error("Application " . index . " contains a non-string argument")
    }

    workingDirectory := source.Has("workingDirectory") ? source["workingDirectory"] : ""
    windowExecutable := source.Has("windowExecutable") ? source["windowExecutable"] : ""
    windowClass := source.Has("windowClass") ? source["windowClass"] : ""
    titleContains := source.Has("windowTitleContains") ? source["windowTitleContains"] : ""
    timeout := source.Has("startupTimeoutSeconds") ? source["startupTimeoutSeconds"] : 60
    if (Type(workingDirectory) != "String" || Type(windowExecutable) != "String"
        || Type(windowClass) != "String" || Type(titleContains) != "String")
        throw Error("Application " . index . " has invalid optional field types")
    try timeout := Integer(timeout)
    catch
        throw Error("Application " . index . " startup timeout must be an integer")
    if (timeout < 5 || timeout > 120)
        throw Error("Application " . index . " startup timeout must be an integer from 5 to 120")

    return Map(
        "id", source.Has("id") && Type(source["id"]) = "String" ? source["id"] : "",
        "title", source["title"],
        "executable", source["executable"],
        "windowExecutable", windowExecutable,
        "arguments", arguments,
        "workingDirectory", workingDirectory,
        "windowClass", windowClass,
        "windowTitleContains", titleContains,
        "startupTimeoutSeconds", Integer(timeout)
    )
}

LS_WorkspaceEditorRefreshApps(editor) {
    editor.AppList.Delete()
    for app in editor.Apps {
        SplitPath(app["executable"], &fileName)
        windowLabel := app["windowClass"] != "" ? app["windowClass"] : "Automatic"
        if (app["windowExecutable"] != "") {
            SplitPath(app["windowExecutable"], &windowFileName)
            windowLabel := windowFileName . " / " . windowLabel
        }
        if (app["windowTitleContains"] != "")
            windowLabel .= " / " . app["windowTitleContains"]
        editor.AppList.Add(, app["title"], fileName, windowLabel)
    }
    editor.StatusText.Text := editor.Apps.Length . " of 5 applications. Automatic window matching is used when no class is specified."
}

LS_WorkspaceEditorAddApp_Handler(ctrl, info) {
    editor := ctrl.Gui
    if (editor.Apps.Length >= 5) {
        MsgBox "A workspace can contain at most five applications.", "Workspace editor", "OK Iconi"
        return
    }
    LS_WorkspaceEditorShowAppDialog(editor)
}

LS_WorkspaceEditorEditApp_Handler(ctrl, info) {
    editor := ctrl.Gui
    index := editor.AppList.GetNext()
    if (!index) {
        MsgBox "Select an application to edit.", "Workspace editor", "OK Iconi"
        return
    }
    LS_WorkspaceEditorShowAppDialog(editor, index)
}

LS_WorkspaceEditorRemoveApp_Handler(ctrl, info) {
    editor := ctrl.Gui
    index := editor.AppList.GetNext()
    if (!index)
        return
    editor.Apps.RemoveAt(index)
    LS_WorkspaceEditorRefreshApps(editor)
}

LS_WorkspaceEditorMoveUp_Handler(ctrl, info) {
    LS_WorkspaceEditorMoveApp(ctrl.Gui, -1)
}

LS_WorkspaceEditorMoveDown_Handler(ctrl, info) {
    LS_WorkspaceEditorMoveApp(ctrl.Gui, 1)
}

LS_WorkspaceEditorMoveApp(editor, direction) {
    index := editor.AppList.GetNext()
    targetIndex := index + direction
    if (!index || targetIndex < 1 || targetIndex > editor.Apps.Length)
        return
    app := editor.Apps.RemoveAt(index)
    editor.Apps.InsertAt(targetIndex, app)
    LS_WorkspaceEditorRefreshApps(editor)
    editor.AppList.Modify(targetIndex, "Select Focus Vis")
}

LS_WorkspaceEditorShowAppDialog(editor, index := 0) {
    seed := index ? editor.Apps[index] : Map(
        "title", "", "executable", "", "arguments", [], "workingDirectory", "",
        "windowExecutable", "", "windowClass", "", "windowTitleContains", "", "startupTimeoutSeconds", 60, "id", ""
    )
    dialog := Gui("+Owner" . editor.Hwnd . " +ToolWindow", index ? "Edit application" : "Add application")
    dialog.BackColor := "0F1419"
    dialog.SetFont("s9 cE5E7EB", "Segoe UI")
    dialog.ParentEditor := editor
    dialog.ItemIndex := index
    dialog.AdvancedVisible := false
    dialog.Closing := false

    dialog.AddText("x20 y20 w115", "Tab name")
    dialog.SetFont("s9 c374151", "Segoe UI")
    dialog.TitleEdit := dialog.AddEdit("x140 y17 w475", seed["title"])
    dialog.SetFont("s9 cE5E7EB", "Segoe UI")
    dialog.AddText("x20 y57 w115", "Application")
    dialog.SetFont("s9 c374151", "Segoe UI")
    dialog.ExecutableEdit := dialog.AddEdit("x140 y54 w390", seed["executable"])
    dialog.BrowseExeButton := dialog.AddButton("x538 y53 w77 h25", "Browse...")
    dialog.BrowseExeButton.OnEvent("Click", LS_WorkspaceEditorBrowseExe_Handler)
    dialog.SetFont("s9 cE5E7EB", "Segoe UI")
    dialog.AddText("x20 y94 w115", "Parameters")
    dialog.SetFont("s9 c374151", "Segoe UI")
    dialog.ArgumentsEdit := dialog.AddEdit("x140 y91 w475 h48 +Multi")
    dialog.ArgumentsEdit.Value := LS_WorkspaceEditorFormatArguments(seed["arguments"])
    dialog.SetFont("s9 cE5E7EB", "Segoe UI")
    dialog.AddText("x20 y151 w115", "Working folder")
    dialog.SetFont("s9 c374151", "Segoe UI")
    dialog.WorkingDirectoryEdit := dialog.AddEdit("x140 y148 w390", seed["workingDirectory"])
    dialog.BrowseFolderButton := dialog.AddButton("x538 y147 w77 h25", "Browse...")
    dialog.BrowseFolderButton.OnEvent("Click", LS_WorkspaceEditorBrowseFolder_Handler)

    dialog.SetFont("s8 c9CA3AF", "Segoe UI")
    dialog.AddText("x20 y184 w595 h31", "AppControl waits for the main window. Configure Advanced matching if a launcher starts another program.")
    dialog.SetFont("s8 c374151", "Segoe UI")
    dialog.AdvancedButton := dialog.AddButton("x20 y222 w150 h26", "Advanced matching...")
    dialog.AdvancedButton.OnEvent("Click", LS_WorkspaceEditorAdvanced_Handler)
    dialog.SetFont("s8 c9CA3AF", "Segoe UI")
    dialog.WindowExecutableLabel := dialog.AddText("x20 y267 w115 Hidden", "Window executable")
    dialog.SetFont("s8 c374151", "Segoe UI")
    dialog.WindowExecutableEdit := dialog.AddEdit("x140 y264 w390 Hidden", seed["windowExecutable"])
    dialog.BrowseWindowExeButton := dialog.AddButton("x538 y263 w77 h25 Hidden", "Browse...")
    dialog.BrowseWindowExeButton.OnEvent("Click", LS_WorkspaceEditorBrowseWindowExe_Handler)
    dialog.SetFont("s8 c9CA3AF", "Segoe UI")
    dialog.WindowClassLabel := dialog.AddText("x20 y302 w115 Hidden", "Window class")
    dialog.SetFont("s8 c374151", "Segoe UI")
    dialog.WindowClassEdit := dialog.AddEdit("x140 y299 w475 Hidden", seed["windowClass"])
    dialog.SetFont("s8 c9CA3AF", "Segoe UI")
    dialog.TitleFilterLabel := dialog.AddText("x20 y337 w115 Hidden", "Title contains")
    dialog.SetFont("s8 c374151", "Segoe UI")
    dialog.TitleFilterEdit := dialog.AddEdit("x140 y334 w475 Hidden", seed["windowTitleContains"])
    dialog.SetFont("s8 c9CA3AF", "Segoe UI")
    dialog.TimeoutLabel := dialog.AddText("x20 y372 w115 Hidden", "Wait up to (seconds)")
    dialog.SetFont("s8 c374151", "Segoe UI")
    dialog.TimeoutEdit := dialog.AddEdit("x140 y369 w80 Hidden", seed["startupTimeoutSeconds"])
    dialog.SetFont("s8 c9CA3AF", "Segoe UI")
    dialog.AdvancedHelpText := dialog.AddText("x20 y407 w595 h38 Hidden", "Set Window executable when a launcher starts a separate program. Class and title filters select its main window. The wait is a maximum; startup continues as soon as the matching window appears.")

    dialog.SetFont("s9 c374151", "Segoe UI")
    dialog.SaveButton := dialog.AddButton("x453 y222 w78 h30 Default", "Apply")
    dialog.CancelButton := dialog.AddButton("x538 y222 w77 h30", "Cancel")
    dialog.SaveButton.OnEvent("Click", LS_WorkspaceEditorAppSave_Handler)
    dialog.CancelButton.OnEvent("Click", LS_WorkspaceEditorAppCancel_Handler)
    dialog.OnEvent("Close", LS_WorkspaceEditorAppDialogClose_Handler)
    editor.Opt("+Disabled")
    dialog.Show("w640 h260 Center")
}

LS_WorkspaceEditorBrowseExe_Handler(ctrl, info) {
    dialog := ctrl.Gui
    initialPath := dialog.ExecutableEdit.Value
    if (initialPath = "")
        initialPath := A_ProgramFiles
    path := FileSelect("1", initialPath, "Select application", "Programs (*.exe)")
    if (path != "")
        dialog.ExecutableEdit.Value := path
}

LS_WorkspaceEditorBrowseWindowExe_Handler(ctrl, info) {
    dialog := ctrl.Gui
    initialPath := dialog.WindowExecutableEdit.Value
    if (initialPath = "")
        initialPath := dialog.ExecutableEdit.Value
    path := FileSelect("1", initialPath, "Select the executable that owns the main window", "Programs (*.exe)")
    if (path != "")
        dialog.WindowExecutableEdit.Value := path
}

LS_WorkspaceEditorBrowseFolder_Handler(ctrl, info) {
    dialog := ctrl.Gui
    initialFolder := dialog.WorkingDirectoryEdit.Value
    if (initialFolder = "" && dialog.ExecutableEdit.Value != "")
        SplitPath(dialog.ExecutableEdit.Value, , &initialFolder)
    if (initialFolder = "")
        initialFolder := A_ProgramFiles
    path := DirSelect("*" . initialFolder, 1, "Select the application's working folder")
    if (path != "")
        dialog.WorkingDirectoryEdit.Value := RTrim(path, "\")
}

LS_WorkspaceEditorAdvanced_Handler(ctrl, info) {
    dialog := ctrl.Gui
    dialog.AdvancedVisible := !dialog.AdvancedVisible
    visible := dialog.AdvancedVisible
    for control in [dialog.WindowExecutableLabel, dialog.WindowExecutableEdit, dialog.BrowseWindowExeButton,
        dialog.WindowClassLabel, dialog.WindowClassEdit, dialog.TitleFilterLabel,
        dialog.TitleFilterEdit, dialog.TimeoutLabel, dialog.TimeoutEdit, dialog.AdvancedHelpText]
        control.Visible := visible
    dialog.AdvancedButton.Text := visible ? "Hide advanced options" : "Advanced matching..."
    dialog.SaveButton.Move(, visible ? 449 : 222)
    dialog.CancelButton.Move(, visible ? 449 : 222)
    dialog.Show(visible ? "h510" : "h260")
}

LS_WorkspaceEditorAppSave_Handler(ctrl, info) {
    dialog := ctrl.Gui
    app := LS_WorkspaceEditorReadApp(dialog)
    if (!IsObject(app))
        return

    editor := dialog.ParentEditor
    if (dialog.ItemIndex) {
        editor.Apps[dialog.ItemIndex] := app
    } else {
        editor.Apps.Push(app)
    }
    LS_WorkspaceEditorCloseAppDialog(dialog)
    LS_WorkspaceEditorRefreshApps(editor)
}

LS_WorkspaceEditorReadApp(dialog) {
    title := Trim(dialog.TitleEdit.Value)
    executable := Trim(dialog.ExecutableEdit.Value)
    argumentsText := dialog.ArgumentsEdit.Value
    workingDirectory := Trim(dialog.WorkingDirectoryEdit.Value)
    windowExecutable := Trim(dialog.WindowExecutableEdit.Value)
    windowClass := Trim(dialog.WindowClassEdit.Value)
    titleContains := Trim(dialog.TitleFilterEdit.Value)
    timeoutText := Trim(dialog.TimeoutEdit.Value)

    if (title = "" || StrLen(title) > 48) {
        MsgBox "Enter a tab name with 1 to 48 characters.", "Application settings", "OK Iconx"
        return 0
    }
    if (!RegExMatch(executable, "i)^(?:[A-Z]:\\|\\\\)") || !FileExist(executable)) {
        MsgBox "Choose an existing application using its full .exe path.", "Application settings", "OK Iconx"
        return 0
    }
    SplitPath(executable, , &executableDirectory, &extension)
    if (StrLower(extension) != "exe") {
        MsgBox "Choose an .exe application.", "Application settings", "OK Iconx"
        return 0
    }
    if (windowExecutable != "") {
        windowExecutableAttributes := FileExist(windowExecutable)
        if (!RegExMatch(windowExecutable, "i)^(?:[A-Z]:\\|\\\\)") || !windowExecutableAttributes
            || InStr(windowExecutableAttributes, "D")) {
            MsgBox "Window executable must be an existing .exe path.", "Application settings", "OK Iconx"
            return 0
        }
        SplitPath(windowExecutable, , , &windowExtension)
        if (StrLower(windowExtension) != "exe" || StrLen(windowExecutable) > 1024) {
            MsgBox "Window executable must be an .exe path of at most 1024 characters.", "Application settings", "OK Iconx"
            return 0
        }
    }
    if (workingDirectory != "" && (!RegExMatch(workingDirectory, "i)^(?:[A-Z]:\\|\\\\)") || !DirExist(workingDirectory))) {
        MsgBox "The working folder must be an existing absolute folder.", "Application settings", "OK Iconx"
        return 0
    }
    if (StrLen(windowClass) > 128 || StrLen(titleContains) > 256) {
        MsgBox "Advanced matching values are too long.", "Application settings", "OK Iconx"
        return 0
    }
    if (!RegExMatch(timeoutText, "^\d+$")) {
        MsgBox "Startup wait must be an integer from 5 to 120 seconds.", "Application settings", "OK Iconx"
        return 0
    }
    try timeout := Integer(timeoutText)
    catch {
        MsgBox "Startup wait must be an integer from 5 to 120 seconds.", "Application settings", "OK Iconx"
        return 0
    }
    if (timeout < 5 || timeout > 120) {
        MsgBox "Startup wait must be an integer from 5 to 120 seconds.", "Application settings", "OK Iconx"
        return 0
    }

    try arguments := LS_WorkspaceEditorParseArguments(argumentsText)
    catch as e {
        MsgBox "Could not parse application parameters:`n" . e.Message, "Application settings", "OK Iconx"
        return 0
    }
    if (arguments.Length > 128) {
        MsgBox "An application can have at most 128 parameters.", "Application settings", "OK Iconx"
        return 0
    }
    for argument in arguments {
        if (StrLen(argument) > 8192) {
            MsgBox "Each application parameter must be 8192 characters or fewer.", "Application settings", "OK Iconx"
            return 0
        }
    }

    if (workingDirectory = "")
        workingDirectory := executableDirectory

    return Map(
        "id", "",
        "title", title,
        "executable", executable,
        "windowExecutable", windowExecutable,
        "arguments", arguments,
        "workingDirectory", workingDirectory,
        "windowClass", windowClass,
        "windowTitleContains", titleContains,
        "startupTimeoutSeconds", timeout
    )
}

LS_WorkspaceEditorParseArguments(text) {
    arguments := []
    if (text = "")
        return arguments

    argumentCount := 0
    argv := DllCall("Shell32\CommandLineToArgvW", "WStr", text, "Int*", &argumentCount, "Ptr")
    if (!argv)
        throw Error("Windows could not split the parameter string")
    try {
        Loop argumentCount {
            argumentPointer := NumGet(argv, (A_Index - 1) * A_PtrSize, "Ptr")
            arguments.Push(StrGet(argumentPointer, "UTF-16"))
        }
    } finally {
        DllCall("LocalFree", "Ptr", argv, "Ptr")
    }
    return arguments
}

LS_WorkspaceEditorFormatArguments(arguments) {
    result := ""
    for argument in arguments {
        if (result != "")
            result .= " "
        result .= LS_WorkspaceEditorQuoteArgument(argument)
    }
    return result
}

LS_WorkspaceEditorQuoteArgument(argument) {
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
            output .= LS_WorkspaceEditorRepeat(slash, backslashCount * 2 + 1) . quote
            backslashCount := 0
            continue
        }
        output .= LS_WorkspaceEditorRepeat(slash, backslashCount) . character
        backslashCount := 0
    }

    output .= LS_WorkspaceEditorRepeat(slash, backslashCount * 2) . quote
    return output
}

LS_WorkspaceEditorRepeat(character, count) {
    output := ""
    Loop count
        output .= character
    return output
}

LS_WorkspaceEditorAppCancel_Handler(ctrl, info) {
    dialog := ctrl is Gui ? ctrl : ctrl.Gui
    LS_WorkspaceEditorCloseAppDialog(dialog)
}

LS_WorkspaceEditorAppDialogClose_Handler(dialog) {
    if (dialog.Closing)
        return
    dialog.Closing := true
    LS_WorkspaceEditorReenableParent(dialog.ParentEditor)
}

LS_WorkspaceEditorCloseAppDialog(dialog) {
    if (dialog.Closing)
        return
    dialog.Closing := true
    editor := dialog.ParentEditor
    try dialog.Destroy()
    LS_WorkspaceEditorReenableParent(editor)
}

LS_WorkspaceEditorReenableParent(editor) {
    if (!IsObject(editor))
        return
    try editor.Opt("-Disabled")
    try editor.Show()
}

LS_WorkspaceEditorSave_Handler(ctrl, info) {
    LS_WorkspaceEditorSave(ctrl.Gui)
}

LS_WorkspaceEditorLaunchTest_Handler(ctrl, info) {
    editor := ctrl.Gui
    if (!LS_WorkspaceEditorSave(editor))
        return

    workspaceId := editor.LoadedWorkspaceId
    try {
        if (!LS_LaunchAppControl(["@workspace=" . workspaceId, "@workspace-test"])) {
            editor.StatusText.Text := "Could not launch AppControl for '" . workspaceId . "'."
            return
        }
        editor.StatusText.Text := "Test launched for '" . workspaceId . "'. Close the test window to stop its apps."
    } catch as e {
        editor.StatusText.Text := "Workspace test could not be launched."
        MsgBox "Could not launch the workspace test:`n" . e.Message, "Workspace editor", "OK Iconx"
    }
}

LS_WorkspaceEditorSave(editor) {
    global APP_WORKSPACE_CONFIG_ROOT

    if (editor.Apps.Length < 2 || editor.Apps.Length > 5) {
        MsgBox "A workspace must contain between two and five applications.", "Workspace editor", "OK Iconx"
        return false
    }
    try LS_WorkspaceEditorValidateApps(editor.Apps)
    catch as e {
        MsgBox "Fix this workspace before saving:`n" . e.Message, "Workspace editor", "OK Iconx"
        return false
    }

    workspaceId := LS_WorkspaceEditorNormalizeId(editor.WorkspaceIdEdit.Value)
    if (workspaceId = "") {
        MsgBox "Enter a name for the workspace.", "Workspace editor", "OK Iconx"
        return false
    }
    editor.WorkspaceIdEdit.Value := workspaceId

    apps := []
    for index, source in editor.Apps {
        appId := "app-" . index
        appManifest := Map(
            "id", appId,
            "title", source["title"],
            "executable", source["executable"],
            "arguments", source["arguments"],
            "workingDirectory", source["workingDirectory"],
            "windowClass", source["windowClass"],
            "windowTitleContains", source["windowTitleContains"],
            "startupTimeoutSeconds", source["startupTimeoutSeconds"]
        )
        if (source["windowExecutable"] != "")
            appManifest["windowExecutable"] := source["windowExecutable"]
        apps.Push(appManifest)
    }
    manifest := Map("schemaVersion", 1, "workspaceId", workspaceId, "apps", apps)
    targetPath := APP_WORKSPACE_CONFIG_ROOT . "\" . workspaceId . ".json"

    if (FileExist(targetPath) && editor.LoadedWorkspaceId != workspaceId) {
        answer := MsgBox("A workspace with this ID already exists. Replace it?", "Confirm overwrite", "YesNo Icon!")
        if (answer != "Yes")
            return false
    }

    try {
        LS_WriteJson(targetPath, manifest)
        if (!LS_RemoteAppWorkspaceStore.Ensure())
            throw Error("The manifest was saved, but read access could not be granted to LABUSER.")
        editor.LoadedWorkspaceId := workspaceId
        editor.ManifestPathText.Text := targetPath
        editor.StatusText.Text := "Saved " . workspaceId . " with " . apps.Length . " applications."
        return true
    } catch as e {
        MsgBox "Could not save the workspace:`n" . e.Message, "Workspace editor", "OK Iconx"
        return false
    }
}

LS_WorkspaceEditorValidateApps(apps) {
    for index, app in apps {
        if !(app is Map)
            throw Error("Application " . index . " is invalid")

        title := app.Has("title") && Type(app["title"]) = "String" ? Trim(app["title"]) : ""
        executable := app.Has("executable") && Type(app["executable"]) = "String" ? Trim(app["executable"]) : ""
        if (title = "" || StrLen(title) > 48)
            throw Error("Application " . index . " needs a tab name of 1 to 48 characters")
        fileAttributes := FileExist(executable)
        if (!RegExMatch(executable, "i)^(?:[A-Z]:\\|\\\\)") || !fileAttributes || InStr(fileAttributes, "D"))
            throw Error("Application '" . title . "' must point to an existing .exe file")
        SplitPath(executable, , , &extension)
        if (StrLower(extension) != "exe" || StrLen(executable) > 1024)
            throw Error("Application '" . title . "' must use an .exe path of at most 1024 characters")

        if (app.Has("windowExecutable") && Type(app["windowExecutable"]) != "String")
            throw Error("Application '" . title . "' has an invalid window executable path")
        windowExecutable := app.Has("windowExecutable") ? Trim(app["windowExecutable"]) : ""
        if (windowExecutable != "") {
            windowAttributes := FileExist(windowExecutable)
            if (!RegExMatch(windowExecutable, "i)^(?:[A-Z]:\\|\\\\)") || !windowAttributes
                || InStr(windowAttributes, "D"))
                throw Error("Application '" . title . "' has an invalid window executable path")
            SplitPath(windowExecutable, , , &windowExtension)
            if (StrLower(windowExtension) != "exe" || StrLen(windowExecutable) > 1024)
                throw Error("Application '" . title . "' must use a .exe window path of at most 1024 characters")
        }

        workingDirectory := ""
        if (app.Has("workingDirectory")) {
            if (Type(app["workingDirectory"]) != "String")
                throw Error("Application '" . title . "' has an invalid working folder")
            workingDirectory := Trim(app["workingDirectory"])
        }
        if (workingDirectory != "" && (!RegExMatch(workingDirectory, "i)^(?:[A-Z]:\\|\\\\)") || !DirExist(workingDirectory)
            || StrLen(workingDirectory) > 1024))
            throw Error("Application '" . title . "' has an invalid working folder")

        windowClass := ""
        if (app.Has("windowClass")) {
            if (Type(app["windowClass"]) != "String")
                throw Error("Application '" . title . "' has an invalid window class filter")
            windowClass := app["windowClass"]
        }
        titleContains := ""
        if (app.Has("windowTitleContains")) {
            if (Type(app["windowTitleContains"]) != "String")
                throw Error("Application '" . title . "' has an invalid window title filter")
            titleContains := app["windowTitleContains"]
        }
        if (StrLen(windowClass) > 128 || StrLen(titleContains) > 256)
            throw Error("Application '" . title . "' has an advanced window filter that is too long")

        arguments := app.Has("arguments") ? app["arguments"] : []
        if !(arguments is Array) || arguments.Length > 128
            throw Error("Application '" . title . "' may have at most 128 parameters")
        for argument in arguments {
            if (Type(argument) != "String" || StrLen(argument) > 8192)
                throw Error("Application '" . title . "' has an invalid parameter")
        }

        timeout := app.Has("startupTimeoutSeconds") ? app["startupTimeoutSeconds"] : 60
        try timeout := Integer(timeout)
        catch
            throw Error("Application '" . title . "' startup wait must be an integer")
        if (timeout < 5 || timeout > 120)
            throw Error("Application '" . title . "' startup wait must be from 5 to 120 seconds")
    }
}

LS_WorkspaceEditorNormalizeId(value) {
    value := StrLower(Trim(value))
    value := RegExReplace(value, "[^a-z0-9_-]+", "-")
    value := Trim(value, "-_")
    if (value = "")
        return ""
    if (!RegExMatch(value, "^[a-z0-9]"))
        value := "workspace-" . value
    return SubStr(value, 1, 64)
}
