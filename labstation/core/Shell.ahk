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

    command := Format('"{1}" -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{2}"', LS_GetPowerShellPath(), tempScript)
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
    command := Format('"{1}" -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{2}"', LS_GetPowerShellPath(), tempScript)
    capture := LS_RunCommandCapture(command, description)
    try FileDelete(tempScript)
    return capture
}

LS_GetPowerShellPath() {
    sysnative := A_WinDir "\Sysnative\WindowsPowerShell\v1.0\powershell.exe"
    system32 := A_WinDir "\System32\WindowsPowerShell\v1.0\powershell.exe"
    if (FileExist(sysnative))
        return sysnative
    if (FileExist(system32))
        return system32
    return "powershell.exe"
}

LS_RunCommand(command, description := "command") {
    LS_LogInfo("Executing command - " . description)
    return RunWait(command, , "Hide")
}

LS_RunCommandCapture(command, description := "command", timeoutMs := 15000) {
    LS_LogInfo("Capturing command output - " . description)
    stdoutPath := A_Temp "\LabStation-" . A_TickCount . "-stdout.txt"
    stderrPath := A_Temp "\LabStation-" . A_TickCount . "-stderr.txt"
    exitPath := A_Temp "\LabStation-" . A_TickCount . "-exit.txt"
    batchPath := A_Temp "\LabStation-" . A_TickCount . "-capture.cmd"
    try FileDelete(stdoutPath)
    try FileDelete(stderrPath)
    try FileDelete(exitPath)
    try FileDelete(batchPath)
    try {
        batch := "@echo off`r`n"
            . command . " > " . LS_CmdQuote(stdoutPath) . " 2> " . LS_CmdQuote(stderrPath) . "`r`n"
            . "set LABSTATION_EXIT=%ERRORLEVEL%`r`n"
            . "echo %LABSTATION_EXIT% > " . LS_CmdQuote(exitPath) . "`r`n"
            . "exit /b %LABSTATION_EXIT%`r`n"
        FileAppend(batch, batchPath, "CP0")
    } catch as e {
        LS_LogError("Cannot write temporary command wrapper: " . e.Message)
        return Map("exitCode", -1, "stdout", "", "stderr", e.Message)
    }
    wrapped := Format('"{1}" /d /s /c ""{2}""', A_ComSpec, batchPath)
    exitCode := -1
    timedOut := false
    try {
        Run(wrapped, , "Hide", &pid)
        deadline := A_TickCount + timeoutMs
        while ProcessExist(pid) {
            if (A_TickCount >= deadline) {
                timedOut := true
                LS_LogWarning("Command timed out after " . timeoutMs . "ms - " . description)
                try RunWait(Format('taskkill /PID {1} /T /F', pid), , "Hide")
                break
            }
            Sleep 100
        }
        if (!timedOut) {
            try exitCode := Trim(FileRead(exitPath, "UTF-8")) + 0
            catch
                exitCode := 0
        }
    } catch as e {
        LS_LogError("Command failed to launch - " . description . ": " . e.Message)
        exitCode := -1
    }
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
    try FileDelete(exitPath)
    try FileDelete(batchPath)
    if (timedOut) {
        stderr := (stderr != "" ? stderr . "`n" : "") . "Command timed out after " . timeoutMs . "ms"
        exitCode := 124
    }
    return Map("exitCode", exitCode, "stdout", stdout, "stderr", stderr)
}

LS_CmdQuote(value) {
    return '"' . StrReplace(value, '"', '""') . '"'
}
