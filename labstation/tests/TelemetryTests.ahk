#Requires AutoHotkey v2.0
#Include TestSupport.ahk
#Include ..\service\Telemetry.ahk
#Include ParityTestSupport.ahk

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
        TestV3EnvelopeHasPortableRequiredFields()
        TestPublishWritesPrimaryAndLegacyHeartbeats()
        TestBuildPayloadFallsBackToServiceStateOperations()
        TestPublishReportsPrimaryWriteFailure()
        TestPublishReportsLegacyWriteFailure()
    } catch as err {
        LS_TestFail("Unhandled telemetry test exception: " . err.Message)
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

    LS_TestAssert(payload["schemaVersion"] = LAB_STATION_SCHEMA_VERSION, "heartbeat uses the configured schema version")
    LS_TestAssert(payload["version"] = LAB_STATION_VERSION, "heartbeat includes the station version")
    LS_TestAssert(payload["remoteAppEnabled"], "heartbeat mirrors RemoteApp state at the top level")
    LS_TestAssert(!payload["legacyAppControlAutostart"], "heartbeat reports no legacy AppControl autostart")
    LS_TestAssert(!payload.Has("autoStartConfigured"), "heartbeat no longer publishes AppControl autostart state")
    LS_TestAssert(payload["summary"]["state"] = "ready", "heartbeat mirrors the status summary")
    LS_TestAssert(payload["operations"]["lastPowerAction"]["mode"] = "shutdown", "heartbeat carries operation history")
    LS_TestAssert(payload["status"]["localSessionActive"] = false, "heartbeat embeds the full status snapshot")
    LS_TestAssert(payload["platform"]["os"] = "windows", "heartbeat publishes the neutral v3 platform field")
    LS_TestAssert(payload["management"]["transport"] = "winrm", "heartbeat publishes management transport")
    LS_TestAssert(payload["status"]["version"] = LAB_STATION_VERSION, "nested status is a complete v3 document")
}

TestV3EnvelopeHasPortableRequiredFields() {
    status := SampleStatus(Map())
    payload := LS_Telemetry.BuildPayload(status)
    matrix := LS_TestLoadParityMatrix()
    contract := matrix["portableStatus"]
    required := contract["requiredFields"]
    windowsPlatform := matrix["platforms"]["windows"]

    for _, key in required
        LS_TestAssert(payload.Has(key), "Station Contract v3 heartbeat contains " . key)

    LS_TestAssert(payload["schemaVersion"] = contract["schemaVersion"], "heartbeat advertises the shared contract version")
    LS_TestAssert(LS_TestArrayContains(contract["profiles"], payload["profile"]), "profile uses a shared contract value")
    LS_TestAssert(LS_TestArrayContains(contract["summaryStates"], payload["summary"]["state"]), "summary state uses a shared contract value")
    LS_TestAssert(payload["platform"]["os"] = windowsPlatform["os"], "platform identifies the Windows implementation")
    LS_TestAssert(payload["management"]["transport"] = windowsPlatform["managementTransport"], "Windows management transport stays explicit")
    LS_TestAssert(Type(payload["sessions"]["active"]) = "Array", "active session projection is always an array")
    LS_TestAssert(Type(payload["sessions"]["localSessionActive"]) = "Integer", "local-session activity serializes as a JSON boolean")
    for _, capability in contract["readinessCapabilities"]
        LS_TestAssert(payload["readiness"].Has(capability), capability . " readiness is portable")
    for _, session in payload["sessions"]["active"] {
        for _, key in contract["sessionRequiredFields"]
            LS_TestAssert(session.Has(key), "active session contains shared field " . key)
        LS_TestAssert(LS_TestArrayContains(contract["sessionKinds"], session["kind"]), "active session kind uses a shared contract value")
        LS_TestAssert(Type(session["active"]) = "Integer", "active session state serializes as a JSON boolean")
        LS_TestAssert(Type(session["evictable"]) = "Integer", "session eviction state serializes as a JSON boolean")
    }
    LS_TestAssert(payload["status"] = status, "heartbeat embeds the source status snapshot")
}

TestPublishWritesPrimaryAndLegacyHeartbeats() {
    status := SampleStatus(Map("lastReleaseSession", Map("success", true, "user", "LABUSER")))

    result := LS_Telemetry.Publish(status)

    LS_TestAssert(result, "telemetry publish succeeds for valid heartbeat destinations")
    LS_TestAssert(FileExist(LAB_STATION_HEARTBEAT_FILE), "telemetry writes the primary heartbeat")
    LS_TestAssert(FileExist(LAB_STATION_LEGACY_HEARTBEAT_FILE), "telemetry writes the legacy heartbeat")
    primary := LS_ParseJson(FileRead(LAB_STATION_HEARTBEAT_FILE, "UTF-8"))
    legacy := LS_ParseJson(FileRead(LAB_STATION_LEGACY_HEARTBEAT_FILE, "UTF-8"))
    LS_TestAssert(primary["status"]["operations"]["lastReleaseSession"]["success"], "primary heartbeat contains operation data")
    LS_TestAssert(legacy["status"]["localModeEnabled"] = false, "legacy heartbeat preserves the status snapshot")
}

TestBuildPayloadFallsBackToServiceStateOperations() {
    IniWrite("1", LAB_STATION_SERVICE_STATE_FILE, "prepare-session", "success")
    IniWrite("LABUSER", LAB_STATION_SERVICE_STATE_FILE, "prepare-session", "user")
    status := SampleStatus()
    status.Delete("operations")

    payload := LS_Telemetry.BuildPayload(status)

    LS_TestAssert(payload["operations"]["lastPrepareSession"]["success"], "heartbeat reads prepare status when operations are absent")
    LS_TestAssert(payload["operations"]["lastPrepareSession"]["user"] = "LABUSER", "heartbeat preserves service-state operation metadata")
}

TestPublishReportsPrimaryWriteFailure() {
    global LAB_STATION_HEARTBEAT_FILE
    originalPath := LAB_STATION_HEARTBEAT_FILE
    LAB_STATION_HEARTBEAT_FILE := TEST_ROOT "\invalid|heartbeat.json"

    result := LS_Telemetry.Publish(SampleStatus())

    LAB_STATION_HEARTBEAT_FILE := originalPath
    LS_TestAssert(!result, "telemetry reports failure when the primary heartbeat cannot be written")
}

TestPublishReportsLegacyWriteFailure() {
    global LAB_STATION_LEGACY_HEARTBEAT_FILE
    originalPath := LAB_STATION_LEGACY_HEARTBEAT_FILE
    LAB_STATION_LEGACY_HEARTBEAT_FILE := TEST_ROOT "\legacy|heartbeat.json"

    result := LS_Telemetry.Publish(SampleStatus())

    LAB_STATION_LEGACY_HEARTBEAT_FILE := originalPath
    LS_TestAssert(!result, "telemetry reports failure when the legacy heartbeat cannot be written")
}

SampleStatus(operations := Map()) {
    return Map(
        "schemaVersion", LAB_STATION_SCHEMA_VERSION,
        "timestamp", "2026-08-25T12:00:00Z",
        "host", "LAB-WS-01",
        "version", LAB_STATION_VERSION,
        "profile", "hybrid",
        "platform", Map("os", "windows", "arch", "x86_64", "init", "windows-service"),
        "management", Map("transport", "winrm", "ready", true, "dispatcher", true),
        "remoteAccess", Map("mode", "remote-app", "available", true, "ready", true, "issues", []),
        "stationProfile", "hybrid",
        "identity", Map("labUser", "LABUSER", "agentVersion", LAB_STATION_VERSION, "contractVersion", LAB_STATION_SCHEMA_VERSION),
        "remoteAppEnabled", true,
        "legacyAppControlAutostart", false,
        "wake", Map("armedCount", 1, "programmableCount", 1, "nicPower", []),
        "power", Map("sleepCompliant", true, "hibernateCompliant", true),
        "policy", Map(),
        "readiness", Map(
            "physicalLab", Map("available", true, "ready", true, "issues", []),
            "wake", Map("available", true, "ready", true, "issues", []),
            "fmu", Map("available", false, "ready", false, "issues", [])
        ),
        "summary", Map("state", "ready", "ready", true, "issues", []),
        "operations", operations,
        "sessions", Map("active", [
            Map("id", "42", "user", "LABUSER", "kind", "remote", "active", true, "evictable", true),
            Map("id", "43", "user", "labstation-ops", "kind", "management", "active", true, "evictable", false)
        ], "localSessionActive", false, "queryOk", true),
        "localSessionActive", false,
        "localModeEnabled", false
    )
}
