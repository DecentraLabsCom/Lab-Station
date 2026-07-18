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
    static HttpsPort := 5986

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
            certificateInfo := Trim(capture["stdout"])
            if (certificateInfo != "")
                LS_LogInfo(certificateInfo)
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
`$httpsListener = `$listenerText -match '(?im)Transport\s*=\s*HTTPS'
`$httpsPort = `$listenerText -match '(?im)Port\s*=\s*5986'
`$httpListener = `$listenerText -match '(?im)Transport\s*=\s*HTTP\s*$'
`$certificateConfigured = `$listenerText -match '(?im)Certificate\s*=\s*\S+'
`$firewall = `$false
try {
    $rule = Get-NetFirewallRule -Name 'WINRM-HTTPS-In-TCP*','LabStation-WinRM-HTTPS' -ErrorAction SilentlyContinue |
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
        $firewall = ($netsh -match '5986') -and ($netsh -match '(?i)(Enabled|Habilitada|Habilitado)\s*:\s*(Yes|S[ií])')
    } catch {}
}
if (-not $firewall) {
try {
    $httpsNetsh = (& netsh advfirewall firewall show rule name='Lab Station WinRM HTTPS' 2>$null) -join [Environment]::NewLine
    $firewall = ($httpsNetsh -match '5986') -and ($httpsNetsh -match '(?i)(Enabled|Habilitada|Habilitado)')
} catch {}
}
$allowUnencrypted = $false
$negotiateAuth = $false
try { $allowUnencrypted = [bool](Get-Item WSMan:\localhost\Service\AllowUnencrypted -ErrorAction SilentlyContinue).Value } catch {}
try { $negotiateAuth = [bool](Get-Item WSMan:\localhost\Service\Auth\Negotiate -ErrorAction SilentlyContinue).Value } catch {}
[pscustomobject]@{
    serviceInstalled = [bool]$svc
    serviceRunning = ($svc.Status -eq 'Running')
    serviceStartType = [string]$svc.StartType
    httpListener = [bool]$httpListener
    httpsListener = [bool]$httpsListener
    httpsPort = [bool]$httpsPort
    certificateConfigured = [bool]$certificateConfigured
    firewallEnabled = [bool]$firewall
    allowUnencrypted = [bool]$allowUnencrypted
    negotiateAuth = [bool]$negotiateAuth
    ntlmAuth = [bool]$negotiateAuth
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
                "httpsListener", false,
                "httpsPort", false,
                "certificateConfigured", false,
                "firewallEnabled", false,
                "allowUnencrypted", false,
                "negotiateAuth", false,
                "ntlmAuth", false,
                "ready", false
            )
        }
        try {
            status := LS_ParseJson(capture["stdout"])
            status["ready"] := (
                status["serviceRunning"]
                && status["httpsListener"]
                && status["httpsPort"]
                && status["certificateConfigured"]
                && status["firewallEnabled"]
                && !status["allowUnencrypted"]
                && status["negotiateAuth"]
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
& winrm quickconfig -quiet | Out-Null
Enable-PSRemoting -Force -SkipNetworkProfileCheck | Out-Null
Set-WinRMConfigBool 'WSMan:\localhost\Service\AllowUnencrypted' $false 'winrm/config/service' 'AllowUnencrypted'
Set-WinRMConfigBool 'WSMan:\localhost\Service\Auth\Negotiate' $true 'winrm/config/service/auth' 'Negotiate'
try { Set-WinRMConfigBool 'WSMan:\localhost\Service\Auth\Basic' $false 'winrm/config/service/auth' 'Basic' } catch {}
try { Set-WinRMConfigBool 'WSMan:\localhost\Service\Auth\Kerberos' $true 'winrm/config/service/auth' 'Kerberos' } catch {}

$dnsNames = New-Object System.Collections.Generic.List[string]
[void]$dnsNames.Add($env:COMPUTERNAME)
[void]$dnsNames.Add('localhost')
try {
    Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Where-Object { $_.IPAddress -notlike '127.*' -and $_.IPAddress -notlike '169.254.*' } |
        ForEach-Object { [void]$dnsNames.Add($_.IPAddress) }
} catch {}
$certificate = Get-ChildItem Cert:\LocalMachine\My -ErrorAction SilentlyContinue |
    Where-Object {
        $_.HasPrivateKey -and
        $_.NotAfter -gt (Get-Date).AddDays(30) -and
        $_.Subject -match ('CN=' + [regex]::Escape($env:COMPUTERNAME))
    } |
    Sort-Object NotAfter -Descending |
    Select-Object -First 1
if (-not $certificate) {
    $certificate = New-SelfSignedCertificate -DnsName ($dnsNames | Select-Object -Unique) -CertStoreLocation 'Cert:\LocalMachine\My' -KeyAlgorithm RSA -KeyLength 2048 -HashAlgorithm SHA256 -NotAfter (Get-Date).AddYears(2) -FriendlyName 'DecentraLabs Lab Station WinRM'
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
        Where-Object { $_.Keys -match 'Transport=HTTP' } |
        Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
} catch {}
try {
    Get-ChildItem WSMan:\localhost\Listener -ErrorAction SilentlyContinue |
        Where-Object { $_.Keys -match 'Transport=HTTPS' } |
        Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
} catch {}
New-Item -Path 'WSMan:\localhost\Listener' -Transport HTTPS -Address '*' -Hostname $env:COMPUTERNAME -CertificateThumbprint $certificate.Thumbprint -Force | Out-Null

try {
    Disable-NetFirewallRule -Name 'WINRM-HTTP-In-TCP*' -ErrorAction SilentlyContinue
    Remove-NetFirewallRule -Name 'LabStation-WinRM-HTTP' -ErrorAction SilentlyContinue
} catch {}
try {
    Remove-NetFirewallRule -Name 'LabStation-WinRM-HTTPS' -ErrorAction SilentlyContinue
    New-NetFirewallRule -Name 'LabStation-WinRM-HTTPS' -DisplayName 'Lab Station WinRM HTTPS' -Direction Inbound -Action Allow -Protocol TCP -LocalPort 5986 -Profile Domain,Private -ErrorAction SilentlyContinue | Out-Null
} catch {
    netsh advfirewall firewall add rule name='Lab Station WinRM HTTPS' dir=in action=allow protocol=TCP localport=5986 profile=domain,private | Out-Null
}
Start-Service -Name WinRM

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
