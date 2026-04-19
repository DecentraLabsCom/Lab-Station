; ============================================================================
; Lab Station - Telemetry publication helpers
; ============================================================================
#Requires AutoHotkey v2.0
#Include ..\core\Config.ahk
#Include ..\core\Logger.ahk
#Include ..\core\Json.ahk
#Include ..\diagnostics\Status.ahk
#Include ServiceState.ahk

class LS_Telemetry {
    static Publish(status := "") {
        data := IsObject(status) ? status : LS_Status.Collect()
        payload := this.BuildPayload(data)
        this.WriteHeartbeat(payload)
    }

    static BuildPayload(status) {
        operations := status.Has("operations") ? status["operations"] : LS_ServiceState.GetOperationsSummary()
        payload := Map()
        payload["timestamp"] := FormatTime(A_NowUTC, "yyyy-MM-ddTHH:mm:ssZ")
        payload["schemaVersion"] := LAB_STATION_SCHEMA_VERSION
        payload["host"] := A_ComputerName
        payload["version"] := LAB_STATION_VERSION
        payload["remoteAppEnabled"] := status["remoteAppEnabled"]
        payload["autoStartConfigured"] := status["autoStartConfigured"]
        payload["wake"] := status["wake"]
        payload["summary"] := status["summary"]
        payload["operations"] := operations
        payload["status"] := status
        return payload
    }

    static WriteHeartbeat(payload) {
        try {
            LS_WriteJson(LAB_STATION_HEARTBEAT_FILE, payload)
        } catch as e {
            LS_LogWarning("Unable to write telemetry heartbeat: " . e.Message)
        }
    }
}
