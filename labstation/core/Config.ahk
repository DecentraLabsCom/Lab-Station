; ============================================================================
; Lab Station - Core Configuration
; ============================================================================
#Requires AutoHotkey v2.0

if (!IsSet(LAB_STATION_VERSION)) {
    global LAB_STATION_VERSION := "1.0.0-alpha"
}

if (!IsSet(LAB_STATION_SCHEMA_VERSION)) {
    ; Version of the telemetry/status JSON contract (heartbeat/status.json).
    global LAB_STATION_SCHEMA_VERSION := "1.0.0"
}

if (!IsSet(LAB_STATION_ROOT)) {
    ; LabStation scripts live inside the labstation/ folder. Project root is one level up.
    global LAB_STATION_ROOT := A_ScriptDir
    global LAB_STATION_PROJECT_ROOT := NormalizePath(A_ScriptDir "\..")
}

if (!IsSet(LAB_STATION_PROJECT_ROOT)) {
    global LAB_STATION_PROJECT_ROOT := NormalizePath(LAB_STATION_ROOT "\..")
}

if (!IsSet(LAB_STATION_CONTROLLER_DIR)) {
    global LAB_STATION_CONTROLLER_DIR := LAB_STATION_PROJECT_ROOT "\controller"
}

if (!DirExist(LAB_STATION_CONTROLLER_DIR)) {
    potential := LAB_STATION_PROJECT_ROOT
    if (FileExist(potential "\AppControl.exe")) {
        LAB_STATION_CONTROLLER_DIR := potential
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

if (!IsSet(LAB_STATION_SESSION_AUDIT_FILE)) {
    global LAB_STATION_SESSION_AUDIT_FILE := LAB_STATION_TELEMETRY_DIR "\session-guard-events.jsonl"
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
        return StrReplace(Trim(DirExist(path) ? DirExist(path) : PathGet(path)), "//", "\\")
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
