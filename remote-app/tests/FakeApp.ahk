#Requires AutoHotkey v2.0
#SingleInstance Off

ParseArgs(args) {
    opts := Map()
    i := 1
    while (i <= args.Length) {
        current := args[i]
        if (SubStr(current, 1, 2) = "--") {
            key := SubStr(current, 3)
            value := ""
            if InStr(key, "=") {
                parts := StrSplit(key, "=", , 2)
                key := parts[1]
                value := parts.Length > 1 ? parts[2] : ""
            } else if (i < args.Length) {
                value := args[i + 1]
                i += 1
            }
            opts[key] := value
        }
        i += 1
    }
    return opts
}

opts := ParseArgs(A_Args)
className := opts.Has("class") ? opts["class"] : "SmokeAppClass"
title := opts.Has("title") ? opts["title"] : "Smoke App"
color := opts.Has("color") ? opts["color"] : "0x1E1E1E"
message := opts.Has("message") ? opts["message"] : "Smoke application placeholder"
lifetimeSec := opts.Has("lifetime") && opts["lifetime"] != "" ? Integer(opts["lifetime"]) : 0
extraWindowTitle := opts.Has("extra-title") ? opts["extra-title"] : ""
extraWindowDelayMs := opts.Has("extra-delay") && opts["extra-delay"] != "" ? Integer(opts["extra-delay"]) : 1000
helperWindowTitle := opts.Has("helper-title") ? opts["helper-title"] : ""
minimizedMarker := opts.Has("minimized-marker") ? opts["minimized-marker"] : ""
dpiUnaware := opts.Has("dpi-unaware") && opts["dpi-unaware"] = "true"
ownedDialogTitle := opts.Has("owned-dialog-title") ? opts["owned-dialog-title"] : ""
ownedDialogDelayMs := opts.Has("owned-dialog-delay") && opts["owned-dialog-delay"] != ""
    ? Integer(opts["owned-dialog-delay"]) : 500
ownedDialogModal := opts.Has("owned-dialog-modal") && opts["owned-dialog-modal"] = "true"

; Gui() uses AutoHotkey's stable runtime window class. The smoke test combines
; that class with each process ID when locating the windows.
windowOptions := "+Resize -MaximizeBox +OwnDialogs"
if (opts.Has("toolwindow") && opts["toolwindow"] = "true")
    windowOptions .= " +ToolWindow"

fakeGui := CreateFakeGui(windowOptions, title, dpiUnaware)
fakeGui.BackColor := color
fakeGui.SetFont("s12", "Segoe UI")
fakeGui.AddText("xm ym w360 Wrap", message)
fakeGui.AddButton("xm y+20 w120", "Idle")
fakeGui.AddButton("x+10 yp w120", "Stop")

fakeGui.Show("w420 h260")

if (opts.Has("minimized") && opts["minimized"] = "true") {
    DllCall("ShowWindow", "Ptr", fakeGui.Hwnd, "Int", 6) ; SW_MINIMIZE
    if (minimizedMarker != "")
        FileAppend(DllCall("IsIconic", "Ptr", fakeGui.Hwnd, "Int") ? "minimized" : "visible", minimizedMarker, "UTF-8")
}

if (helperWindowTitle != "") {
    helperGui := Gui("+ToolWindow", helperWindowTitle)
    helperGui.Show("w24 h24")
}

if (ownedDialogTitle != "")
    SetTimer(() => CreateOwnedDialog(ownedDialogTitle, fakeGui.Hwnd, ownedDialogModal), -ownedDialogDelayMs)

if (extraWindowTitle != "")
    SetTimer(() => CreateExtraWindow(extraWindowTitle), -extraWindowDelayMs)

if (lifetimeSec > 0) {
    SetTimer(() => ExitApp(), -lifetimeSec * 1000)
}

OnMessage(0x0010, (*) => ExitApp())
return

CreateExtraWindow(title) {
    global FAKE_EXTRA_GUI
    FAKE_EXTRA_GUI := Gui("+Resize", title)
    FAKE_EXTRA_GUI.AddText("x20 y20 w260", title)
    FAKE_EXTRA_GUI.Show("w320 h180")
}

CreateOwnedDialog(title, ownerHwnd, modal := false) {
    global FAKE_OWNED_DIALOG
    FAKE_OWNED_DIALOG := Gui("+Owner" . ownerHwnd . " +Resize", title)
    FAKE_OWNED_DIALOG.AddText("x16 y16 w280", title)
    continueButton := FAKE_OWNED_DIALOG.AddButton("x16 y52 w120", "Continue")
    continueButton.OnEvent("Click", (*) => CloseOwnedDialog(ownerHwnd))
    if (modal)
        DllCall("EnableWindow", "Ptr", ownerHwnd, "Int", 0)
    FAKE_OWNED_DIALOG.Show("w320 h140")
}

CloseOwnedDialog(ownerHwnd) {
    global FAKE_OWNED_DIALOG
    if (DllCall("IsWindow", "Ptr", ownerHwnd, "Int"))
        DllCall("EnableWindow", "Ptr", ownerHwnd, "Int", 1)
    if (IsObject(FAKE_OWNED_DIALOG))
        FAKE_OWNED_DIALOG.Destroy()
}

CreateFakeGui(options, title, dpiUnaware := false) {
    if (!dpiUnaware)
        return Gui(options, title)

    previousContext := DllCall("SetThreadDpiAwarenessContext", "Ptr", -1, "Ptr")
    if (!previousContext)
        throw Error("Could not set the fake app thread to DPI-unaware context")

    try {
        return Gui(options, title)
    } finally {
        restoredContext := DllCall("SetThreadDpiAwarenessContext", "Ptr", previousContext, "Ptr")
        if (!restoredContext)
            throw Error("Could not restore the fake app thread DPI context")
    }
}
