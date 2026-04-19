; ============================================================================
; Lab Station - Shell helpers
; ============================================================================
#Requires AutoHotkey v2.0
#Include Config.ahk
#Include Logger.ahk

LS_RunPowerShell(script, description := "PowerShell command") {
    tempScript := A_Temp "\LabStation-" . A_TickCount . ".ps1"
    try {
        FileDelete(tempScript)
    } catch {
    }
    try {
        FileAppend(script, tempScript, "UTF-8")
    } catch as e {
        LS_LogError("Cannot write temporary PowerShell script: " . e.Message)
        return -1
    }

    command := Format('powershell -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{1}"', tempScript)
    LS_LogInfo("Executing PowerShell - " . description)
    exitCode := RunWait(command, , "Hide")
    try FileDelete(tempScript)
    return exitCode
}

LS_RunPowerShellCapture(script, description := "PowerShell command") {
    tempScript := A_Temp "\LabStation-" . A_TickCount . "-capture.ps1"
    try FileDelete(tempScript)
    try {
        FileAppend(script, tempScript, "UTF-8")
    } catch as e {
        LS_LogError("Cannot write temporary PowerShell script: " . e.Message)
        return Map("exitCode", -1, "stdout", "", "stderr", e.Message)
    }
    command := Format('powershell -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{1}"', tempScript)
    capture := LS_RunCommandCapture(command, description)
    try FileDelete(tempScript)
    return capture
}

LS_RunCommand(command, description := "command") {
    LS_LogInfo("Executing command - " . description)
    return RunWait(command, , "Hide")
}

LS_RunCommandCapture(command, description := "command") {
    LS_LogInfo("Capturing command output - " . description)
    stdoutPath := A_Temp "\LabStation-" . A_TickCount . "-stdout.txt"
    stderrPath := A_Temp "\LabStation-" . A_TickCount . "-stderr.txt"
    try FileDelete(stdoutPath)
    try FileDelete(stderrPath)
    wrapped := Format('cmd /c "{1} > \"{2}\" 2> \"{3}\""', command, stdoutPath, stderrPath)
    exitCode := RunWait(wrapped, , "Hide")
    stdout := ""
    stderr := ""
    try stdout := FileRead(stdoutPath, "UTF-8")
    catch
        stdout := ""
    try stderr := FileRead(stderrPath, "UTF-8")
    catch
        stderr := ""
    try FileDelete(stdoutPath)
    try FileDelete(stderrPath)
    return Map("exitCode", exitCode, "stdout", stdout, "stderr", stderr)
}
