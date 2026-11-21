; ============================================================================
; Lab Station - Shared structured logging helpers
; ============================================================================
#Requires AutoHotkey v2.0
#Include Config.ahk
#Include Json.ahk

global LAB_STATION_LOG_LEVEL := "INFO"
try {
    configuredLogLevel := StrUpper(Trim(EnvGet("LABSTATION_LOG_LEVEL")))
    if (configuredLogLevel != "")
        LAB_STATION_LOG_LEVEL := configuredLogLevel
}

global LAB_STATION_LOG_RETENTION_DAYS := 180
global LAB_STATION_LOG_SUMMARY_INTERVAL_MS := 300000
global LAB_STATION_LOG_WARNING_INTERVAL_MS := 300000

LS_Log(message, level := "INFO") {
    LS_LogEvent("station-message", message, level)
}

LS_LogInfo(message) {
    LS_Log(message, "INFO")
}

LS_LogDebug(message) {
    LS_Log(message, "DEBUG")
}

LS_LogWarning(message) {
    LS_Log(message, "WARNING")
}

LS_LogError(message) {
    LS_Log(message, "ERROR")
}

LS_LogEvent(event, message, level := "INFO", details := "") {
    global LAB_STATION_LOG, LAB_STATION_LOG_LEVEL
    global LAB_STATION_LOG_WARNING_INTERVAL_MS
    static warningState := Map()

    level := StrUpper(level)
    if (!LS_LogLevelEnabled(level, LAB_STATION_LOG_LEVEL))
        return false

    if (!IsObject(details))
        details := Map()
    if (level = "WARNING") {
        key := event . "`n" . message
        nowTick := A_TickCount
        if (warningState.Has(key)) {
            state := warningState[key]
            if (LS_LogElapsedMs(state["lastTick"], nowTick) < LAB_STATION_LOG_WARNING_INTERVAL_MS) {
                state["suppressed"] += 1
                warningState[key] := state
                return false
            }
            if (state["suppressed"] > 0) {
                details := LS_LogCopyMap(details)
                details["repeatedEvent"] := event
                details["originalMessage"] := message
                details["repeatCount"] := state["suppressed"] + 1
                message := Format("Repeated warning {1} {2} times in the last five minutes", event, state["suppressed"] + 1)
                event := "warning-repeat-summary"
            }
        }
        warningState[key] := Map("lastTick", nowTick, "suppressed", 0)
    }

    profile := "unknown"
    try profile := StrLower(Trim(IniRead(LAB_STATION_PROFILE_FILE, "Station", "Profile", "unknown")))
    if (profile = "")
        profile := "unknown"
    else if (profile = "server")
        profile := "dedicated"

    record := Map(
        "schemaVersion", 1,
        "timestamp", FormatTime(A_NowUTC, "yyyy-MM-ddTHH:mm:ssZ"),
        "level", level,
        "event", event,
        "message", message,
        "platform", "windows",
        "host", A_ComputerName,
        "profile", profile,
        "details", details
    )
    line := LS_ToJson(record) . "`n"

    SplitPath(LAB_STATION_LOG, &fileName, &directory)
    if (directory = "")
        directory := A_WorkingDir
    try {
        if (!DirExist(directory))
            DirCreate(directory)
    } catch {
        return false
    }

    lockHandle := LS_AcquireLogLock(LAB_STATION_LOG . ".lock")
    try {
        if (lockHandle) {
            if (!LS_MaintainLogFile())
                return false
            FileAppend(line, LAB_STATION_LOG, "UTF-8-RAW")
            LS_PruneLogArchives()
        } else {
            ; Skipping a rare event is safer than racing a cross-process rotation.
            return false
        }
        OutputDebug("LabStation - " . line)
        return true
    } catch {
        ; Logging failures must never interrupt a station operation.
        return false
    } finally {
        if (lockHandle)
            DllCall("CloseHandle", "Ptr", lockHandle)
    }
}

LS_LogStatusSummary(status) {
    global LAB_STATION_LOG_SUMMARY_INTERVAL_MS
    static lastLoggedTick := 0
    static lastState := ""

    if (!IsObject(status) || !status.Has("summary") || !IsObject(status["summary"]))
        return false

    summary := status["summary"]
    ready := summary.Has("ready")
        ? summary["ready"]
        : (summary.Has("state") && StrLower(Trim(summary["state"])) = "ready")
    readiness := ready ? "ready" : "not-ready"
    nowTick := A_TickCount
    shouldLog := lastLoggedTick = 0
        || readiness != lastState
        || LS_LogElapsedMs(lastLoggedTick, nowTick) >= LAB_STATION_LOG_SUMMARY_INTERVAL_MS
    if (!shouldLog)
        return false

    lastLoggedTick := nowTick
    lastState := readiness
    details := Map("ready", ready)
    LS_LogEvent("station-status-summary", "Station status summary", "INFO", details)
    return true
}

LS_LogLevelEnabled(level, configuredLevel) {
    configuredLevel := StrUpper(Trim(configuredLevel))
    if (configuredLevel = "")
        configuredLevel := "INFO"
    ranks := Map("DEBUG", 10, "INFO", 20, "WARNING", 30, "ERROR", 40)
    if (!ranks.Has(configuredLevel))
        configuredLevel := "INFO"
    return ranks.Has(level) && ranks[level] >= ranks[configuredLevel]
}

LS_LogElapsedMs(startTick, endTick) {
    elapsed := endTick - startTick
    return elapsed < 0 ? elapsed + 4294967296 : elapsed
}

LS_LogCopyMap(source) {
    copied := Map()
    for key, value in source
        copied[key] := value
    return copied
}

LS_AcquireLogLock(path) {
    loop 1200 {
        handle := DllCall(
            "CreateFileW",
            "WStr", path,
            "UInt", 0xC0000000,
            "UInt", 0,
            "Ptr", 0,
            "UInt", 4,
            "UInt", 0x80,
            "Ptr", 0,
            "Ptr"
        )
        if (handle != -1)
            return handle
        if (A_LastError != 32 && A_LastError != 33)
            return 0
        Sleep(50)
    }
    return 0
}

LS_MaintainLogFile() {
    global LAB_STATION_LOG
    SplitPath(LAB_STATION_LOG, &fileName, &directory, &extension, &baseName)
    if (directory = "")
        directory := A_WorkingDir
    if (!DirExist(directory))
        return false
    if (!FileExist(LAB_STATION_LOG))
        return true
    if (FileGetSize(LAB_STATION_LOG) = 0)
        return true

    modified := FileGetTime(LAB_STATION_LOG, "M")
    currentDay := FormatTime(A_Now, "yyyyMMdd")
    modifiedDay := SubStr(modified, 1, 8)
    currentSchema := LS_LogHasCurrentSchema(LAB_STATION_LOG)
    if (modifiedDay = currentDay && currentSchema)
        return true

    prefix := baseName . (currentSchema ? "-" : "-legacy-") . modifiedDay
    archivePath := LS_UniqueArchivePath(directory, prefix)
    try FileMove(LAB_STATION_LOG, archivePath)
    catch
        return false
    LS_CompressLogArchive(archivePath)
    return true
}

LS_LogHasCurrentSchema(path) {
    try {
        file := FileOpen(path, "r", "UTF-8")
        if (!IsObject(file))
            return false
        line := file.ReadLine()
        file.Close()
        return InStr(line, '"schemaVersion":1') > 0
    } catch {
        return false
    }
}

LS_UniqueArchivePath(directory, prefix) {
    candidate := directory . "\" . prefix . ".log"
    if (!FileExist(candidate) && !FileExist(candidate . ".gz"))
        return candidate
    suffix := 2
    loop {
        candidate := directory . "\" . prefix . "-" . suffix . ".log"
        if (!FileExist(candidate) && !FileExist(candidate . ".gz"))
            return candidate
        suffix += 1
    }
}

LS_CompressLogArchive(path) {
    compressedPath := path . ".gz"
    if (FileExist(compressedPath))
        return false
    escapedSource := StrReplace(path, "'", "''")
    escapedTarget := StrReplace(compressedPath, "'", "''")
    scriptPath := A_Temp . "\LabStation-Gzip-" . A_TickCount . "-" . Random(1000, 9999) . ".ps1"
    script := "$ErrorActionPreference = 'Stop'`n"
        . "Add-Type -AssemblyName System.IO.Compression`n"
        . "$inputStream = [System.IO.File]::OpenRead('" . escapedSource . "')`n"
        . "$outputStream = [System.IO.File]::Create('" . escapedTarget . "')`n"
        . "$gzipStream = [System.IO.Compression.GZipStream]::new($outputStream, [System.IO.Compression.CompressionMode]::Compress)`n"
        . "try { $inputStream.CopyTo($gzipStream) } finally { $gzipStream.Dispose(); $inputStream.Dispose(); $outputStream.Dispose() }`n"
    try {
        FileAppend(script, scriptPath, "UTF-8-RAW")
        powershellPath := LS_LogGetPowerShellPath()
        command := Format('"{1}" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{2}"', powershellPath, scriptPath)
        exitCode := RunWait(command, , "Hide")
        if (exitCode = 0 && FileExist(compressedPath) && FileGetSize(compressedPath) > 0) {
            FileDelete(path)
            return true
        }
    } catch {
    } finally {
        try FileDelete(scriptPath)
    }
    return false
}

LS_LogGetPowerShellPath() {
    sysnative := A_WinDir . "\Sysnative\WindowsPowerShell\v1.0\powershell.exe"
    system32 := A_WinDir . "\System32\WindowsPowerShell\v1.0\powershell.exe"
    if (FileExist(sysnative))
        return sysnative
    if (FileExist(system32))
        return system32
    return "powershell.exe"
}

LS_PruneLogArchives() {
    global LAB_STATION_LOG, LAB_STATION_LOG_RETENTION_DAYS
    static lastPruneKey := ""
    SplitPath(LAB_STATION_LOG, &fileName, &directory, &extension, &baseName)
    if (directory = "")
        directory := A_WorkingDir
    today := FormatTime(A_Now, "yyyyMMdd")
    pruneKey := LAB_STATION_LOG . "|" . today
    if (lastPruneKey = pruneKey)
        return

    cutoff := FormatTime(DateAdd(A_Now, -LAB_STATION_LOG_RETENTION_DAYS, "Days"), "yyyyMMddHHmmss")
    prefix := baseName . "-"
    Loop Files, directory . "\" . prefix . "*.log*", "F" {
        name := A_LoopFileName
        suffix := SubStr(name, StrLen(prefix) + 1)
        if (SubStr(suffix, 1, 7) = "legacy-")
            suffix := SubStr(suffix, 8)
        date := SubStr(suffix, 1, 8)
        if (!RegExMatch(date, "^\d{8}$"))
            continue
        if (Integer(date . "000000") < Integer(cutoff)) {
            try FileDelete(A_LoopFileFullPath)
        }
    }
    lastPruneKey := pruneKey
}
