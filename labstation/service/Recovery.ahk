; ============================================================================
; Lab Station - Safeguard recovery helpers
; ============================================================================
#Requires AutoHotkey v2.0
#Include ..\core\Config.ahk
#Include ..\core\Logger.ahk
#Include ..\core\Json.ahk
#Include ..\diagnostics\Status.ahk
#Include ServiceState.ahk
#Include SessionManager.ahk

class LS_Recovery {
    static RebootIfNeeded(options := Map()) {
        LS_LogInfo("Recovery: evaluating safeguard reboot request")
        status := LS_Status.Collect()
        reasons := this.ResolveReasons(status, options)
        if (reasons.Length = 0) {
            message := "Healthy state detected; reboot skipped"
            LS_LogInfo("Recovery: " . message)
            LS_ServiceState.RecordSafeguardReboot(false, Map("reason", "healthy", "message", message, "success", true))
            return Map("rebooted", false, "reason", "healthy", "message", message, "success", true, "skipped", true)
        }

        timeout := options.Has("timeout") ? options["timeout"] : 20
        user := options.Has("user") ? options["user"] : ""
        LS_SessionManager.CloseControllerProcesses()
        LS_SessionManager.LogoffLabUser(user)
        rebooted := LS_SessionManager.TriggerReboot(timeout)
        joinedReasons := LS_StrJoin(reasons, ", ")
        message := rebooted
            ? Format("Safeguard reboot scheduled ({1})", joinedReasons)
            : "Unable to schedule safeguard reboot"
        if (rebooted) {
            LS_LogWarning("Recovery: " . message)
        } else {
            LS_LogError("Recovery: reboot scheduling failed")
        }
        issuesText := status["summary"]["issues"].Length > 0 ? LS_StrJoin(status["summary"]["issues"], "; ") : ""
        LS_ServiceState.RecordSafeguardReboot(rebooted, Map(
            "reason", joinedReasons,
            "issues", issuesText,
            "message", message,
            "success", rebooted
        ))
        return Map("rebooted", rebooted, "reason", joinedReasons, "message", message, "success", rebooted)
    }

    static ResolveReasons(status, options) {
        reasons := []
        if (options.Has("force") && options["force"]) {
            reasons.Push("forced-by-backend")
            return reasons
        }
        if (options.Has("reason") && options["reason"] != "")
            reasons.Push(options["reason"])
        summary := status["summary"]
        if (summary.Has("state") && summary["state"] != "ready")
            reasons.Push("status-needs-action")
        if (status.Has("sessions") && status["sessions"]["hasOtherUsers"])
            reasons.Push("other-users-active")
        if (!status["remoteAppEnabled"])
            reasons.Push("remoteapp-disabled")
        if (!status["autoStartConfigured"])
            reasons.Push("autostart-missing")
        policy := status.Has("policy") ? status["policy"] : Map()
        if (policy.Has("autoLogon") && !policy["autoLogon"]["enabled"])
            reasons.Push("autologon-disabled")
        if (policy.Has("remoteDesktopUsers")) {
            rds := policy["remoteDesktopUsers"]
            if (rds.Has("otherMembers") && rds["otherMembers"].Length > 0)
                reasons.Push("remote-desktop-users-drift")
        }
        return this.DistinctReasons(reasons)
    }

    static DistinctReasons(reasons) {
        unique := Map()
        cleaned := []
        for reason in reasons {
            key := StrLower(reason)
            if (key = "")
                continue
            if (!unique.Has(key)) {
                unique[key] := true
                cleaned.Push(reason)
            }
        }
        return cleaned
    }
}
