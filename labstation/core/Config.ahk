; ============================================================================
; Lab Station - Core Configuration
; ============================================================================
#Requires AutoHotkey v2.0

if (!IsSet(LAB_STATION_VERSION)) {
    global LAB_STATION_VERSION := "3.1.0"
}

if (!IsSet(LAB_STATION_SCHEMA_VERSION)) {
    ; Version of the telemetry/status JSON contract (heartbeat/status.json).
    global LAB_STATION_SCHEMA_VERSION := "1.0.0"
}

if (!IsSet(LAB_STATION_ROOT)) {
    ; Source scripts live inside labstation/. Compiled releases are placed at
    ; the project root, but Gateway's operational contract uses the same
    ; labstation/data layout for telemetry, flags, and queued commands.
    if (A_IsCompiled) {
        global LAB_STATION_PROJECT_ROOT := A_ScriptDir
        global LAB_STATION_ROOT := NormalizePath(A_ScriptDir "\labstation")
    } else {
        global LAB_STATION_ROOT := A_ScriptDir
        global LAB_STATION_PROJECT_ROOT := NormalizePath(A_ScriptDir "\..")
    }
}

if (!IsSet(LAB_STATION_PROJECT_ROOT)) {
    global LAB_STATION_PROJECT_ROOT := NormalizePath(LAB_STATION_ROOT "\..")
}

if (!IsSet(LAB_STATION_LEGACY_DATA_DIR)) {
    ; Older compiled releases wrote data directly below the executable. Keep
    ; the path available for one-way telemetry migration without making it
    ; the active Gateway contract.
    global LAB_STATION_LEGACY_DATA_DIR := A_IsCompiled ? LAB_STATION_PROJECT_ROOT "\data" : ""
}

if (!IsSet(LAB_STATION_CONTROLLER_DIR)) {
    global LAB_STATION_CONTROLLER_DIR := LAB_STATION_PROJECT_ROOT "\controller"
}

if (!DirExist(LAB_STATION_CONTROLLER_DIR)) {
    candidates := [
        LAB_STATION_PROJECT_ROOT,
        LAB_STATION_ROOT,
        LAB_STATION_PROJECT_ROOT "\dist"
    ]
    for candidate in candidates {
        if (FileExist(candidate "\AppControl.exe") || FileExist(candidate "\AppControl.ahk")) {
            LAB_STATION_CONTROLLER_DIR := candidate
            break
        }
    }
}

if (!IsSet(LAB_STATION_LOG)) {
    global LAB_STATION_LOG := LAB_STATION_ROOT "\labstation.log"
}

if (!IsSet(LAB_STATION_DATA_DIR)) {
    global LAB_STATION_DATA_DIR := LAB_STATION_ROOT "\data"
    EnsureDir(LAB_STATION_DATA_DIR)
}

if (!IsSet(LAB_STATION_STATUS_FILE)) {
    global LAB_STATION_STATUS_FILE := LAB_STATION_DATA_DIR "\status.json"
}

if (!IsSet(LAB_STATION_COMMAND_DIR)) {
    global LAB_STATION_COMMAND_DIR := LAB_STATION_DATA_DIR "\commands"
    EnsureDir(LAB_STATION_COMMAND_DIR)
}

if (!IsSet(LAB_STATION_COMMAND_INBOX)) {
    global LAB_STATION_COMMAND_INBOX := LAB_STATION_COMMAND_DIR "\inbox"
    EnsureDir(LAB_STATION_COMMAND_INBOX)
}

if (!IsSet(LAB_STATION_COMMAND_PROCESSED_DIR)) {
    global LAB_STATION_COMMAND_PROCESSED_DIR := LAB_STATION_COMMAND_DIR "\processed"
    EnsureDir(LAB_STATION_COMMAND_PROCESSED_DIR)
}

if (!IsSet(LAB_STATION_COMMAND_RESULTS_DIR)) {
    global LAB_STATION_COMMAND_RESULTS_DIR := LAB_STATION_COMMAND_DIR "\results"
    EnsureDir(LAB_STATION_COMMAND_RESULTS_DIR)
}

if (!IsSet(LAB_STATION_TELEMETRY_DIR)) {
    global LAB_STATION_TELEMETRY_DIR := LAB_STATION_DATA_DIR "\telemetry"
    EnsureDir(LAB_STATION_TELEMETRY_DIR)
}

if (!IsSet(LAB_STATION_HEARTBEAT_FILE)) {
    global LAB_STATION_HEARTBEAT_FILE := LAB_STATION_TELEMETRY_DIR "\heartbeat.json"
}

if (!IsSet(LAB_STATION_SERVICE_STATE_FILE)) {
    global LAB_STATION_SERVICE_STATE_FILE := LAB_STATION_DATA_DIR "\service-state.ini"
}

if (!IsSet(LAB_STATION_LOCAL_MODE_FLAG)) {
    global LAB_STATION_LOCAL_MODE_FLAG := LAB_STATION_DATA_DIR "\local-mode.flag"
}

if (!IsSet(LAB_STATION_PROFILE_FILE)) {
    global LAB_STATION_PROFILE_FILE := LAB_STATION_DATA_DIR "\station-profile.ini"
}

if (!IsSet(LAB_STATION_SESSION_AUDIT_FILE)) {
    global LAB_STATION_SESSION_AUDIT_FILE := LAB_STATION_TELEMETRY_DIR "\session-guard-events.jsonl"
}

if (!IsSet(LAB_STATION_LEGACY_STATUS_FILE)) {
    global LAB_STATION_LEGACY_STATUS_FILE := LAB_STATION_LEGACY_DATA_DIR != ""
        ? LAB_STATION_LEGACY_DATA_DIR "\status.json"
        : ""
}

if (!IsSet(LAB_STATION_LEGACY_HEARTBEAT_FILE)) {
    global LAB_STATION_LEGACY_HEARTBEAT_FILE := LAB_STATION_LEGACY_DATA_DIR != ""
        ? LAB_STATION_LEGACY_DATA_DIR "\telemetry\heartbeat.json"
        : ""
}

LS_IsHeadlessSession() {
    static initialized := false
    static cached := false
    if (initialized)
        return cached

    station := DllCall("GetProcessWindowStation", "Ptr")
    flags := Buffer(8, 0)
    required := 0
    if (station && DllCall(
        "GetUserObjectInformation",
        "Ptr", station,
        "Int", 2,
        "Ptr", flags,
        "UInt", flags.Size,
        "UInt*", &required
    )) {
        ; WSF_VISIBLE is set for the interactive WinSta0 window station.
        cached := (NumGet(flags, 0, "UInt") & 0x1) = 0
        initialized := true
        return cached
    }

    sessionName := StrLower(Trim(EnvGet("SESSIONNAME")))
    cached := sessionName = "services" || sessionName = "winrm" || sessionName = "ssh"
    initialized := true
    return cached
}

LS_ShowMessage(message, title := "Lab Station", options := "OK") {
    if (LS_IsHeadlessSession()) {
        OutputDebug("LabStation headless result - " . title)
        try FileAppend(message . "`n", "*", "UTF-8")
        return ""
    }
    return MsgBox(message, title, options)
}

EnsureDir(path) {
    try {
        if (!DirExist(path)) {
            DirCreate(path)
        }
    } catch {
    }
}

NormalizePath(path) {
    try {
        resolved := PathGet(path)
        return StrReplace(Trim(resolved), "/", "\")
    } catch {
        return path
    }
}

PathGet(path) {
    return (SubStr(path, 1, 2) = "\\" ? path : FileExist(path) ? (GetFullPathName(path)) : path)
}

GetFullPathName(path) {
    buf := Buffer(32768)
    size := DllCall("GetFullPathName", "str", path, "UInt", buf.Size, "str", buf, "ptr", 0, "UInt")
    if (size = 0 || size > buf.Size) {
        return path
    }
    return StrGet(buf, size)
}
