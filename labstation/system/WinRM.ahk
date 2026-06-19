; ============================================================================
; Lab Station - WinRM configuration for Lab Gateway operations
; ============================================================================
#Requires AutoHotkey v2.0
#Include ..\core\Config.ahk
#Include ..\core\Logger.ahk
#Include ..\core\Admin.ahk
#Include ..\core\Shell.ahk
#Include ..\core\Json.ahk

class LS_WinRM {
    static DefaultGatewayUser := "LabGatewaySvc"

    static Configure(user := "", &password := "") {
        if (!LS_EnsureAdmin()) {
            return false
        }
        if (!user || user = "") {
            user := this.DefaultGatewayUser
        }
        localPassword := password && password != "" ? password : this.GeneratePassword()
        script := this.BuildConfigureScript(user, localPassword)
        exitCode := LS_RunPowerShell(script, "Configure WinRM for Lab Gateway")
        if (exitCode = 0) {
            password := localPassword
            LS_LogInfo("WinRM configured for Lab Gateway user " . user)
            return true
        }
        LS_LogError("WinRM configuration failed (exit=" . exitCode . ")")
        return false
    }

    static GetStatus() {
        script := "
        (
$ErrorActionPreference = 'SilentlyContinue'
$svc = Get-Service -Name WinRM
$listener = Get-ChildItem WSMan:\localhost\Listener | Where-Object {
    $_.Keys -contains 'Transport=HTTP'
} | Select-Object -First 1
$firewall = Get-NetFirewallRule -Name 'WINRM-HTTP-In-TCP*','LabStation-WinRM-HTTP' -ErrorAction SilentlyContinue |
    Where-Object { $_.Enabled -eq 'True' -and $_.Direction -eq 'Inbound' } |
    Select-Object -First 1
if (-not $firewall) {
    $firewall = Get-NetFirewallRule -DisplayGroup 'Windows Remote Management' -ErrorAction SilentlyContinue |
        Where-Object { $_.Enabled -eq 'True' -and $_.Direction -eq 'Inbound' } |
        Select-Object -First 1
}
$allowUnencrypted = (Get-Item WSMan:\localhost\Service\AllowUnencrypted).Value
$ntlmAuth = Get-Item WSMan:\localhost\Service\Auth\NTLM
[pscustomobject]@{
    serviceInstalled = [bool]$svc
    serviceRunning = ($svc.Status -eq 'Running')
    serviceStartType = [string]$svc.StartType
    httpListener = [bool]$listener
    firewallEnabled = [bool]$firewall
    allowUnencrypted = [bool]$allowUnencrypted
    ntlmAuth = [bool]$ntlmAuth.Value
} | ConvertTo-Json -Compress
        )"
        capture := LS_RunPowerShellCapture(script, "Query WinRM status")
        if (capture["exitCode"] != 0 || Trim(capture["stdout"]) = "") {
            LS_LogWarning("Unable to query WinRM status")
            return Map(
                "serviceInstalled", false,
                "serviceRunning", false,
                "serviceStartType", "",
                "httpListener", false,
                "firewallEnabled", false,
                "allowUnencrypted", false,
                "ntlmAuth", false,
                "ready", false
            )
        }
        try {
            status := LS_ParseJson(capture["stdout"])
            status["ready"] := (
                status["serviceRunning"]
                && status["httpListener"]
                && status["firewallEnabled"]
                && status["allowUnencrypted"]
                && status["ntlmAuth"]
            )
            return status
        } catch as e {
            LS_LogWarning("Unable to parse WinRM status: " . e.Message)
            return Map("ready", false)
        }
    }

    static BuildConfigureScript(user, password) {
        escapedUser := this.EscapeForPSSingleQuote(user)
        escapedPassword := this.EscapeForPSSingleQuote(password)
        template := "
        (
$ErrorActionPreference = 'Stop'
$User = '__WINRM_USER__'
$Password = '__WINRM_PASSWORD__'
$secure = ConvertTo-SecureString $Password -AsPlainText -Force
if (-not (Get-LocalUser -Name $User -ErrorAction SilentlyContinue)) {
    New-LocalUser -Name $User -Password $secure -PasswordNeverExpires $true -AccountNeverExpires $true -Description 'DecentraLabs Lab Gateway WinRM account' | Out-Null
} else {
    Set-LocalUser -Name $User -Password $secure -PasswordNeverExpires $true -AccountNeverExpires $true -Description 'DecentraLabs Lab Gateway WinRM account'
    Enable-LocalUser -Name $User -ErrorAction SilentlyContinue | Out-Null
}
try { Add-LocalGroupMember -Group 'Administrators' -Member $User -ErrorAction SilentlyContinue } catch {}

Set-Service -Name WinRM -StartupType Automatic
Enable-PSRemoting -Force -SkipNetworkProfileCheck | Out-Null
Set-Item -Path WSMan:\localhost\Service\AllowUnencrypted -Value $true
Set-Item -Path WSMan:\localhost\Service\Auth\NTLM -Value $true
Set-Item -Path WSMan:\localhost\Service\Auth\Negotiate -Value $true
try { Set-Item -Path WSMan:\localhost\Service\Auth\Kerberos -Value $true } catch {}
try {
    Enable-NetFirewallRule -Name 'WINRM-HTTP-In-TCP*' -ErrorAction Stop
} catch {
    try { Enable-NetFirewallRule -DisplayGroup 'Windows Remote Management' -ErrorAction Stop } catch {}
}
try {
    New-NetFirewallRule -Name 'LabStation-WinRM-HTTP' -DisplayName 'Lab Station WinRM HTTP' -Direction Inbound -Action Allow -Protocol TCP -LocalPort 5985 -Profile Any -ErrorAction SilentlyContinue | Out-Null
} catch {
    netsh advfirewall firewall set rule group='Windows Remote Management' new enable=yes | Out-Null
}
Start-Service -Name WinRM

$localUsers = Get-LocalUser -ErrorAction SilentlyContinue
$targetSid = ''
try { $targetSid = ($localUsers | Where-Object { $_.Name -eq $User } | Select-Object -First 1).SID.Value } catch {}
if ($targetSid) {
    $denySids = New-Object System.Collections.Generic.List[string]
    $tempExport = Join-Path $env:TEMP ('ls-winrm-secexport-' + [guid]::NewGuid().Guid + '.inf')
    secedit /export /cfg $tempExport /areas USER_RIGHTS | Out-Null
    if (Test-Path $tempExport) {
        foreach ($line in Get-Content $tempExport) {
            if ($line -match '^SeDenyInteractiveLogonRight\s*=\s*(.*)$') {
                foreach ($token in $Matches[1].Split(',')) {
                    $t = $token.Trim()
                    if ($t -and -not $denySids.Contains($t)) { [void]$denySids.Add($t) }
                }
                break
            }
        }
        Remove-Item $tempExport -Force -ErrorAction SilentlyContinue
    }
    $targetToken = '*' + $targetSid
    if (-not $denySids.Contains($targetToken)) { [void]$denySids.Add($targetToken) }
    $tempCfg = Join-Path $env:TEMP ('ls-winrm-deny-' + [guid]::NewGuid().Guid + '.inf')
    $cfg = @'
[Unicode]
Unicode=yes
[Version]
signature="$CHICAGO$"
Revision=1
[Privilege Rights]
SeDenyInteractiveLogonRight = __DENY_SIDS__
'@
    $cfg = $cfg.Replace('__DENY_SIDS__', ($denySids -join ','))
    $cfg | Out-File -FilePath $tempCfg -Encoding Unicode -Force
    $dbPath = Join-Path $env:TEMP 'ls-winrm-deny.sdb'
    secedit /configure /db $dbPath /cfg $tempCfg /areas USER_RIGHTS /quiet | Out-Null
    if ($LASTEXITCODE -ne 0) { throw ("secedit failed with exit code " + $LASTEXITCODE) }
    Remove-Item $tempCfg -Force -ErrorAction SilentlyContinue
}
        )"
        script := StrReplace(template, "__WINRM_USER__", escapedUser)
        return StrReplace(script, "__WINRM_PASSWORD__", escapedPassword)
    }

    static EscapeForPSSingleQuote(value) {
        return StrReplace(value, "'", "''")
    }

    static GeneratePassword(length := 24) {
        chars := "ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789!@#$%+-_"
        password := ""
        total := StrLen(chars)
        Loop length {
            idx := Floor(Random() * total) + 1
            password .= SubStr(chars, idx, 1)
        }
        return password
    }
}
