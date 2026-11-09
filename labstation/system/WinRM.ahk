; ============================================================================
; Lab Station - WinRM configuration for Lab Gateway operations
; ============================================================================
#Requires AutoHotkey v2.0
#Include ..\core\Config.ahk
#Include ..\core\Logger.ahk
#Include ..\core\Admin.ahk
#Include ..\core\Shell.ahk
#Include ..\core\Json.ahk
#Include FirewallManager.ahk

class LS_WinRM {
    static DefaultGatewayUser := "LabGatewaySvc"

    static Configure(user := "", &password := "") {
        if (!LS_EnsureAdmin()) {
            return false
        }
        if (!LS_FirewallManager.ConfigureWinRmFirewall()) {
            LS_LogError("Configure a valid Gateway WinRM firewall scope before enabling WinRM")
            return false
        }
        if (!user || user = "") {
            user := this.DefaultGatewayUser
        }
        localPassword := password && password != "" ? password : this.GeneratePassword()
        script := this.BuildConfigureScript(user, localPassword)
        capture := LS_RunPowerShellCapture(
            script,
            "Configure WinRM for Lab Gateway",
            LAB_STATION_LONG_COMMAND_TIMEOUT_MS
        )
        exitCode := capture["exitCode"]
        firewallReady := LS_FirewallManager.ConfigureWinRmFirewall()
        status := exitCode = 0 && firewallReady ? this.GetStatus() : Map("ready", false)
        if (exitCode = 0 && status.Has("ready") && status["ready"]) {
            password := localPassword
            LS_LogInfo("WinRM configured for Lab Gateway user " . user)
            certificateInfo := Trim(capture["stdout"])
            if (certificateInfo != "")
                LS_LogInfo(certificateInfo)
            return true
        }
        detail := LS_CaptureDetail(capture)
        if (detail != "")
            LS_LogError("WinRM configuration failed or not ready (exit=" . exitCode . "): " . detail)
        else
            LS_LogError("WinRM configuration failed or not ready (exit=" . exitCode . ")")
        return false
    }

    static GetStatus(firewallStatus := "") {
        if (!IsObject(firewallStatus))
            firewallStatus := LS_FirewallManager.GetStatus()
        script := "
        (
$ErrorActionPreference = 'Continue'
$svc = Get-Service -Name WinRM -ErrorAction SilentlyContinue
$listenerText = ''
`$listenerObjects = @()
try {
    # Query the listener as a WSMan object first.  The object property is
    # CertificateThumbprint on Windows client (including Windows 10 and 11),
    # while older/localized winrm.exe text may expose a different label.
    `$listenerObjects = @(Get-WSManInstance -ResourceURI 'winrm/config/listener' -Enumerate -ErrorAction Stop)
} catch {}
try { $listenerText = (& winrm enumerate winrm/config/listener 2>$null) -join [Environment]::NewLine } catch {}
function ConvertTo-BooleanValue([object]$Value) {
    # WSMan provider values are strings on Windows PowerShell 5.1.  Casting
    # the string "false" directly to [bool] returns $true, so parse the
    # documented textual values explicitly instead of relying on truthiness.
    if ($Value -is [bool]) { return [bool]$Value }
    if ($null -eq $Value) { return $null }
    $text = ([string]$Value).Trim()
    if ($text -match '^(?i:true|1|yes|enabled|on)$') { return $true }
    if ($text -match '^(?i:false|0|no|disabled|off)$') { return $false }
    return $null
}
function Test-ValidWinRMCertificate([string]$Thumbprint) {
    if ([string]::IsNullOrWhiteSpace($Thumbprint)) { return $false }
    $normalized = ($Thumbprint -replace '\s', '').ToUpperInvariant()
    try {
        return [bool](Get-ChildItem Cert:\LocalMachine\My -ErrorAction Stop |
            Where-Object {
                (($_.Thumbprint -replace '\s', '').ToUpperInvariant() -eq $normalized) -and
                $_.HasPrivateKey -and
                $_.NotAfter -gt (Get-Date)
            } |
            Select-Object -First 1)
    } catch {
        return $false
    }
}
`$httpsListeners = @(`$listenerObjects | Where-Object {
    [string]`$_.Transport -match '(?i)^HTTPS$' -and
    (ConvertTo-BooleanValue `$_.Enabled) -eq `$true
})
`$httpsListener = `$httpsListeners.Count -gt 0
`$httpsPort = @(`$httpsListeners | Where-Object { [string]`$_.Port -eq '5986' }).Count -gt 0
`$certificateConfigured = `$false
foreach (`$listener in `$httpsListeners) {
    `$thumbprint = ([string]`$listener.CertificateThumbprint).Trim()
    if ([string]::IsNullOrWhiteSpace(`$thumbprint)) {
        `$thumbprint = ([string]`$listener.Certificate).Trim()
    }
    if (Test-ValidWinRMCertificate `$thumbprint) {
        `$certificateConfigured = `$true
        break
    }
}
`$httpListener = @(`$listenerObjects | Where-Object {
    [string]`$_.Transport -match '(?i)^HTTP$' -and
    (ConvertTo-BooleanValue `$_.Enabled) -eq `$true
}).Count -gt 0
# Fallback for systems where the WSMan PowerShell provider is unavailable.
# Parse one listener block at a time so an enabled HTTP/HTTPS listener cannot
# accidentally satisfy the status of a different, disabled listener.
`$listenerBlocks = @()
if (`$listenerText) {
    `$listenerBlocks = @(`$listenerText -split '(?im)(?=^\s*Listener\s*$)' |
        Where-Object { `$_ -match '\S' })
}
foreach (`$block in `$listenerBlocks) {
    `$isHttpsBlock = `$block -match '(?im)^\s*Transport\s*=\s*HTTPS\s*$'
    `$isHttpBlock = `$block -match '(?im)^\s*Transport\s*=\s*HTTP\s*$'
    `$isEnabledBlock = `$block -match '(?im)^\s*Enabled\s*=\s*(?:true|yes|1|si|sí)\s*$'
    if (`$isHttpsBlock -and `$isEnabledBlock) {
        `$httpsListener = `$true
        if (`$block -match '(?im)^\s*Port\s*=\s*5986\s*$') {
            `$httpsPort = `$true
        }
        if (-not `$certificateConfigured -and
            `$block -match '(?im)(?:CertificateThumbprint|Certificate)\s*=\s*(\S+)') {
            `$certificateConfigured = Test-ValidWinRMCertificate `$Matches[1]
        }
    }
    if (`$isHttpBlock -and `$isEnabledBlock) {
        `$httpListener = `$true
    }
}
`$allowUnencrypted = `$null
`$negotiateAuth = `$null
`$ntlmAuth = `$null
try { `$allowUnencrypted = ConvertTo-BooleanValue ((Get-Item WSMan:\localhost\Service\AllowUnencrypted -ErrorAction Stop).Value) } catch {}
try { `$negotiateAuth = ConvertTo-BooleanValue ((Get-Item WSMan:\localhost\Service\Auth\Negotiate -ErrorAction Stop).Value) } catch {}
try { `$ntlmAuth = ConvertTo-BooleanValue ((Get-Item WSMan:\localhost\Service\Auth\NTLM -ErrorAction Stop).Value) } catch {}
[pscustomobject]@{
    serviceInstalled = [bool]$svc
    serviceRunning = ($svc.Status -eq 'Running')
    serviceStartType = [string]$svc.StartType
    httpListener = [bool]$httpListener
    httpsListener = [bool]$httpsListener
    httpsPort = [bool]$httpsPort
    certificateConfigured = [bool]$certificateConfigured
    firewallEnabled = $false
    allowUnencrypted = $allowUnencrypted
    negotiateAuth = $negotiateAuth
    ntlmAuth = $ntlmAuth
} | ConvertTo-Json -Compress
        )"
        capture := LS_RunPowerShellCapture(
            script,
            "Query WinRM status",
            LAB_STATION_COMMAND_TIMEOUT_MS
        )
        if (capture["exitCode"] != 0 || Trim(capture["stdout"]) = "") {
            detail := LS_CaptureDetail(capture)
            if (detail != "")
                LS_LogWarning("Unable to query WinRM status: " . detail)
            else
                LS_LogWarning("Unable to query WinRM status")
            return Map(
                "serviceInstalled", false,
                "serviceRunning", false,
                "serviceStartType", "",
                "httpListener", false,
                "httpsListener", false,
                "httpsPort", false,
                "certificateConfigured", false,
                "firewallEnabled", false,
                "firewallScopeConfigured", false,
                "firewallScopedRuleReady", false,
                "firewallHttpBlocked", false,
                "firewallInboundDefaultBlocked", false,
                "allowUnencrypted", false,
                "negotiateAuth", false,
                "ntlmAuth", false,
                "ready", false
            )
        }
        try {
            status := LS_ParseJson(capture["stdout"])
            status["firewallScopeConfigured"] := firewallStatus["winrmSourcesConfigured"]
            status["firewallScopedRuleReady"] := firewallStatus["winrmRuleReady"]
            status["firewallHttpBlocked"] := firewallStatus["winrmHttpBlocked"]
            status["firewallInboundDefaultBlocked"] := firewallStatus["inboundDefaultBlocked"]
            status["firewallEnabled"] := firewallStatus["winrmReady"]
            status["ready"] := (
                status["serviceRunning"]
                && !status["httpListener"]
                && status["httpsListener"]
                && status["httpsPort"]
                && status["certificateConfigured"]
                && status["firewallEnabled"]
                && status["allowUnencrypted"] = false
                && status["negotiateAuth"] = true
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

function Set-WinRMConfigBool([string]$Path, [bool]$Value, [string]$WinRMPath, [string]$Key) {
    try {
        if (Test-Path $Path) {
            Set-Item -Path $Path -Value $Value -ErrorAction Stop
            return
        }
    } catch {}
    $textValue = if ($Value) { 'true' } else { 'false' }
    & winrm set $WinRMPath "@{$Key=`"$textValue`"}" | Out-Null
    if ($LASTEXITCODE -ne 0) { throw ('winrm set failed for ' + $WinRMPath + '/' + $Key + ' with exit code ' + $LASTEXITCODE) }
}

Set-Service -Name WinRM -StartupType Automatic
Start-Service -Name WinRM
Enable-PSRemoting -Force -SkipNetworkProfileCheck | Out-Null
Set-WinRMConfigBool 'WSMan:\localhost\Service\AllowUnencrypted' $false 'winrm/config/service' 'AllowUnencrypted'
Set-WinRMConfigBool 'WSMan:\localhost\Service\Auth\Negotiate' $true 'winrm/config/service/auth' 'Negotiate'
try { Set-WinRMConfigBool 'WSMan:\localhost\Service\Auth\Basic' $false 'winrm/config/service/auth' 'Basic' } catch {}
try { Set-WinRMConfigBool 'WSMan:\localhost\Service\Auth\Kerberos' $true 'winrm/config/service/auth' 'Kerberos' } catch {}

$dnsNames = New-Object System.Collections.Generic.List[string]
[void]$dnsNames.Add($env:COMPUTERNAME)
[void]$dnsNames.Add('localhost')
$ipAddresses = New-Object System.Collections.Generic.List[string]
try {
    Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Where-Object { $_.IPAddress -notlike '127.*' -and $_.IPAddress -notlike '169.254.*' } |
        ForEach-Object {
            if (-not $ipAddresses.Contains($_.IPAddress)) {
                [void]$ipAddresses.Add($_.IPAddress)
            }
        }
} catch {}

$sanParts = @($dnsNames | ForEach-Object { 'DNS=' + $_ })
$sanParts += @($ipAddresses | ForEach-Object { 'IPAddress=' + $_ })
$sanExtension = '2.5.29.17={text}' + ($sanParts -join '&')

function Test-WinRMCertificate([object]$Candidate, [string[]]$RequiredIpAddresses) {
    if (-not $Candidate -or -not $Candidate.HasPrivateKey -or $Candidate.NotAfter -le (Get-Date).AddDays(30)) {
        return $false
    }
    $san = $Candidate.Extensions |
        Where-Object { $_.Oid.Value -eq '2.5.29.17' } |
        Select-Object -First 1
    if (-not $san) {
        return $false
    }
    try {
        $dnsNames = @($Candidate.DnsNameList | ForEach-Object {
            if ($_.Unicode) { [string]$_.Unicode } else { [string]$_ }
        })
    } catch {
        return $false
    }
    $formattedSan = $san.Format($true)
    foreach ($ipAddress in $RequiredIpAddresses) {
        if ($dnsNames -contains $ipAddress) {
            # The legacy setup encoded IP literals as dNSName values.
            return $false
        }
        if ($formattedSan -notmatch [regex]::Escape($ipAddress)) {
            return $false
        }
    }
    return $true
}

$certificate = Get-ChildItem Cert:\LocalMachine\My -ErrorAction SilentlyContinue |
    Where-Object {
        $_.HasPrivateKey -and
        $_.NotAfter -gt (Get-Date).AddDays(30) -and
        $_.Subject -match ('CN=' + [regex]::Escape($env:COMPUTERNAME)) -and
        (Test-WinRMCertificate $_ @($ipAddresses))
    } |
    Sort-Object NotAfter -Descending |
    Select-Object -First 1
if (-not $certificate) {
    $certParams = @{
        Subject = ('CN=' + $env:COMPUTERNAME)
        TextExtension = @($sanExtension)
        CertStoreLocation = 'Cert:\LocalMachine\My'
        KeyAlgorithm = 'RSA'
        KeyLength = 2048
        HashAlgorithm = 'SHA256'
        NotAfter = (Get-Date).AddYears(2)
        FriendlyName = 'DecentraLabs Lab Station WinRM'
    }
    $certificate = New-SelfSignedCertificate @certParams
}
if (-not $certificate -or -not $certificate.Thumbprint) {
    throw 'Unable to create or locate a WinRM HTTPS certificate'
}
$certificateDir = Join-Path $env:ProgramData 'DecentraLabs\Lab Station'
New-Item -ItemType Directory -Path $certificateDir -Force | Out-Null
$certificateExport = Join-Path $certificateDir 'winrm-server.cer'
Export-Certificate -Cert $certificate -FilePath $certificateExport -Force | Out-Null
Write-Output ('WinRM certificate thumbprint: ' + $certificate.Thumbprint)
Write-Output ('WinRM certificate export: ' + $certificateExport)

try {
    Get-ChildItem WSMan:\localhost\Listener -ErrorAction SilentlyContinue |
        Where-Object { $_.Keys -match 'Transport=HTTP|Transport=HTTPS' } |
        Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
} catch {}
New-Item -Path 'WSMan:\localhost\Listener' -Transport HTTPS -Address '*' -Hostname $env:COMPUTERNAME -CertificateThumbprint $certificate.Thumbprint -Force | Out-Null

Start-Service -Name WinRM
# LabStation-WinRM-HTTPS on TCP 5986 is created with Gateway source filters by Lab Station after this script.

function Test-LocalUserCompat([string]$Name) {
    try { return [bool](Get-LocalUser -Name $Name -ErrorAction Stop) } catch {}
    try {
        $safeName = $Name.Replace("'", "''")
        $user = Get-CimInstance Win32_UserAccount -Filter ("LocalAccount=True AND Name='" + $safeName + "'") -ErrorAction Stop | Select-Object -First 1
        if ($user) { return $true }
    } catch {}
    $oldPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        & net.exe user $Name 1>$null 2>$null
        return $LASTEXITCODE -eq 0
    } finally {
        $ErrorActionPreference = $oldPreference
    }
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
            New-LocalUser -Name $Name -Password $secure -PasswordNeverExpires -AccountNeverExpires -Description 'DecentraLabs Lab Gateway WinRM account' | Out-Null
        } catch {
            $oldPreference = $ErrorActionPreference
            $ErrorActionPreference = 'Continue'
            & net.exe user $Name $PlainPassword /add /expires:never /passwordchg:no 1>$null 2>$null
            $ErrorActionPreference = $oldPreference
            if ($LASTEXITCODE -ne 0) { throw ('net user add failed with exit code ' + $LASTEXITCODE) }
        }
    } else {
        try {
            Set-LocalUser -Name $Name -Password $secure -PasswordNeverExpires $true -Description 'DecentraLabs Lab Gateway WinRM account'
            Enable-LocalUser -Name $Name -ErrorAction SilentlyContinue | Out-Null
        } catch {
            $oldPreference = $ErrorActionPreference
            $ErrorActionPreference = 'Continue'
            & net.exe user $Name $PlainPassword /active:yes /expires:never /passwordchg:no 1>$null 2>$null
            $ErrorActionPreference = $oldPreference
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
        $oldPreference = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        & net.exe localgroup $groupName $Member /add 1>$null 2>$null
        $ErrorActionPreference = $oldPreference
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
