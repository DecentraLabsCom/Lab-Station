; ============================================================================
; Lab Station - Connector registry
; ============================================================================
#Requires AutoHotkey v2.0
#Include ..\core\Config.ahk
#Include ..\service\FmuExecutor.ahk

class LS_ConnectorRegistry {
    static List() {
        return [
            this.Fmi(),
            this.GuacamoleApp(),
            this.Planned("opc-ua", "OPC-UA", "Industrial equipment connector"),
            this.Planned("tango", "TANGO", "Scientific control systems connector")
        ]
    }

    static Get(id) {
        for connector in this.List() {
            if (connector["id"] = id)
                return connector
        }
        return this.Fmi()
    }

    static Fmi() {
        status := LS_FmuExecutor.GetHealthSummary()
        health := status.Has("lastHealth") && IsObject(status["lastHealth"]) ? status["lastHealth"] : Map()
        available := status.Has("available") && status["available"]
        running := status.Has("running") && status["running"]
        fmuCount := health.Has("fmuCount") ? health["fmuCount"] : ""
        state := !available ? "missing" : (running ? "running" : "stopped")
        details := []
        details.Push("Station endpoint: http://" . A_ComputerName . ":" . LAB_STATION_FMU_EXECUTOR_PORT)
        details.Push("FMU folder: " . LS_ConnectorRegistry.FmiRoot())
        details.Push("Port: " . LAB_STATION_FMU_EXECUTOR_PORT)
        details.Push("Internal token: " . (status.Has("tokenConfigured") && status["tokenConfigured"] ? "configured" : "MISSING"))
        if (fmuCount != "")
            details.Push("FMUs detected: " . fmuCount)
        details.Push("Gateway mode: FMU_BACKEND_MODE=station")

        return Map(
            "id", "fmi",
            "label", "FMI / FMU",
            "summary", "Serve FMI/FMU simulations from this Lab Station.",
            "state", state,
            "enabled", available,
            "planned", false,
            "details", details,
            "gatewayConfig", this.FmiGatewayConfig(),
            "actions", ["start", "stop", "restart", "open-folder", "copy-config"]
        )
    }

    static GuacamoleApp() {
        appControl := LS_ConnectorRegistry.AppControlPath()
        available := appControl != ""
        details := []
        details.Push("Controller path: " . (available ? appControl : "Not found"))
        details.Push("Autostart target: " . LAB_STATION_CONTROLLER_DIR)
        details.Push("RemoteApp and LABUSER readiness remain part of Station diagnosis.")
        return Map(
            "id", "guacamole-app",
            "label", "Guacamole App",
            "summary", "Local lab application launched inside remote Guacamole/RDP sessions.",
            "state", available ? "available" : "missing",
            "enabled", available,
            "planned", false,
            "details", details,
            "gatewayConfig", "",
            "actions", ["open-folder"]
        )
    }

    static Planned(id, label, summary) {
        return Map(
            "id", id,
            "label", label,
            "summary", summary,
            "state", "planned",
            "enabled", false,
            "planned", true,
            "details", ["Connector surface reserved for future integration."],
            "gatewayConfig", "",
            "actions", []
        )
    }

    static FmiRoot() {
        return LAB_STATION_PROJECT_ROOT "\fmu-executor\fmu-data"
    }

    static FmiGatewayConfig() {
        return "FMU_BACKEND_MODE=station`r`n"
            . "FMU_STATION_BASE_URL=http://<station-ip>:" . LAB_STATION_FMU_EXECUTOR_PORT . "`r`n"
            . "FMU_STATION_INTERNAL_TOKEN=<same-as-FMU_INTERNAL_TOKEN>"
    }

    static AppControlPath() {
        exe := LAB_STATION_CONTROLLER_DIR "\AppControl.exe"
        if (FileExist(exe))
            return exe
        script := LAB_STATION_CONTROLLER_DIR "\AppControl.ahk"
        if (FileExist(script))
            return script
        return ""
    }

    static Start(id) {
        if (id = "fmi")
            return LS_FmuExecutor.Start()
        return false
    }

    static Stop(id) {
        if (id = "fmi")
            return LS_FmuExecutor.Stop()
        return false
    }

    static Restart(id) {
        if (id = "fmi")
            return LS_FmuExecutor.Restart()
        return false
    }

    static OpenFolder(id) {
        target := ""
        if (id = "fmi")
            target := this.FmiRoot()
        else if (id = "guacamole-app")
            target := LAB_STATION_CONTROLLER_DIR
        if (target = "")
            return false
        try {
            if (!DirExist(target))
                DirCreate(target)
            Run Format('explorer.exe "{1}"', target)
            return true
        } catch {
            return false
        }
    }

    static CopyGatewayConfig(id) {
        if (id != "fmi")
            return false
        A_Clipboard := this.FmiGatewayConfig()
        return true
    }
}
