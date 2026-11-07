#Requires AutoHotkey v2.0

if (A_Args.Length < 2)
    ExitApp(2)

childScript := A_Args[1]
title := A_Args[2]
commandLine := '"' . A_AhkPath . '" "' . childScript . '" --class AutoHotkeyGUI --title "'
    . title . '" --lifetime 120'
Run(commandLine, , "Hide")
ExitApp(0)
