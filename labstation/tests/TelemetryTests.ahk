#Requires AutoHotkey v2.0
#Include TestSupport.ahk
#Include ..\service\Telemetry.ahk

global TEST_FAILURES := 0
global TEST_ROOT := A_Temp "\LabStation-TelemetryTests-" A_TickCount
global ORIGINAL_HEARTBEAT_FILE := LAB_STATION_HEARTBEAT_FILE
global ORIGINAL_LEGACY_HEARTBEAT_FILE := LAB_STATION_LEGACY_HEARTBEAT_FILE
global ORIGINAL_STATE_FILE := LAB_STATION_SERVICE_STATE_FILE

DirCreate(TEST_ROOT)
DirCreate(TEST_ROOT "\telemetry")
DirCreate(TEST_ROOT "\legacy")
LAB_STATION_HEARTBEAT_FILE := TEST_ROOT "\telemetry\heartbeat.json"
LAB_STATION_LEGACY_HEARTBEAT_FILE := TEST_ROOT "\legacy\heartbeat.json"
LAB_STATION_SERVICE_STATE_FILE := TEST_ROOT "\service-state.ini"

RunTelemetryTests()

RunTelemetryTests() {
    global ORIGINAL_HEARTBEAT_FILE, ORIGINAL_LEGACY_HEARTBEAT_FILE, ORIGINAL_STATE_FILE
    global LAB_STATION_HEARTBEAT_FILE, LAB_STATION_LEGACY_HEARTBEAT_FILE, LAB_STATION_SERVICE_STATE_FILE, TEST_ROOT

    try {
        TestBuildPayloadMirrorsStatusAndOperations()
        TestPublishWritesPrimaryAndLegacyHeartbeats()
        TestBuildPayloadFallsBackToServiceStateOperations()
        TestPublishReportsPrimaryWriteFailure()
        TestPublishReportsLegacyWriteFailure()
    } catch as err {
        Fail("Unhandled telemetry test exception: " . err.Message)
    }

    LAB_STATION_HEARTBEAT_FILE := ORIGINAL_HEARTBEAT_FILE
    LAB_STATION_LEGACY_HEARTBEAT_FILE := ORIGINAL_LEGACY_HEARTBEAT_FILE
    LAB_STATION_SERVICE_STATE_FILE := ORIGINAL_STATE_FILE
    try DirDelete(TEST_ROOT, true)

    if (TEST_FAILURES > 0) {
        LS_TestOutput("TelemetryTests failed: " . TEST_FAILURES . " failure(s)" . Chr(10))
        ExitApp(1)
    }

    LS_TestOutput("TelemetryTests passed" . Chr(10))
    ExitApp(0)
}

TestBuildPayloadMirrorsStatusAndOperations() {
    operations := Map(
        "lastPrepareSession", Map("success", true, "user", "LABUSER"),
        "lastPowerAction", Map("success", true, "mode", "shutdown")
    )
    status := SampleStatus(operations)

    payload := LS_Telemetry.BuildPayload(status)

    Assert(payload["schemaVersion"] = LAB_STATION_SCHEMA_VERSION, "heartbeat uses the configured schema version")
    Assert(payload["version"] = LAB_STATION_VERSION, "heartbeat includes the station version")
    Assert(payload["remoteAppEnabled"], "heartbeat mirrors RemoteApp state at the top level")
    Assert(payload["autoStartConfigured"], "heartbeat mirrors autostart state at the top level")
    Assert(payload["summary"]["state"] = "ready", "heartbeat mirrors the status summary")
    Assert(payload["operations"]["lastPowerAction"]["mode"] = "shutdown", "heartbeat carries operation history")
    Assert(payload["status"]["localSessionActive"] = false, "heartbeat embeds the full status snapshot")
}

TestPublishWritesPrimaryAndLegacyHeartbeats() {
    status := SampleStatus(Map("lastReleaseSession", Map("success", true, "user", "LABUSER")))

    result := LS_Telemetry.Publish(status)

    Assert(result, "telemetry publish succeeds for valid heartbeat destinations")
    Assert(FileExist(LAB_STATION_HEARTBEAT_FILE), "telemetry writes the primary heartbeat")
    Assert(FileExist(LAB_STATION_LEGACY_HEARTBEAT_FILE), "telemetry writes the legacy heartbeat")
    primary := LS_ParseJson(FileRead(LAB_STATION_HEARTBEAT_FILE, "UTF-8"))
    legacy := LS_ParseJson(FileRead(LAB_STATION_LEGACY_HEARTBEAT_FILE, "UTF-8"))
    Assert(primary["status"]["operations"]["lastReleaseSession"]["success"], "primary heartbeat contains operation data")
    Assert(legacy["status"]["localModeEnabled"] = false, "legacy heartbeat preserves the status snapshot")
}

TestBuildPayloadFallsBackToServiceStateOperations() {
    IniWrite("1", LAB_STATION_SERVICE_STATE_FILE, "prepare-session", "success")
    IniWrite("LABUSER", LAB_STATION_SERVICE_STATE_FILE, "prepare-session", "user")
    status := SampleStatus()
    status.Delete("operations")

    payload := LS_Telemetry.BuildPayload(status)

    Assert(payload["operations"]["lastPrepareSession"]["success"], "heartbeat reads prepare status when operations are absent")
    Assert(payload["operations"]["lastPrepareSession"]["user"] = "LABUSER", "heartbeat preserves service-state operation metadata")
}

TestPublishReportsPrimaryWriteFailure() {
    global LAB_STATION_HEARTBEAT_FILE
    originalPath := LAB_STATION_HEARTBEAT_FILE
    LAB_STATION_HEARTBEAT_FILE := TEST_ROOT "\invalid|heartbeat.json"

    result := LS_Telemetry.Publish(SampleStatus())

    LAB_STATION_HEARTBEAT_FILE := originalPath
    Assert(!result, "telemetry reports failure when the primary heartbeat cannot be written")
}

TestPublishReportsLegacyWriteFailure() {
    global LAB_STATION_LEGACY_HEARTBEAT_FILE
    originalPath := LAB_STATION_LEGACY_HEARTBEAT_FILE
    LAB_STATION_LEGACY_HEARTBEAT_FILE := TEST_ROOT "\legacy|heartbeat.json"

    result := LS_Telemetry.Publish(SampleStatus())

    LAB_STATION_LEGACY_HEARTBEAT_FILE := originalPath
    Assert(!result, "telemetry reports failure when the legacy heartbeat cannot be written")
}

SampleStatus(operations := Map()) {
    return Map(
        "schemaVersion", LAB_STATION_SCHEMA_VERSION,
        "timestamp", "2026-08-25T12:00:00Z",
        "stationProfile", "hybrid",
        "identity", Map("labUser", "LABUSER"),
        "remoteAppEnabled", true,
        "autoStartConfigured", true,
        "wake", Map("armedCount", 1, "programmableCount", 1, "nicPower", []),
        "power", Map("sleepCompliant", true, "hibernateCompliant", true),
        "policy", Map(),
        "sessions", Map("hasOtherUsers", false),
        "summary", Map("state", "ready", "ready", true, "issues", []),
        "operations", operations,
        "localSessionActive", false,
        "localModeEnabled", false
    )
}

Assert(condition, message) {
    if (!condition)
        Fail(message)
}

Fail(message) {
    global TEST_FAILURES
    TEST_FAILURES += 1
    LS_TestOutput(message . Chr(10))
}
