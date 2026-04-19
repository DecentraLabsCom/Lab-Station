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

windowOptions := "+Resize -MaximizeBox +OwnDialogs"
if (className != "")
    windowOptions .= " +Class" . className

gui := Gui(windowOptions)
gui.BackColor := color
gui.SetFont("s12", "Segoe UI")
gui.AddText("xm ym w360 Wrap", message)
gui.AddButton("xm y+20 w120", "Idle")
gui.AddButton("x+10 yp w120", "Stop")

gui.Show("w420 h260", title)

if (lifetimeSec > 0) {
    SetTimer(() => ExitApp(), -lifetimeSec * 1000)
}

OnMessage(0x0010, (*) => ExitApp())
return
