; ============================================================================
; Lab Station - Account management helpers
; ============================================================================
#Requires AutoHotkey v2.0
#Include ..\core\Config.ahk
#Include ..\core\Logger.ahk
#Include ..\core\Admin.ahk
#Include ..\core\Shell.ahk

class LS_AccountManager {
    static DefaultUser := "LABUSER"

    static Setup(user, &password) {
        if (!LS_EnsureAdmin()) {
            return false
        }
        if (!user || user = "") {
            user := this.DefaultUser
        }
        localPass := password
        if (!this.EnsureAccount(user, &localPass)) {
            return false
        }
        if (!this.ConfigureAutologon(user, localPass)) {
            return false
        }
        password := localPass
        return this.ApplyLockdown(user)
    }

    static EnsureAccount(user, &password) {
        if (!LS_EnsureAdmin()) {
            return false
        }
        if (!user || user = "") {
            user := this.DefaultUser
        }
        localPassword := password && password != "" ? password : this.GeneratePassword()
        escapedUser := this.EscapeForPSSingleQuote(user)
        escapedPassword := this.EscapeForPSSingleQuote(localPassword)
        script := "
        (
`$ErrorActionPreference = 'Stop'
`$User = '__LABUSER__'
`$Password = '__LABUSER_PASSWORD__'

function Test-LocalUserCompat([string]`$Name) {
    try { return [bool](Get-LocalUser -Name `$Name -ErrorAction Stop) } catch {}
    try {
        `$safeName = `$Name.Replace("'", "''")
        `$user = Get-CimInstance Win32_UserAccount -Filter ("LocalAccount=True AND Name='" + `$safeName + "'") -ErrorAction Stop | Select-Object -First 1
        if (`$user) { return `$true }
    } catch {}
    `$oldPreference = `$ErrorActionPreference
    `$ErrorActionPreference = 'Continue'
    try {
        & net.exe user `$Name 1>`$null 2>`$null
        return `$LASTEXITCODE -eq 0
    } finally {
        `$ErrorActionPreference = `$oldPreference
    }
}

function Set-LocalUserWithAdsi([string]`$Name, [string]`$PlainPassword) {
    `$created = `$false
    try {
        `$computer = [ADSI]('WinNT://' + `$env:COMPUTERNAME + ',computer')
        try {
            `$user = [ADSI]('WinNT://' + `$env:COMPUTERNAME + '/' + `$Name + ',user')
        } catch {
            `$user = `$computer.Create('user', `$Name)
            `$created = `$true
            `$user.SetInfo()
        }
        `$user.SetPassword(`$PlainPassword)
        `$user.Put('Description', 'DecentraLabs Lab Station service account')
        try {
            `$flags = [int]`$user.UserFlags.Value
        } catch {
            `$flags = 0x0200
        }
        `$flags = (`$flags -bor 0x0200 -bor 0x10000) -band (-bnot 0x0002)
        `$user.Put('UserFlags', `$flags)
        `$user.SetInfo()
        return `$true
    } catch {
        if (`$created) {
            try { ([ADSI]('WinNT://' + `$env:COMPUTERNAME + ',computer')).Delete('user', `$Name) } catch {}
        }
        Write-Output ('ADSI user setup failed: ' + `$_.Exception.Message)
        return `$false
    }
}

function Ensure-LocalUserCompat([string]`$Name, [string]`$PlainPassword) {
    `$secure = ConvertTo-SecureString `$PlainPassword -AsPlainText -Force
    if (-not (Test-LocalUserCompat `$Name)) {
        `$created = `$false
        try {
            New-LocalUser -Name `$Name -Password `$secure -PasswordNeverExpires `$true -AccountNeverExpires `$true -Description 'DecentraLabs Lab Station service account' -UserMayNotChangePassword `$true | Out-Null
            `$created = `$true
        } catch {
            Write-Output ('New-LocalUser failed: ' + `$_.Exception.Message)
        }
        if (-not `$created) {
            `$oldPreference = `$ErrorActionPreference
            `$ErrorActionPreference = 'Continue'
            & net.exe user `$Name `$PlainPassword /add /expires:never /passwordchg:no 1>`$null 2>`$null
            `$ErrorActionPreference = `$oldPreference
            if (`$LASTEXITCODE -eq 0) { `$created = `$true } else { Write-Output ('net user add failed with exit code ' + `$LASTEXITCODE) }
        }
        if (-not `$created) {
            `$created = Set-LocalUserWithAdsi `$Name `$PlainPassword
        }
        if (-not `$created) { throw ('Unable to create local user ' + `$Name + ' with New-LocalUser, net user, or ADSI') }
    } else {
        `$updated = `$false
        try {
            Set-LocalUser -Name `$Name -Password `$secure -PasswordNeverExpires `$true -Description 'DecentraLabs Lab Station service account'
            Enable-LocalUser -Name `$Name -ErrorAction SilentlyContinue | Out-Null
            `$updated = `$true
        } catch {
            Write-Output ('Set-LocalUser failed: ' + `$_.Exception.Message)
        }
        if (-not `$updated) {
            `$oldPreference = `$ErrorActionPreference
            `$ErrorActionPreference = 'Continue'
            & net.exe user `$Name `$PlainPassword /active:yes /expires:never /passwordchg:no 1>`$null 2>`$null
            `$ErrorActionPreference = `$oldPreference
            if (`$LASTEXITCODE -eq 0) { `$updated = `$true } else { Write-Output ('net user update failed with exit code ' + `$LASTEXITCODE) }
        }
        if (-not `$updated) {
            `$updated = Set-LocalUserWithAdsi `$Name `$PlainPassword
        }
        if (-not `$updated) { throw ('Unable to update local user ' + `$Name + ' with Set-LocalUser, net user, or ADSI') }
    }
    try {
        `$oldPreference = `$ErrorActionPreference
        `$ErrorActionPreference = 'Continue'
        & net.exe user `$Name /active:yes /expires:never /passwordchg:no 1>`$null 2>`$null
        `$ErrorActionPreference = `$oldPreference
    } catch {}
    if (-not (Test-LocalUserCompat `$Name)) { throw ('Local user ' + `$Name + ' was not created') }
}
function Get-AdsiLocalGroupBySid([string]`$GroupSid) {
    try {
        `$computer = [ADSI]('WinNT://' + `$env:COMPUTERNAME + ',computer')
        foreach (`$child in `$computer.Children) {
            try {
                if (`$child.SchemaClassName -ne 'Group') { continue }
                `$sid = New-Object System.Security.Principal.SecurityIdentifier(`$child.objectSid.Value, 0)
                if (`$sid.Value -eq `$GroupSid) { return `$child }
            } catch {}
        }
    } catch {}
    return `$null
}

function Get-CimLocalGroupBySid([string]`$GroupSid) {
    try { return Get-CimInstance Win32_Group -Filter ("SID='" + `$GroupSid.Replace("'", "''") + "'") -ErrorAction Stop | Select-Object -First 1 } catch {}
    try { return Get-WmiObject Win32_Group -Filter ("SID='" + `$GroupSid.Replace("'", "''") + "'") -ErrorAction Stop | Select-Object -First 1 } catch {}
    return `$null
}

function Get-CimLocalUser([string]`$Name) {
    `$safeName = `$Name.Replace("'", "''")
    try { return Get-CimInstance Win32_UserAccount -Filter ("LocalAccount=True AND Name='" + `$safeName + "'") -ErrorAction Stop | Select-Object -First 1 } catch {}
    try { return Get-WmiObject Win32_UserAccount -Filter ("LocalAccount=True AND Name='" + `$safeName + "'") -ErrorAction Stop | Select-Object -First 1 } catch {}
    return `$null
}

function Add-LocalGroupMemberBySidCim([string]`$GroupSid, [string]`$Member) {
    `$group = Get-CimLocalGroupBySid `$GroupSid
    `$user = Get-CimLocalUser `$Member
    if (-not `$group -or -not `$user) { return `$false }
    try {
        `$groupPath = 'WinNT://' + `$group.Domain + '/' + `$group.Name + ',group'
        `$userPath = 'WinNT://' + `$user.Domain + '/' + `$user.Name + ',user'
        `$adsiGroup = [ADSI]`$groupPath
        try {
            if (`$adsiGroup.psbase.Invoke('IsMember', `$userPath)) { return `$true }
        } catch {}
        `$adsiGroup.Add(`$userPath)
        return `$true
    } catch {
        if (`$_.Exception.Message -match 'already.*member|ya.*miembro') { return `$true }
    }
    return `$false
}

function Test-LocalGroupMemberBySidCim([string]`$GroupSid, [string]`$Member) {
    `$group = Get-CimLocalGroupBySid `$GroupSid
    `$user = Get-CimLocalUser `$Member
    if (-not `$group -or -not `$user) { return `$false }
    try {
        `$groupPath = 'WinNT://' + `$group.Domain + '/' + `$group.Name + ',group'
        `$userPath = 'WinNT://' + `$user.Domain + '/' + `$user.Name + ',user'
        return [bool]([ADSI]`$groupPath).psbase.Invoke('IsMember', `$userPath)
    } catch {}
    return `$false
}

function Add-LocalGroupMemberCompat([string]`$GroupSid, [string]`$Member) {
    `$sid = New-Object System.Security.Principal.SecurityIdentifier(`$GroupSid)
    `$groupName = `$sid.Translate([System.Security.Principal.NTAccount]).Value.Split('\')[-1]
    `$memberSid = ''
    try { `$memberSid = (Get-LocalUser -Name `$Member -ErrorAction Stop).SID.Value } catch {}
    `$memberCandidates = @(`$Member, ('.\' + `$Member), (`$env:COMPUTERNAME + '\' + `$Member))
    if (`$memberSid) { `$memberCandidates += `$memberSid }
    try {
        `$localGroupName = (Get-LocalGroup -SID `$GroupSid -ErrorAction Stop).Name
        foreach (`$candidate in `$memberCandidates) {
            try { Add-LocalGroupMember -Group `$localGroupName -Member `$candidate -ErrorAction Stop; return } catch {
                if (`$_.Exception.Message -match 'already.*member|ya.*miembro') { return }
            }
        }
    } catch {}
    foreach (`$candidate in `$memberCandidates) {
        `$oldPreference = `$ErrorActionPreference
        `$ErrorActionPreference = 'Continue'
        & net.exe localgroup `$groupName `$candidate /add 1>`$null 2>`$null
        `$ErrorActionPreference = `$oldPreference
        if (`$LASTEXITCODE -eq 0) { return }
    }
    try {
        `$group = Get-AdsiLocalGroupBySid `$GroupSid
        if (`$group) {
            `$group.Add('WinNT://' + `$env:COMPUTERNAME + '/' + `$Member + ',user')
            return
        }
    } catch {
        if (`$_.Exception.Message -match 'already.*member|ya.*miembro') { return }
    }
    try {
        `$group = [ADSI]('WinNT://./' + `$groupName + ',group')
        `$group.Add('WinNT://./' + `$Member + ',user')
        return
    } catch {}
    if (Add-LocalGroupMemberBySidCim `$GroupSid `$Member) { return }
    throw ('Unable to add ' + `$Member + ' to ' + `$groupName)
}

function Test-LocalGroupMemberCompat([string]`$GroupSid, [string]`$Member) {
    `$sid = New-Object System.Security.Principal.SecurityIdentifier(`$GroupSid)
    `$groupName = `$sid.Translate([System.Security.Principal.NTAccount]).Value.Split('\')[-1]
    `$memberSid = ''
    try { `$memberSid = (Get-LocalUser -Name `$Member -ErrorAction Stop).SID.Value } catch {}
    try {
        `$localGroupName = (Get-LocalGroup -SID `$GroupSid -ErrorAction Stop).Name
        `$members = Get-LocalGroupMember -Group `$localGroupName -ErrorAction Stop
        foreach (`$entry in `$members) {
            if (`$memberSid -and `$entry.SID -and `$entry.SID.Value -eq `$memberSid) { return `$true }
            if (`$entry.Name -and `$entry.Name.Split('\')[-1].ToLowerInvariant() -eq `$Member.ToLowerInvariant()) { return `$true }
        }
    } catch {}
    try {
        `$group = Get-AdsiLocalGroupBySid `$GroupSid
        if (`$group) {
            `$members = `$group.psbase.Invoke('Members')
            foreach (`$entry in `$members) {
                try {
                    `$entrySid = New-Object System.Security.Principal.SecurityIdentifier(`$entry.GetType().InvokeMember('objectSid', 'GetProperty', `$null, `$entry, `$null), 0)
                    if (`$memberSid -and `$entrySid.Value -eq `$memberSid) { return `$true }
                } catch {}
                try {
                    `$entryName = `$entry.GetType().InvokeMember('Name', 'GetProperty', `$null, `$entry, `$null)
                    if (`$entryName -and `$entryName.ToLowerInvariant() -eq `$Member.ToLowerInvariant()) { return `$true }
                } catch {}
            }
        }
    } catch {}
    try {
        `$group = [ADSI]('WinNT://./' + `$groupName + ',group')
        if (`$group.psbase.Invoke('IsMember', ('WinNT://./' + `$Member + ',user'))) { return `$true }
    } catch {}
    if (Test-LocalGroupMemberBySidCim `$GroupSid `$Member) { return `$true }
    `$oldPreference = `$ErrorActionPreference
    `$ErrorActionPreference = 'Continue'
    `$netLines = & net.exe localgroup `$groupName 2>`$null
    `$ErrorActionPreference = `$oldPreference
    `$netText = (`$netLines | Where-Object { `$_ -notmatch '(?i)(command completed|comando.*complet|se ha completado)' }) -join "`n"
    return (`$netText -match ('(^|\s|\\)' + [regex]::Escape(`$Member) + '(\s|$)'))
}

function Remove-LocalGroupMemberCompat([string]`$GroupSid, [string]`$Member) {
    try {
        `$groupName = (Get-LocalGroup -SID `$GroupSid -ErrorAction Stop).Name
        Remove-LocalGroupMember -Group `$groupName -Member `$Member -ErrorAction SilentlyContinue
        return
    } catch {}
    try {
        `$sid = New-Object System.Security.Principal.SecurityIdentifier(`$GroupSid)
        `$groupName = `$sid.Translate([System.Security.Principal.NTAccount]).Value.Split('\')[-1]
        `$oldPreference = `$ErrorActionPreference
        `$ErrorActionPreference = 'Continue'
        & net.exe localgroup `$groupName `$Member /delete 1>`$null 2>`$null
        `$ErrorActionPreference = `$oldPreference
    } catch {}
}

Ensure-LocalUserCompat `$User `$Password
Add-LocalGroupMemberCompat 'S-1-5-32-545' `$User
Add-LocalGroupMemberCompat 'S-1-5-32-555' `$User
Remove-LocalGroupMemberCompat 'S-1-5-32-544' `$User
`$rdpGroup = (New-Object System.Security.Principal.SecurityIdentifier('S-1-5-32-555')).Translate([System.Security.Principal.NTAccount]).Value.Split('\')[-1]
if (-not (Test-LocalUserCompat `$User)) {
    throw ('Local user ' + `$User + ' was not created or could not be verified')
}
if (-not (Test-LocalGroupMemberCompat 'S-1-5-32-555' `$User)) {
    throw ('Local user ' + `$User + ' is not listed in ' + `$rdpGroup)
}
'LABSTATION_ACCOUNT_READY'
exit 0
        )"
        script := StrReplace(script, "__LABUSER__", escapedUser)
        script := StrReplace(script, "__LABUSER_PASSWORD__", escapedPassword)
        capture := LS_RunPowerShellCapture(script, "Configure lab service account", 60000)
        exitCode := capture["exitCode"]
        if (exitCode = 0 && InStr(capture["stdout"], "LABSTATION_ACCOUNT_READY") > 0 && this.AccountExists(user)) {
            password := localPassword
            LS_LogInfo(Format("Account {1} created/updated", user))
            return true
        }
        detail := Trim(capture["stderr"] != "" ? capture["stderr"] : capture["stdout"])
        if (detail != "")
            LS_LogError(Format("Unable to create/configure account {1} (exit={2}): {3}", user, exitCode, detail))
        else
            LS_LogError(Format("Unable to create/configure account {1} (exit={2})", user, exitCode))
        return false
    }

    static ConfigureAutologon(user, password, domain := "") {
        if (!LS_EnsureAdmin()) {
            return false
        }
        if (!user || user = "") {
            user := this.DefaultUser
        }
        if (!password || password = "") {
            LS_LogError("Password required to configure Autologon")
            return false
        }
        key := "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon"
        try {
            RegWrite("1", "REG_SZ", key, "AutoAdminLogon")
            RegWrite(user, "REG_SZ", key, "DefaultUserName")
            RegWrite(password, "REG_SZ", key, "DefaultPassword")
            RegWrite(domain, "REG_SZ", key, "DefaultDomainName")
            RegWrite("1", "REG_DWORD", key, "ForceAutoLogon")
            RegWrite("0", "REG_DWORD", key, "DisableCAD")
            LS_LogInfo("Autologon configured successfully")
            return true
        } catch as e {
            LS_LogError("Error configuring Autologon: " . e.Message)
            return false
        }
    }

    static ApplyLockdown(user := "") {
        if (!LS_EnsureAdmin()) {
            return false
        }
        if (!user || user = "") {
            user := this.DefaultUser
        }
        ok := true
        ok := this.EnsureRemoteDesktopRestrictions(user) && ok
        ok := this.ConfigureDenyInteractiveLogon(user) && ok
        ok := this.RefreshAutologonState(user) && ok
        if (ok) {
            LS_LogInfo("Lockdown applied")
        } else {
            LS_LogWarning("Lockdown completed with warnings")
        }
        return ok
    }

    static EnsureRemoteDesktopRestrictions(user) {
        escaped := this.EscapeForPSSingleQuote(user)
        template := "
        (
`$ErrorActionPreference = 'Stop'
`$User = '__LABUSER__'

function Normalize-LocalName([string]`$Name) {
    if (-not `$Name) { return '' }
    return (`$Name.Split('\')[-1]).ToLowerInvariant()
}

function Get-LocalGroupNameCompat([string]`$GroupSid, [string]`$Fallback) {
    try { return (Get-CimInstance Win32_Group -Filter ("SID='" + `$GroupSid.Replace("'", "''") + "'") -ErrorAction Stop | Select-Object -First 1).Name } catch {}
    try { return (Get-WmiObject Win32_Group -Filter ("SID='" + `$GroupSid.Replace("'", "''") + "'") -ErrorAction Stop | Select-Object -First 1).Name } catch {}
    try { return (Get-LocalGroup -SID `$GroupSid -ErrorAction Stop).Name } catch {}
    try {
        `$sid = New-Object System.Security.Principal.SecurityIdentifier(`$GroupSid)
        return `$sid.Translate([System.Security.Principal.NTAccount]).Value.Split('\')[-1]
    } catch {
        return `$Fallback
    }
}

function Get-CimLocalGroupBySid([string]`$GroupSid) {
    try { return Get-CimInstance Win32_Group -Filter ("SID='" + `$GroupSid.Replace("'", "''") + "'") -ErrorAction Stop | Select-Object -First 1 } catch {}
    try { return Get-WmiObject Win32_Group -Filter ("SID='" + `$GroupSid.Replace("'", "''") + "'") -ErrorAction Stop | Select-Object -First 1 } catch {}
    return `$null
}

function Get-CimLocalUser([string]`$Name) {
    `$safeName = `$Name.Replace("'", "''")
    try { return Get-CimInstance Win32_UserAccount -Filter ("LocalAccount=True AND Name='" + `$safeName + "'") -ErrorAction Stop | Select-Object -First 1 } catch {}
    try { return Get-WmiObject Win32_UserAccount -Filter ("LocalAccount=True AND Name='" + `$safeName + "'") -ErrorAction Stop | Select-Object -First 1 } catch {}
    return `$null
}

function Add-LocalGroupMemberBySidCim([string]`$GroupSid, [string]`$Member) {
    `$group = Get-CimLocalGroupBySid `$GroupSid
    `$user = Get-CimLocalUser `$Member
    if (-not `$group -or -not `$user) { return `$false }
    try {
        `$groupPath = 'WinNT://' + `$group.Domain + '/' + `$group.Name + ',group'
        `$userPath = 'WinNT://' + `$user.Domain + '/' + `$user.Name + ',user'
        `$adsiGroup = [ADSI]`$groupPath
        try {
            if (`$adsiGroup.psbase.Invoke('IsMember', `$userPath)) { return `$true }
        } catch {}
        `$adsiGroup.Add(`$userPath)
        return `$true
    } catch {
        if (`$_.Exception.Message -match 'already.*member|ya.*miembro') { return `$true }
    }
    return `$false
}

function Test-LocalGroupMemberBySidCim([string]`$GroupSid, [string]`$Member) {
    `$group = Get-CimLocalGroupBySid `$GroupSid
    `$user = Get-CimLocalUser `$Member
    if (-not `$group -or -not `$user) { return `$false }
    try {
        `$groupPath = 'WinNT://' + `$group.Domain + '/' + `$group.Name + ',group'
        `$userPath = 'WinNT://' + `$user.Domain + '/' + `$user.Name + ',user'
        return [bool]([ADSI]`$groupPath).psbase.Invoke('IsMember', `$userPath)
    } catch {}
    return `$false
}

function Add-LocalGroupMemberCompat([string]`$Group, [string]`$Member) {
    `$memberSid = ''
    try { `$memberSid = (Get-LocalUser -Name `$Member -ErrorAction Stop).SID.Value } catch {}
    `$memberCandidates = @(`$Member, ('.\' + `$Member), (`$env:COMPUTERNAME + '\' + `$Member))
    if (`$memberSid) { `$memberCandidates += `$memberSid }
    try {
        foreach (`$candidate in `$memberCandidates) {
            try { Add-LocalGroupMember -Group `$Group -Member `$candidate -ErrorAction Stop; return } catch {
                if (`$_.Exception.Message -match 'already.*member|ya.*miembro') { return }
            }
        }
    } catch {}
    foreach (`$candidate in `$memberCandidates) {
        `$oldPreference = `$ErrorActionPreference
        `$ErrorActionPreference = 'Continue'
        & net.exe localgroup `$Group `$candidate /add 1>`$null 2>`$null
        `$ErrorActionPreference = `$oldPreference
        if (`$LASTEXITCODE -eq 0) { return }
    }
    try {
        `$adsiGroup = [ADSI]('WinNT://./' + `$Group + ',group')
        `$adsiGroup.Add('WinNT://./' + `$Member + ',user')
        return
    } catch {}
    if (Add-LocalGroupMemberBySidCim 'S-1-5-32-555' `$Member) { return }
    throw ('Unable to add ' + `$Member + ' to ' + `$Group)
}

function Test-LocalGroupMemberCompat([string]`$Group, [string]`$Member) {
    `$memberSid = ''
    try { `$memberSid = (Get-LocalUser -Name `$Member -ErrorAction Stop).SID.Value } catch {}
    try {
        `$members = Get-LocalGroupMember -Group `$Group -ErrorAction Stop
        foreach (`$entry in `$members) {
            if (`$memberSid -and `$entry.SID -and `$entry.SID.Value -eq `$memberSid) { return `$true }
            if (`$entry.Name -and `$entry.Name.Split('\')[-1].ToLowerInvariant() -eq `$Member.ToLowerInvariant()) { return `$true }
        }
    } catch {}
    try {
        `$adsiGroup = [ADSI]('WinNT://./' + `$Group + ',group')
        if (`$adsiGroup.psbase.Invoke('IsMember', ('WinNT://./' + `$Member + ',user'))) { return `$true }
    } catch {}
    if (Test-LocalGroupMemberBySidCim 'S-1-5-32-555' `$Member) { return `$true }
    `$oldPreference = `$ErrorActionPreference
    `$ErrorActionPreference = 'Continue'
    `$netLines = & net.exe localgroup `$Group 2>`$null
    `$ErrorActionPreference = `$oldPreference
    `$netText = (`$netLines | Where-Object { `$_ -notmatch '(?i)(command completed|comando.*complet|se ha completado)' }) -join "`n"
    return (`$netText -match ('(^|\s|\\)' + [regex]::Escape(`$Member) + '(\s|$)'))
}

`$group = Get-LocalGroupNameCompat 'S-1-5-32-555' 'Remote Desktop Users'
`$targetLower = Normalize-LocalName `$User
Add-LocalGroupMemberCompat `$group `$User
`$members = Get-LocalGroupMember -Group `$group -ErrorAction SilentlyContinue
foreach (`$member in `$members) {
    `$memberLower = Normalize-LocalName `$member.Name
    if (`$member.ObjectClass -eq 'User' -and `$memberLower -ne `$targetLower) {
        try { Remove-LocalGroupMember -Group `$group -Member `$member.Name -ErrorAction SilentlyContinue } catch {}
    }
}
Add-LocalGroupMemberCompat `$group `$User
`$oldPreference = `$ErrorActionPreference
`$ErrorActionPreference = 'Continue'
`$finalMembers = & net.exe localgroup `$group 2>`$null
`$ErrorActionPreference = `$oldPreference
if (-not (Test-LocalGroupMemberCompat `$group `$User)) {
    throw ('Local user ' + `$User + ' is not listed in ' + `$group)
}
try {
    Set-ItemProperty -Path 'HKLM:\\SYSTEM\\CurrentControlSet\\Control\\Terminal Server' -Name 'fDenyTSConnections' -Value 0
    New-ItemProperty -Path 'HKLM:\\SOFTWARE\\Microsoft\\Windows NT\\CurrentVersion\\Winlogon' -Name 'DisableLockWorkstation' -Value 1 -PropertyType DWORD -Force | Out-Null
} catch {}
        )"
        script := StrReplace(template, "__LABUSER__", escaped)
        exitCode := LS_RunPowerShell(script, "Restrict Remote Desktop users")
        if (exitCode != 0) {
            LS_LogError("Unable to adjust Remote Desktop Users membership (exit=" . exitCode . ")")
            return false
        }
        return true
    }

    static ConfigureDenyInteractiveLogon(user) {
        script := this.BuildDenyInteractiveScript(user)
        exitCode := LS_RunPowerShell(script, "Configure SeDenyInteractiveLogonRight")
        if (exitCode != 0) {
            LS_LogError("Unable to apply SeDenyInteractiveLogonRight (exit=" . exitCode . ")")
            return false
        }
        return true
    }

    static BuildDenyInteractiveScript(user) {
        escaped := this.EscapeForPSSingleQuote(user)
        template := "
        (
`$ErrorActionPreference = 'Stop'
`$target = '__LABUSER__'
`$targetLower = `$target.ToLower()
`$exempt = @('__LABUSER__','Administrator','DefaultAccount','WDAGUtilityAccount','Guest') | ForEach-Object { `$_.ToLower() }
`$localUsers = Get-LocalUser -ErrorAction SilentlyContinue
`$targetSid = ''
try { `$targetSid = (`$localUsers | Where-Object { `$_.Name -eq `$target } | Select-Object -First 1).SID.Value } catch {}
`$denySids = New-Object System.Collections.Generic.List[string]
`$tempExport = Join-Path `$env:TEMP ('ls-secexport-' + [guid]::NewGuid().Guid + '.inf')
secedit /export /cfg `$tempExport /areas USER_RIGHTS | Out-Null
if (Test-Path `$tempExport) {
    foreach (`$line in Get-Content `$tempExport) {
        if (`$line -match '^SeDenyInteractiveLogonRight\s*=\s*(.*)$') {
            `$tokens = `$Matches[1].Split(',')
            foreach (`$token in `$tokens) {
                `$t = `$token.Trim()
                if (-not `$t) { continue }
                if (`$targetSid -and `$t -eq ('*' + `$targetSid)) { continue }
                if (`$t.ToLower() -eq `$targetLower) { continue }
                [void]`$denySids.Add(`$t)
            }
            break
        }
    }
    Remove-Item `$tempExport -Force -ErrorAction SilentlyContinue
}
foreach (`$user in `$localUsers) {
    `$nameLower = `$user.Name.ToLower()
    if (`$nameLower -eq `$targetLower) { continue }
    if (`$exempt -contains `$nameLower) { continue }
    try {
        `$sid = `$user.SID.Value
        if (-not `$sid) { continue }
        `$token = '*' + `$sid
        if (-not `$denySids.Contains(`$token)) { [void]`$denySids.Add(`$token) }
    } catch {}
}
if (`$denySids.Count -eq 0) { [void]`$denySids.Add('*S-1-5-32-546') }
`$tempCfg = Join-Path `$env:TEMP ('ls-deny-' + [guid]::NewGuid().Guid + '.inf')
`$cfg = @`"
[Unicode]
Unicode=yes
[Version]
signature=`"`$CHICAGO`$`"
Revision=1
[Privilege Rights]
SeDenyInteractiveLogonRight = {0}
`"@ -f (`$denySids -join ',')
`$cfg | Out-File -FilePath `$tempCfg -Encoding Unicode -Force
`$dbPath = Join-Path `$env:TEMP 'ls-deny.sdb'
& secedit /configure /db `$dbPath /cfg `$tempCfg /areas USER_RIGHTS /quiet | Out-Null
`$code = `$LASTEXITCODE
Remove-Item `$tempCfg -Force -ErrorAction SilentlyContinue
if (`$code -ne 0) { throw `"secedit failed with exit code `$code`" }
        )"
        return StrReplace(template, "__LABUSER__", escaped)
    }

    static RefreshAutologonState(user) {
        password := this.GetStoredAutologonPassword()
        if (password = "") {
            LS_LogWarning("Autologon password not found; skipping refresh")
            return false
        }
        domain := ""
        key := "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon"
        try domain := RegRead(key, "DefaultDomainName")
        return this.ConfigureAutologon(user, password, domain)
    }

    static GetStoredAutologonPassword() {
        key := "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon"
        try {
            return RegRead(key, "DefaultPassword")
        } catch {
            return ""
        }
    }

    static AccountExists(user) {
        escaped := this.EscapeForPSSingleQuote(user)
        script := Format("
        (
try {{
    if (Get-LocalUser -Name '{1}' -ErrorAction Stop) {{ '1'; exit 0 }}
}} catch {{}}
try {{
    `$user = Get-CimInstance Win32_UserAccount -Filter "LocalAccount=True AND Name='{1}'" -ErrorAction Stop | Select-Object -First 1
    if (`$user) {{ '1'; exit 0 }}
}} catch {{}}
`$oldPreference = `$ErrorActionPreference
`$ErrorActionPreference = 'Continue'
& net.exe user '{1}' 1>`$null 2>`$null
`$code = `$LASTEXITCODE
`$ErrorActionPreference = `$oldPreference
if (`$code -eq 0) {{ '1'; exit 0 }}
exit 1
        )", escaped)
        capture := LS_RunPowerShellCapture(script, "Verify local account")
        return capture["exitCode"] = 0 && InStr(capture["stdout"], "1") > 0
    }

    static EscapeForPSSingleQuote(value) {
        return StrReplace(value, "'", "''")
    }

    static GeneratePassword(length := 20) {
        chars := "ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789"
        password := ""
        total := StrLen(chars)
        Loop length {
            idx := Floor(Random() * total) + 1
            password .= SubStr(chars, idx, 1)
        }
        return password
    }
}
