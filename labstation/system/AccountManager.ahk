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
        if (!this.EnsureAccount(user, localPass)) {
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
        script := Format("
        (
`$User = '{1}'
`$Password = '{2}'
`$secure = ConvertTo-SecureString `$Password -AsPlainText -Force
`$description = 'DecentraLabs Lab Station service account'
if (-not (Get-LocalUser -Name `$User -ErrorAction SilentlyContinue)) {{
    New-LocalUser -Name `$User -Password `$secure -PasswordNeverExpires `$true -AccountNeverExpires `$true -Description `$description -UserMayNotChangePassword `$true | Out-Null
}} else {{
    Set-LocalUser -Name `$User -Password `$secure -PasswordNeverExpires `$true -UserMayNotChangePassword `$true -AccountNeverExpires `$true -Description `$description
    Enable-LocalUser -Name `$User -ErrorAction SilentlyContinue | Out-Null
}}
`$groups = @('Users', 'Remote Desktop Users')
foreach (`$group in `$groups) {{
    try {{ Add-LocalGroupMember -Group `$group -Member `$User -ErrorAction SilentlyContinue }} catch {{}}
}}
try {{ Remove-LocalGroupMember -Group 'Administrators' -Member `$User -ErrorAction SilentlyContinue }} catch {{}}
        )", user, localPassword)
        exitCode := LS_RunPowerShell(script, "Configure lab service account")
        if (exitCode = 0) {
            password := localPassword
            LS_LogInfo(Format("Account {1} created/updated", user))
            return true
        }
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
        key := "HKLM\\SOFTWARE\\Microsoft\\Windows NT\\CurrentVersion\\Winlogon"
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
        script := Format("
        (
`$User = '{1}'
`$group = 'Remote Desktop Users'
`$members = Get-LocalGroupMember -Group `$group -ErrorAction SilentlyContinue
foreach (`$member in `$members) {{
    if (`$member.ObjectClass -eq 'User' -and `$member.Name -ne `$User) {{
        try {{ Remove-LocalGroupMember -Group `$group -Member `$member.Name -ErrorAction SilentlyContinue }} catch {{}}
    }}
}}
try {{
    Set-ItemProperty -Path 'HKLM:\\SYSTEM\\CurrentControlSet\\Control\\Terminal Server' -Name 'fDenyTSConnections' -Value 0
    New-ItemProperty -Path 'HKLM:\\SOFTWARE\\Microsoft\\Windows NT\\CurrentVersion\\Winlogon' -Name 'DisableLockWorkstation' -Value 1 -PropertyType DWORD -Force | Out-Null
}} catch {{}}
        )", user)
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
        key := "HKLM\\SOFTWARE\\Microsoft\\Windows NT\\CurrentVersion\\Winlogon"
        try domain := RegRead(key, "DefaultDomainName")
        return this.ConfigureAutologon(user, password, domain)
    }

    static GetStoredAutologonPassword() {
        key := "HKLM\\SOFTWARE\\Microsoft\\Windows NT\\CurrentVersion\\Winlogon"
        try {
            return RegRead(key, "DefaultPassword")
        } catch {
            return ""
        }
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
