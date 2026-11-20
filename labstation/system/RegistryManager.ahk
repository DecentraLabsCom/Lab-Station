; ============================================================================
; Lab Station - Registry helpers
; ============================================================================
#Requires AutoHotkey v2.0
#Include ..\core\Config.ahk
#Include ..\core\Logger.ahk
#Include ..\core\Admin.ahk
#Include ..\core\Shell.ahk
#Include ..\core\RemoteSessionPolicy.ahk

class LS_RegistryManager {
    static SetRemoteAppPolicy() {
        if (!LS_EnsureAdmin()) {
            return false
        }
        basePath := "HKLM\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services"
        try {
            RegWrite(1, "REG_DWORD", basePath, "fAllowUnlistedRemotePrograms")
            LS_LogInfo("RemoteApp policy 'fAllowUnlistedRemotePrograms' set to 1")
            return true
        } catch as e {
            LS_LogError("Cannot set RemoteApp policy: " . e.Message)
            return false
        }
    }

    static GetRdpDisconnectedSessionLimit() {
        script := "$ErrorActionPreference = 'Stop'`n"
            . "$setting = Get-CimInstance -Namespace 'root/CIMV2/TerminalServices' -ClassName Win32_TSSessionSetting | Where-Object { $_.TerminalName -eq 'RDP-Tcp' } | Select-Object -First 1`n"
            . "if ($null -eq $setting) { throw 'RDP-Tcp session settings were not found' }`n"
            . "$limit = [long]$setting.DisconnectedSessionLimit`n"
            . "$source = [int]$setting.PolicySourceDisconnectedSessionLimit`n"
            . "Write-Output ('RDP_SESSION_LIMIT|' + $limit + '|' + $source)"
        capture := LS_RunPowerShellCapture(script, "Read RDP disconnected-session policy")
        output := Trim(capture["stdout"])
        if (capture["exitCode"] != 0 || !RegExMatch(output, "(?m)^RDP_SESSION_LIMIT\|(\d+)\|([012])$", &match)) {
            detail := LS_CaptureDetail(capture)
            LS_LogWarning("Unable to read the effective RDP disconnected-session limit"
                . (detail != "" ? ": " . detail : ""))
            return Map("available", false, "limitMs", 0, "source", "unknown", "sourceCode", -1,
                "ready", false, "message", "Unable to read effective RDP session settings")
        }

        limitMs := Integer(match[1])
        sourceCode := Integer(match[2])
        source := sourceCode = 0 ? "server" : sourceCode = 1 ? "groupPolicy" : "default"
        return Map(
            "available", true,
            "limitMs", limitMs,
            "source", source,
            "sourceCode", sourceCode,
            "ready", limitMs = LAB_STATION_RDP_DISCONNECTED_LIMIT_MS,
            "message", limitMs = 0 ? "unlimited" : limitMs . " ms"
        )
    }

    static EnsureRdpDisconnectedSessionLimit() {
        if (!LS_EnsureAdmin())
            return false

        current := this.GetRdpDisconnectedSessionLimit()
        if (!current["available"]) {
            LS_LogError("Setup cannot verify the RDP disconnected-session limit")
            MsgBox "Lab Station could not read the effective RDP disconnected-session limit. Setup cannot verify the "
                . LAB_STATION_RDP_DISCONNECTED_SESSION_LIMIT_SECONDS . "-second safety limit that leaves time for AppControl's 120-second reconnect grace, orderly close, and the Gateway retry.`n`nCheck the Lab Station log and the Windows Remote Desktop Session Host settings.", "Lab Station Setup", "OK Iconx"
            return false
        }

        LS_LogInfo("Effective RDP disconnected-session limit before setup: "
            . current["message"] . " (source=" . current["source"] . ")")
        if (current["ready"]) {
            LS_LogInfo("RDP disconnected-session hard limit is already "
                . LAB_STATION_RDP_DISCONNECTED_SESSION_LIMIT_SECONDS . " seconds")
            return true
        }

        if (current["sourceCode"] = 1) {
            LS_LogError("A Group Policy controls the RDP disconnected-session limit ("
                . current["message"] . "); leaving that centrally managed value unchanged")
            MsgBox "A Windows Group Policy currently controls the RDP disconnected-session limit and sets it to "
                . current["message"] . ".`n`nLab Station will not overwrite a centrally managed policy. Configure the controlling policy to set MaxDisconnectionTime to "
                . LAB_STATION_RDP_DISCONNECTED_LIMIT_MS . " ms, then run Setup again.",
                "Lab Station Setup", "OK Iconx"
            return false
        }

        script := "$ErrorActionPreference = 'Stop'`n"
            . "$setting = Get-CimInstance -Namespace 'root/CIMV2/TerminalServices' -ClassName Win32_TSSessionSetting | Where-Object { $_.TerminalName -eq 'RDP-Tcp' } | Select-Object -First 1`n"
            . "if ($null -eq $setting) { throw 'RDP-Tcp session settings were not found' }`n"
            . "$result = Invoke-CimMethod -InputObject $setting -MethodName TimeLimit -Arguments @{ SessionLimitType = 'DisconnectedSessionLimit'; ValueLimit = [uint32]" . LAB_STATION_RDP_DISCONNECTED_LIMIT_MS . " } -ErrorAction Stop`n"
            . "if ($null -eq $result -or $null -eq $result.ReturnValue) { throw 'TimeLimit returned no result code' }`n"
            . "if ([int]$result.ReturnValue -ne 0) { throw ('TimeLimit returned ' + $result.ReturnValue) }`n"
            . "$setting = Get-CimInstance -Namespace 'root/CIMV2/TerminalServices' -ClassName Win32_TSSessionSetting | Where-Object { $_.TerminalName -eq 'RDP-Tcp' } | Select-Object -First 1`n"
            . "Write-Output ('RDP_SESSION_LIMIT|' + [long]$setting.DisconnectedSessionLimit + '|' + [int]$setting.PolicySourceDisconnectedSessionLimit)"
        setCapture := LS_RunPowerShellCapture(script, "Set RDP disconnected-session limit")
        if (setCapture["exitCode"] != 0) {
            detail := LS_CaptureDetail(setCapture)
            LS_LogWarning("Win32_TSSessionSetting did not confirm the RDP disconnected-session limit"
                . (detail != "" ? ": " . detail : ""))
        } else {
            LS_LogInfo("Win32_TSSessionSetting response: " . Trim(setCapture["stdout"]))
        }

        verified := this.GetRdpDisconnectedSessionLimit()
        if (verified["available"] && !verified["ready"] && verified["sourceCode"] != 1) {
            if (this.SetLocalRdpDisconnectedSessionPolicy())
                verified := this.GetRdpDisconnectedSessionLimit()
        }

        if (!verified["available"] || !verified["ready"]) {
            actual := verified["message"] . " (source=" . verified["source"] . ")"
            LS_LogError("RDP disconnected-session limit verification failed after WMI and local policy attempts; Windows reports " . actual)
            MsgBox "Windows still reports " . actual . " after Lab Station attempted to set the disconnected-session limit to "
                . LAB_STATION_RDP_DISCONNECTED_SESSION_LIMIT_SECONDS . " seconds. Setup cannot guarantee the cleanup safety window.`n`nCheck the controlling Group Policy and the Lab Station log for details.", "Lab Station Setup", "OK Iconx"
            return false
        }

        LS_LogInfo("RDP disconnected-session limit set and verified: " . verified["limitMs"] . " ms")
        return true
    }

    static SetLocalRdpDisconnectedSessionPolicy() {
        basePath := "HKLM\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services"
        try {
            RegWrite(LAB_STATION_RDP_DISCONNECTED_LIMIT_MS, "REG_DWORD", basePath, "MaxDisconnectionTime")
            LS_LogWarning("Win32_TSSessionSetting did not apply the RDP disconnected-session limit; wrote the Lab Station local policy fallback")
            return true
        } catch as e {
            LS_LogError("Cannot write the local RDP disconnected-session policy fallback: " . e.Message)
            return false
        }
    }

    static RemoveRunEntry(valueName) {
        if (!LS_EnsureAdmin()) {
            return false
        }
        basePath := "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Run"
        try {
            RegDelete(basePath, valueName)
            LS_LogInfo("Run entry '" . valueName . "' removed")
            return true
        } catch as e {
            ; Removing an already absent migration entry is idempotent.
            try {
                RegRead(basePath, valueName)
                LS_LogError("Cannot remove Run entry '" . valueName . "': " . e.Message)
                return false
            } catch {
                LS_LogInfo("Run entry '" . valueName . "' was already absent")
                return true
            }
        }
    }
}
