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
        capture := LS_RunPowerShellCapture(script, "Configure WinRM for Lab Gateway")
        exitCode := capture["exitCode"]
        status := exitCode = 0 ? this.GetStatus() : Map("ready", false)
        if (exitCode = 0 && status.Has("ready") && status["ready"]) {
            password := localPassword
            LS_LogInfo("WinRM configured for Lab Gateway user " . user)
            return true
        }
        detail := Trim(capture["stderr"] != "" ? capture["stderr"] : capture["stdout"])
        if (detail != "")
            LS_LogError("WinRM configuration failed or not ready (exit=" . exitCode . "): " . detail)
        else
            LS_LogError("WinRM configuration failed or not ready (exit=" . exitCode . ")")
        return false
    }

    static GetStatus() {
        script := "
        (
$ErrorActionPreference = 'Continue'
$svc = Get-Service -Name WinRM -ErrorAction SilentlyContinue
$listenerText = ''
try { $listenerText = (& winrm enumerate winrm/config/listener 2>$null) -join [Environment]::NewLine } catch {}
$listener = $listenerText -match 'Transport\s*=\s*HTTP'
$firewall = $false
try {
    $rule = Get-NetFirewallRule -Name 'WINRM-HTTP-In-TCP*','LabStation-WinRM-HTTP' -ErrorAction SilentlyContinue |
        Where-Object { $_.Enabled -eq 'True' -and $_.Direction -eq 'Inbound' } |
        Select-Object -First 1
    if (-not $rule) {
        $rule = Get-NetFirewallRule -DisplayGroup 'Windows Remote Management' -ErrorAction SilentlyContinue |
            Where-Object { $_.Enabled -eq 'True' -and $_.Direction -eq 'Inbound' } |
            Select-Object -First 1
    }
    $firewall = [bool]$rule
} catch {}
if (-not $firewall) {
    try {
        $netsh = (& netsh advfirewall firewall show rule name=all 2>$null) -join [Environment]::NewLine
        $firewall = ($netsh -match '5985') -and ($netsh -match '(?i)(Enabled|Habilitada|Habilitado)\s*:\s*(Yes|S[ií])')
    } catch {}
}
$allowUnencrypted = $false
$ntlmAuth = $false
try { $allowUnencrypted = [bool](Get-Item WSMan:\localhost\Service\AllowUnencrypted -ErrorAction SilentlyContinue).Value } catch {}
try { $ntlmAuth = [bool](Get-Item WSMan:\localhost\Service\Auth\NTLM -ErrorAction SilentlyContinue).Value } catch {}
[pscustomobject]@{
    serviceInstalled = [bool]$svc
    serviceRunning = ($svc.Status -eq 'Running')
    serviceStartType = [string]$svc.StartType
    httpListener = [bool]$listener
    firewallEnabled = [bool]$firewall
    allowUnencrypted = [bool]$allowUnencrypted
    ntlmAuth = [bool]$ntlmAuth
} | ConvertTo-Json -Compress
        )"
        capture := LS_RunPowerShellCapture(script, "Query WinRM status")
        if (capture["exitCode"] != 0 || Trim(capture["stdout"]) = "") {
            detail := Trim(capture["stderr"] != "" ? capture["stderr"] : capture["stdout"])
            if (detail != "")
                LS_LogWarning("Unable to query WinRM status: " . detail)
            else
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

try {
    Get-NetConnectionProfile -ErrorAction Stop |
        Where-Object { $_.NetworkCategory -eq 'Public' } |
        ForEach-Object {
            Set-NetConnectionProfile -InterfaceIndex $_.InterfaceIndex -NetworkCategory Private -ErrorAction Stop
        }
} catch {
    throw ('Unable to set Public network profile(s) to Private for WinRM firewall rules: ' + $_.Exception.Message)
}

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
netsh advfirewall firewall add rule name='Lab Station WinRM HTTP' dir=in action=allow protocol=TCP localport=5985 profile=any | Out-Null
Start-Service -Name WinRM

function Test-LocalUserCompat([string]$Name) {
    try { return [bool](Get-LocalUser -Name $Name -ErrorAction Stop) } catch {}
    & net user $Name *> $null
    return $LASTEXITCODE -eq 0
}

function Get-LocalUserSidCompat([string]$Name) {
    try {
        $u = Get-LocalUser -Name $Name -ErrorAction Stop
        if ($u -and $u.SID) { return $u.SID.Value }
    } catch {}
    try {
        $account = New-Object System.Security.Principal.NTAccount($env:COMPUTERNAME, $Name)
        return $account.Translate([System.Security.Principal.SecurityIdentifier]).Value
    } catch {
        return ''
    }
}

function Ensure-LocalUserCompat([string]$Name, [string]$PlainPassword) {
    $secure = ConvertTo-SecureString $PlainPassword -AsPlainText -Force
    if (-not (Test-LocalUserCompat $Name)) {
        try {
            New-LocalUser -Name $Name -Password $secure -PasswordNeverExpires $true -AccountNeverExpires $true -Description 'DecentraLabs Lab Gateway WinRM account' | Out-Null
        } catch {
            & net user $Name $PlainPassword /add /expires:never /passwordchg:no | Out-Null
            if ($LASTEXITCODE -ne 0) { throw ('net user add failed with exit code ' + $LASTEXITCODE) }
        }
    } else {
        try {
            Set-LocalUser -Name $Name -Password $secure -PasswordNeverExpires $true -AccountNeverExpires $true -Description 'DecentraLabs Lab Gateway WinRM account'
            Enable-LocalUser -Name $Name -ErrorAction SilentlyContinue | Out-Null
        } catch {
            & net user $Name $PlainPassword /active:yes /expires:never /passwordchg:no | Out-Null
            if ($LASTEXITCODE -ne 0) { throw ('net user update failed with exit code ' + $LASTEXITCODE) }
        }
    }
    if (-not (Test-LocalUserCompat $Name)) { throw ('Local user ' + $Name + ' was not created') }
}

function Add-LocalGroupMemberCompat([string]$GroupSid, [string]$Member) {
    try {
        $groupName = (Get-LocalGroup -SID $GroupSid -ErrorAction Stop).Name
        Add-LocalGroupMember -Group $groupName -Member $Member -ErrorAction SilentlyContinue
        return
    } catch {}
    try {
        $sid = New-Object System.Security.Principal.SecurityIdentifier($GroupSid)
        $groupName = $sid.Translate([System.Security.Principal.NTAccount]).Value.Split('\')[-1]
        & net localgroup $groupName $Member /add | Out-Null
    } catch {}
}

Ensure-LocalUserCompat $User $Password
Add-LocalGroupMemberCompat 'S-1-5-32-544' $User

$targetSid = Get-LocalUserSidCompat $User
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
