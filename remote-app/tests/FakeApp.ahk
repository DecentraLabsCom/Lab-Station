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

; Gui() uses AutoHotkey's stable runtime window class. The smoke test combines
; that class with each process ID when locating the windows.
windowOptions := "+Resize -MaximizeBox +OwnDialogs"

fakeGui := Gui(windowOptions, title)
fakeGui.BackColor := color
fakeGui.SetFont("s12", "Segoe UI")
fakeGui.AddText("xm ym w360 Wrap", message)
fakeGui.AddButton("xm y+20 w120", "Idle")
fakeGui.AddButton("x+10 yp w120", "Stop")

fakeGui.Show("w420 h260")

if (lifetimeSec > 0) {
    SetTimer(() => ExitApp(), -lifetimeSec * 1000)
}

OnMessage(0x0010, (*) => ExitApp())
return
