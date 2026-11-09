; ============================================================================
; Lab Station - Gateway-scoped inbound firewall policy
; ============================================================================
#Requires AutoHotkey v2.0
#Include ..\core\Config.ahk
#Include ..\core\Logger.ahk
#Include ..\core\Admin.ahk
#Include ..\core\Shell.ahk
#Include ..\core\Json.ahk

class LS_FirewallManager {
    static RegistryKey := "HKLM\SOFTWARE\DecentraLabs\Lab Station\NetworkAccess"
    static RdpValue := "RdpRemoteAddresses"
    static WinRmValue := "WinRmRemoteAddresses"

    static ConfigureGatewayScopes() {
        if (!LS_EnsureAdmin())
            return false

        rdpDefault := this.ReadConfiguredAddresses(this.RdpValue)
        winrmDefault := this.ReadConfiguredAddresses(this.WinRmValue)
        rdpInput := InputBox(
            "Enter the source IP address(es) or CIDR subnet(s) that Windows sees for Guacamole/guacd RDP traffic. Use commas between entries. Do not enter the browser user's IP.",
            "Gateway firewall scope - RDP",
            "w700 h190",
            rdpDefault
        )
        if (rdpInput.Result != "OK")
            return false

        winrmInput := InputBox(
            "Enter the source IP address(es) or CIDR subnet(s) that Windows sees for Lab Gateway WinRM management traffic. Use commas between entries.",
            "Gateway firewall scope - WinRM",
            "w700 h190",
            winrmDefault
        )
        if (winrmInput.Result != "OK")
            return false

        try {
            rdpAddresses := this.NormalizeAddressList(rdpInput.Value)
            winrmAddresses := this.NormalizeAddressList(winrmInput.Value)
        } catch as e {
            MsgBox(e.Message, "Invalid Gateway firewall scope", "OK Iconx")
            return false
        }

        if (!this.ValidateAddressList(rdpAddresses) || !this.ValidateAddressList(winrmAddresses)) {
            MsgBox("Use valid IPv4 or IPv6 addresses and CIDR subnets only. Prefix lengths must be between 1 and 32 for IPv4, or 1 and 128 for IPv6.", "Invalid Gateway firewall scope", "OK Iconx")
            return false
        }

        try {
            RegWrite(rdpAddresses, "REG_SZ", this.RegistryKey, this.RdpValue)
            RegWrite(winrmAddresses, "REG_SZ", this.RegistryKey, this.WinRmValue)
        } catch as e {
            LS_LogError("Unable to save Gateway firewall scopes: " . e.Message)
            return false
        }

        rdpReady := this.ConfigureRdpFirewall()
        winrmReady := this.ConfigureWinRmFirewall()
        if (!rdpReady || !winrmReady)
            LS_LogError("Gateway firewall scope setup was incomplete; do not enable remote access until both rules are ready")
        return rdpReady && winrmReady
    }

    static ConfigureRdpFirewall() {
        return this.ConfigureScopedRule(
            this.RdpValue,
            "RDP",
            "3389",
            "TermService",
            "LabStation-RDP-Gateway-TCP",
            "Lab Station RDP from Gateway"
        )
    }

    static ConfigureWinRmFirewall() {
        ; Keep the WinRM HTTPS rule scoped by Gateway address and port, but do not
        ; add a Windows service filter: it prevented TCP 5986 from matching on a
        ; deployed Windows Station even though the listener and source scope were correct.
        return this.ConfigureScopedRule(
            this.WinRmValue,
            "WinRM",
            "5986",
            "WinRM",
            "LabStation-WinRM-HTTPS",
            "Lab Station WinRM HTTPS from Gateway",
            false
        )
    }

    static ConfigureScopedRule(valueName, label, port, service, ruleName, displayName, useServiceFilter := true) {
        if (!LS_EnsureAdmin())
            return false
        addresses := this.ReadConfiguredAddresses(valueName)
        if (addresses = "" || !this.ValidateAddressList(addresses)) {
            LS_LogError("No valid Gateway source addresses configured for " . label)
            return false
        }
        addressArray := this.PowerShellAddressArray(addresses)
        serviceFilterArgument := useServiceFilter ? " -Service '" . service . "'" : ""
        expectedServiceFilter := useServiceFilter ? service : "Any"
        script := ""
            . "`$ErrorActionPreference = 'Stop'`n"
            . "`$allowedAddresses = " . addressArray . "`n"
            . "if (`$allowedAddresses.Count -eq 0 -or `$allowedAddresses -contains 'Any') { throw 'Gateway firewall scope is empty or unrestricted' }`n"
            . "Set-NetFirewallProfile -Profile Domain,Private,Public -Enabled True -DefaultInboundAction Block`n"
            . "function Disable-RelatedInboundRules([string]`$LocalPort, [string]`$Service, [string]`$ManagedRuleName) {`n"
            . "  `$rules = @(Get-NetFirewallRule -PolicyStore ActiveStore -Direction Inbound -Action Allow -Enabled True -ErrorAction SilentlyContinue)`n"
            . "  foreach (`$rule in `$rules) {`n"
            . "    if (`$rule.Name -eq `$ManagedRuleName) { continue }`n"
            . "    `$matchesPort = `$false`n"
            . "    `$matchesService = `$false`n"
            . "    foreach (`$portFilter in @(Get-NetFirewallPortFilter -AssociatedNetFirewallRule `$rule -ErrorAction SilentlyContinue)) {`n"
            . "      if (([string]`$portFilter.Protocol -match '(?i)^TCP$|^6$') -and [string]`$portFilter.LocalPort -eq `$LocalPort) { `$matchesPort = `$true }`n"
            . "    }`n"
            . "    foreach (`$serviceFilter in @(Get-NetFirewallServiceFilter -AssociatedNetFirewallRule `$rule -ErrorAction SilentlyContinue)) {`n"
            . "      if ([string]`$serviceFilter.Service -eq `$Service) { `$matchesService = `$true }`n"
            . "    }`n"
            . "    if (`$matchesPort -or `$matchesService) { Disable-NetFirewallRule -InputObject `$rule -ErrorAction Stop }`n"
            . "  }`n"
            . "}`n"
            . "Disable-RelatedInboundRules '" . port . "' '" . service . "' '" . ruleName . "'`n"
            . "if ('" . label . "' -eq 'RDP') { Get-NetFirewallRule -Name 'RemoteDesktop-*' -ErrorAction SilentlyContinue | Disable-NetFirewallRule -ErrorAction Stop | Out-Null }`n"
            . "if ('" . label . "' -eq 'WinRM') {`n"
            . "  Get-NetFirewallRule -Name 'WINRM-HTTP-In-TCP*','WINRM-HTTPS-In-TCP*','WINRM-HTTP-Compat-In-TCP*','WINRM-HTTPS-Compat-In-TCP*' -ErrorAction SilentlyContinue | Disable-NetFirewallRule -ErrorAction Stop | Out-Null`n"
            . "  Remove-NetFirewallRule -Name 'LabStation-WinRM-HTTP-Block' -ErrorAction SilentlyContinue`n"
            . "  New-NetFirewallRule -Name 'LabStation-WinRM-HTTP-Block' -DisplayName 'Lab Station block WinRM HTTP' -Direction Inbound -Action Block -Enabled True -Protocol TCP -LocalPort '5985' -Service 'WinRM' -Profile Domain,Private,Public -ErrorAction Stop | Out-Null`n"
            . "}`n"
            . "Remove-NetFirewallRule -Name '" . ruleName . "' -ErrorAction SilentlyContinue`n"
            . "New-NetFirewallRule -Name '" . ruleName . "' -DisplayName '" . displayName . "' -Direction Inbound -Action Allow -Enabled True -Protocol TCP -LocalPort '" . port . "'" . serviceFilterArgument . " -RemoteAddress `$allowedAddresses -Profile Domain,Private,Public -ErrorAction Stop | Out-Null`n"
            . "`$rule = Get-NetFirewallRule -Name '" . ruleName . "' -ErrorAction Stop`n"
            . "`$actualAddresses = @((Get-NetFirewallAddressFilter -AssociatedNetFirewallRule `$rule -ErrorAction Stop).RemoteAddress)`n"
            . "`$actualPort = @(Get-NetFirewallPortFilter -AssociatedNetFirewallRule `$rule -ErrorAction Stop | Where-Object { ([string]`$_.Protocol -match '(?i)^TCP$|^6$') -and [string]`$_.LocalPort -eq '" . port . "' }).Count -gt 0`n"
            . "`$actualService = @(Get-NetFirewallServiceFilter -AssociatedNetFirewallRule `$rule -ErrorAction Stop | Where-Object { [string]`$_.Service -eq '" . expectedServiceFilter . "' }).Count -gt 0`n"
            . "if (-not `$rule.Enabled -or `$rule.Action -ne 'Allow' -or -not `$actualPort -or -not `$actualService -or `$actualAddresses.Count -ne `$allowedAddresses.Count -or @(`$actualAddresses | Where-Object { `$allowedAddresses -notcontains ([string]`$_).Trim() }).Count -gt 0) { throw 'The scoped firewall rule did not pass verification' }`n"
            . "Write-Output 'LABSTATION_SCOPED_FIREWALL_READY'`n"
        capture := LS_RunPowerShellCapture(script, "Configure Gateway-scoped " . label . " firewall rule", LAB_STATION_LONG_COMMAND_TIMEOUT_MS)
        ready := capture["exitCode"] = 0 && InStr(capture["stdout"], "LABSTATION_SCOPED_FIREWALL_READY") > 0
        if (ready) {
            LS_LogInfo("Gateway-scoped " . label . " firewall rule configured for " . addresses)
            return true
        }
        detail := LS_CaptureDetail(capture)
        LS_LogError("Unable to configure Gateway-scoped " . label . " firewall rule" . (detail != "" ? ": " . detail : ""))
        return false
    }

    static GetStatus() {
        script := ""
            . "`$ErrorActionPreference = 'Stop'`n"
            . "`$key = 'HKLM:\SOFTWARE\DecentraLabs\Lab Station\NetworkAccess'`n"
            . "`$configured = Get-ItemProperty -Path `$key -ErrorAction SilentlyContinue`n"
            . "`$rdpExpected = @()`n"
            . "`$winrmExpected = @()`n"
            . "if (`$configured.RdpRemoteAddresses) { `$rdpExpected = @(([string]`$configured.RdpRemoteAddresses).Split(',') | ForEach-Object { `$_.Trim() } | Where-Object { `$_ }) }`n"
            . "if (`$configured.WinRmRemoteAddresses) { `$winrmExpected = @(([string]`$configured.WinRmRemoteAddresses).Split(',') | ForEach-Object { `$_.Trim() } | Where-Object { `$_ }) }`n"
            . "`$profiles = @(Get-NetFirewallProfile -Profile Domain,Private,Public -ErrorAction Stop)`n"
            . "`$inboundBlocked = `$profiles.Count -eq 3 -and @(`$profiles | Where-Object { -not `$_.Enabled -or [string]`$_.DefaultInboundAction -ne 'Block' }).Count -eq 0`n"
            . "function Test-ScopedRule([string]`$Name, [string]`$Port, [string]`$Service, [string[]]`$Expected) {`n"
            . "  if (`$Expected.Count -eq 0) { return `$false }`n"
            . "  foreach (`$rule in @(Get-NetFirewallRule -Name `$Name -ErrorAction SilentlyContinue)) {`n"
            . "    if (-not `$rule.Enabled -or `$rule.Direction -ne 'Inbound' -or `$rule.Action -ne 'Allow') { continue }`n"
            . "    `$portOk = @(Get-NetFirewallPortFilter -AssociatedNetFirewallRule `$rule -ErrorAction SilentlyContinue | Where-Object { ([string]`$_.Protocol -match '(?i)^TCP$|^6$') -and [string]`$_.LocalPort -eq `$Port }).Count -gt 0`n"
            . "    `$serviceOk = @(Get-NetFirewallServiceFilter -AssociatedNetFirewallRule `$rule -ErrorAction SilentlyContinue | Where-Object { [string]`$_.Service -eq `$Service }).Count -gt 0`n"
            . "    `$actual = @((Get-NetFirewallAddressFilter -AssociatedNetFirewallRule `$rule -ErrorAction SilentlyContinue).RemoteAddress | ForEach-Object { ([string]`$_).Trim() } | Where-Object { `$_ })`n"
            . "    `$profileText = [string]`$rule.Profile`n"
            . "    `$profileOk = `$profileText -eq 'Any' -or @(@('Domain','Private','Public') | Where-Object { `$profileText -notmatch `$_ }).Count -eq 0`n"
            . "    if (`$portOk -and `$serviceOk -and `$profileOk -and `$actual.Count -eq `$Expected.Count -and @(`$actual | Where-Object { `$Expected -notcontains `$_ }).Count -eq 0) { return `$true }`n"
            . "  }`n"
            . "  return `$false`n"
            . "}`n"
            . "function Test-NoUnexpectedAllowRule([string]`$Port, [string]`$Service, [string]`$ManagedName, [string]`$Kind) {`n"
            . "  foreach (`$rule in @(Get-NetFirewallRule -PolicyStore ActiveStore -Direction Inbound -Action Allow -Enabled True -ErrorAction SilentlyContinue)) {`n"
            . "    if (`$rule.Name -eq `$ManagedName) { continue }`n"
            . "    if (`$Kind -eq 'RDP' -and `$rule.Name -like 'RemoteDesktop-*') { return `$false }`n"
            . "    if (`$Kind -eq 'WinRM' -and `$rule.Name -like 'WINRM-*-In-TCP*') { return `$false }`n"
            . "    `$portMatch = @(Get-NetFirewallPortFilter -AssociatedNetFirewallRule `$rule -ErrorAction SilentlyContinue | Where-Object { ([string]`$_.Protocol -match '(?i)^TCP$|^6$') -and [string]`$_.LocalPort -eq `$Port }).Count -gt 0`n"
            . "    `$serviceMatch = @(Get-NetFirewallServiceFilter -AssociatedNetFirewallRule `$rule -ErrorAction SilentlyContinue | Where-Object { [string]`$_.Service -eq `$Service }).Count -gt 0`n"
            . "    if (`$portMatch -or `$serviceMatch) { return `$false }`n"
            . "  }`n"
            . "  return `$true`n"
            . "}`n"
            . "`$rdpRule = Test-ScopedRule 'LabStation-RDP-Gateway-TCP' '3389' 'TermService' `$rdpExpected`n"
            . "`$winrmRule = Test-ScopedRule 'LabStation-WinRM-HTTPS' '5986' 'Any' `$winrmExpected`n"
            . "`$rdpNoUnexpectedRules = Test-NoUnexpectedAllowRule '3389' 'TermService' 'LabStation-RDP-Gateway-TCP' 'RDP'`n"
            . "`$winrmNoUnexpectedRules = Test-NoUnexpectedAllowRule '5986' 'WinRM' 'LabStation-WinRM-HTTPS' 'WinRM'`n"
            . "`$winrmHttpBlocked = `$false`n"
            . "foreach (`$rule in @(Get-NetFirewallRule -Name 'LabStation-WinRM-HTTP-Block' -ErrorAction SilentlyContinue)) {`n"
            . "  if (-not `$rule.Enabled -or `$rule.Direction -ne 'Inbound' -or `$rule.Action -ne 'Block') { continue }`n"
            . "  `$portOk = @(Get-NetFirewallPortFilter -AssociatedNetFirewallRule `$rule -ErrorAction SilentlyContinue | Where-Object { ([string]`$_.Protocol -match '(?i)^TCP$|^6$') -and [string]`$_.LocalPort -eq '5985' }).Count -gt 0`n"
            . "  `$serviceOk = @(Get-NetFirewallServiceFilter -AssociatedNetFirewallRule `$rule -ErrorAction SilentlyContinue | Where-Object { [string]`$_.Service -eq 'WinRM' }).Count -gt 0`n"
            . "  `$profileText = [string]`$rule.Profile`n"
            . "  `$profileOk = `$profileText -eq 'Any' -or @(@('Domain','Private','Public') | Where-Object { `$profileText -notmatch `$_ }).Count -eq 0`n"
            . "  if (`$portOk -and `$serviceOk -and `$profileOk) { `$winrmHttpBlocked = `$true; break }`n"
            . "}`n"
            . "[pscustomobject]@{ inboundDefaultBlocked = [bool]`$inboundBlocked; rdpSourcesConfigured = (`$rdpExpected.Count -gt 0); rdpRuleReady = [bool]`$rdpRule; rdpNoUnexpectedAllowRules = [bool]`$rdpNoUnexpectedRules; rdpReady = ([bool]`$inboundBlocked -and [bool]`$rdpRule -and [bool]`$rdpNoUnexpectedRules); winrmSourcesConfigured = (`$winrmExpected.Count -gt 0); winrmRuleReady = [bool]`$winrmRule; winrmNoUnexpectedAllowRules = [bool]`$winrmNoUnexpectedRules; winrmHttpBlocked = [bool]`$winrmHttpBlocked; winrmReady = ([bool]`$inboundBlocked -and [bool]`$winrmRule -and [bool]`$winrmNoUnexpectedRules -and [bool]`$winrmHttpBlocked) } | ConvertTo-Json -Compress`n"
        capture := LS_RunPowerShellCapture(script, "Query Gateway-scoped firewall status", LAB_STATION_COMMAND_TIMEOUT_MS)
        if (capture["exitCode"] != 0 || Trim(capture["stdout"]) = "") {
            detail := LS_CaptureDetail(capture)
            if (detail != "")
                LS_LogWarning("Unable to query Gateway-scoped firewall status: " . detail)
            return this.EmptyStatus()
        }
        try return LS_ParseJson(capture["stdout"])
        catch as e {
            LS_LogWarning("Unable to parse Gateway-scoped firewall status: " . e.Message)
            return this.EmptyStatus()
        }
    }

    static EmptyStatus() {
        return Map(
            "inboundDefaultBlocked", false,
            "rdpSourcesConfigured", false,
            "rdpRuleReady", false,
            "rdpNoUnexpectedAllowRules", false,
            "rdpReady", false,
            "winrmSourcesConfigured", false,
            "winrmRuleReady", false,
            "winrmNoUnexpectedAllowRules", false,
            "winrmHttpBlocked", false,
            "winrmReady", false
        )
    }

    static ReadConfiguredAddresses(valueName) {
        try return Trim(RegRead(this.RegistryKey, valueName))
        catch {
            return ""
        }
    }

    static NormalizeAddressList(value) {
        value := StrReplace(value, "`r", ",")
        value := StrReplace(value, "`n", ",")
        value := StrReplace(value, ";", ",")
        result := []
        seen := Map()
        for entry in StrSplit(value, ",") {
            entry := Trim(entry)
            if (entry = "")
                continue
            if (!RegExMatch(entry, "i)^([0-9a-f:.]+)(?:/([0-9]{1,3}))?$"))
                throw Error("Invalid address or subnet: " . entry)
            if (seen.Has(StrLower(entry)))
                continue
            seen[StrLower(entry)] := true
            result.Push(entry)
        }
        if (result.Length = 0)
            throw Error("At least one Gateway source address or CIDR subnet is required.")
        joined := ""
        for index, entry in result
            joined .= (index > 1 ? "," : "") . entry
        return joined
    }

    static ValidateAddressList(addresses) {
        script := ""
            . "`$ErrorActionPreference = 'Stop'`n"
            . "`$entries = " . this.PowerShellAddressArray(addresses) . "`n"
            . "foreach (`$entry in `$entries) {`n"
            . "  `$parts = `$entry.Split('/')`n"
            . "  if (`$parts.Count -gt 2) { exit 1 }`n"
            . "  `$ip = [System.Net.IPAddress]::Parse(`$parts[0])`n"
            . "  if (`$parts.Count -eq 2) {`n"
            . "    `$prefix = 0`n"
            . "    if (-not [int]::TryParse(`$parts[1], [ref]`$prefix)) { exit 1 }`n"
            . "    `$maxPrefix = if (`$ip.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork) { 32 } else { 128 }`n"
            . "    if (`$prefix -lt 1 -or `$prefix -gt `$maxPrefix) { exit 1 }`n"
            . "  }`n"
            . "}`n"
            . "Write-Output 'LABSTATION_ADDRESS_LIST_VALID'`n"
        capture := LS_RunPowerShellCapture(script, "Validate Gateway firewall addresses")
        return capture["exitCode"] = 0 && InStr(capture["stdout"], "LABSTATION_ADDRESS_LIST_VALID") > 0
    }

    static PowerShellAddressArray(addresses) {
        result := "@("
        entries := StrSplit(addresses, ",")
        for index, address in entries {
            escaped := StrReplace(address, "'", "''")
            result .= (index > 1 ? "," : "") . "'" . escaped . "'"
        }
        return result . ")"
    }
}
