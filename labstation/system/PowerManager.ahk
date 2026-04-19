; ============================================================================
; Lab Station - Controlled shutdown/hibernate helpers
; ============================================================================
#Requires AutoHotkey v2.0
#Include ..\core\Config.ahk
#Include ..\core\Logger.ahk
#Include ..\core\Shell.ahk
#Include ..\core\Json.ahk
#Include WakeOnLan.ahk
#Include EnergyAudit.ahk
#Include ..\service\ServiceState.ahk

class LS_PowerManager {
    static Shutdown(options := Map()) {
        opts := this.NormalizeOptions(options)
        opts["mode"] := "shutdown"
        return this.Execute(opts)
    }

    static Hibernate(options := Map()) {
        opts := this.NormalizeOptions(options)
        opts["mode"] := "hibernate"
        return this.Execute(opts)
    }

    static NormalizeOptions(options) {
        normalized := Map()
        normalized["delay"] := options.Has("delay") ? Max(0, options["delay"]) : 0
        normalized["force"] := options.Has("force") ? options["force"] : true
        normalized["reason"] := options.Has("reason") ? options["reason"] : ""
        normalized["repairWake"] := options.Has("repairWake") ? options["repairWake"] : true
        normalized["skipWakeCheck"] := options.Has("skipWakeCheck") ? options["skipWakeCheck"] : false
        normalized["failOnWakeIssues"] := options.Has("failOnWakeIssues") ? options["failOnWakeIssues"] : false
        return normalized
    }

    static Execute(options) {
        mode := options["mode"]
        this.LogRequest(mode, options)
        readiness := options["skipWakeCheck"] ? this.ReadinessSkipped() : this.ValidateWakeReadiness()
        if (!readiness["ok"] && options["repairWake"]) {
            LS_LogWarning("Wake readiness issues detected before power action. Reapplying WoL configuration...")
            LS_WakeOnLan.Configure()
            readiness := options["skipWakeCheck"] ? this.ReadinessSkipped() : this.ValidateWakeReadiness()
        }
        if (!readiness["ok"]) {
            msg := "Wake readiness incomplete: " . LS_StrJoin(readiness["issues"], "; ")
            if (options["failOnWakeIssues"]) {
                LS_LogError(msg)
                this.RecordPowerAction(false, mode, options, readiness)
                return false
            }
            LS_LogWarning(msg)
        }
        command := this.BuildCommand(mode, options)
        description := mode = "hibernate" ? "Schedule hibernate" : "Schedule shutdown"
        exitCode := LS_RunCommand(command, description)
        success := (exitCode = 0)
        if (!success)
            LS_LogError(Format("Power action failed (exit={1})", exitCode))
        this.RecordPowerAction(success, mode, options, readiness)
        return success
    }

    static LogRequest(mode, options) {
        details := []
        details.Push("mode=" . mode)
        details.Push("delay=" . options["delay"])
        details.Push("force=" . (options["force"] ? "true" : "false"))
        if (options["reason"] != "")
            details.Push("reason=" . options["reason"])
        LS_LogInfo("Power action requested: " . LS_StrJoin(details, ", "))
    }

    static ValidateWakeReadiness() {
        wake := LS_EnergyAudit.GetWakeDevices()
        nics := LS_EnergyAudit.GetNicPowerManagement()
        issues := []
        if (wake["armedCount"] = 0)
            issues.Push("No wake-armed devices")
        for nic in nics {
            if (!nic.Has("wolReady") || !nic["wolReady"]) {
                label := nic.Has("name") ? nic["name"] : "NIC"
                issues.Push("NIC not WoL ready: " . label)
            }
        }
        return Map("ok", issues.Length = 0, "issues", issues, "wake", wake, "nics", nics)
    }

    static ReadinessSkipped() {
        return Map("ok", true, "issues", [], "wake", Map(), "nics", [])
    }

    static BuildCommand(mode, options) {
        forceFlag := options["force"] ? "/f" : ""
        reason := this.BuildReason(options["reason"])
        if (mode = "shutdown") {
            return Format('shutdown /s /t {1} {2} {3}', options["delay"], forceFlag, reason)
        }
        ; Hibernate ignores /t; emulate delay with timeout if needed
        base := Format('shutdown /h {1} {2}', forceFlag, reason)
        if (options["delay"] > 0) {
            ; Avoid nested quotes that break when reason contains quotes/spaces.
            return Format('cmd /c timeout /t {1} /nobreak >nul & {2}', options["delay"], base)
        }
        return base
    }

    static BuildReason(reason) {
        if (reason = "")
            return ""
        sanitized := StrReplace(reason, '"', "'")
        return Format('/c "{1}"', sanitized)
    }

    static RecordPowerAction(success, mode, options, readiness) {
        details := Map()
        details["success"] := success
        details["mode"] := mode
        details["delay"] := options["delay"]
        details["force"] := options["force"]
        if (options["reason"] != "")
            details["reason"] := options["reason"]
        details["wakeReady"] := readiness["ok"]
        if (readiness["issues"].Length > 0)
            details["wakeIssues"] := LS_StrJoin(readiness["issues"], "; ")
        details["wakeArmed"] := readiness["wake"].Has("armedCount") ? readiness["wake"]["armedCount"] : ""
        LS_ServiceState.RecordPowerAction(details)
    }
}
