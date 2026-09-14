; ============================================================================
; Lab Station - Wake-on-LAN configuration
; ============================================================================
#Requires AutoHotkey v2.0
#Include ..\core\Config.ahk
#Include ..\core\Logger.ahk
#Include ..\core\Admin.ahk
#Include ..\core\Shell.ahk

class LS_WakeOnLan {
    static Configure() {
        if (!LS_EnsureAdmin()) {
            return false
        }
        script := "
        (
$ErrorActionPreference = 'Stop'
$adapters = @(Get-NetAdapter -Physical -ErrorAction Stop | Where-Object { `$_.Status -eq 'Up' })
if (-not `$adapters) {
    Write-Output 'No active physical adapters detected'
    exit 0
}

function Get-SettingState([object]$Value, [string]$Kind = 'wake') {
    if (`$null -eq `$Value) { return 'unknown' }
    `$text = ([string]`$Value).Trim().ToLowerInvariant()
    if (`$text -match '^(enabled|true|on|yes|si|sí|habilitado|habilitada|activado|activada)$') { return 'enabled' }
    if (`$text -match '^(disabled|false|off|no|deshabilitado|deshabilitada|desactivado|desactivada)$') { return 'disabled' }
    if (`$text -match '^(unsupported|not supported|unavailable|n/a)$') { return 'unsupported' }
    if (`$text -match '^\d+$') {
        `$number = [int]`$text
        if (`$Kind -eq 'allow') {
            if (`$number -eq 2) { return 'enabled' }
            if (`$number -eq 1) { return 'disabled' }
            if (`$number -eq 0) { return 'unsupported' }
            return 'unknown'
        }
        if (`$number -eq 1) { return 'enabled' }
        if (`$number -eq 0) { return 'disabled' }
        return 'unknown'
    }
    return 'unknown'
}

function Set-WakeAdvancedProperty([string]$Name, [string]$Keyword, [string]$Value) {
    try {
        Set-NetAdapterAdvancedProperty -Name `$Name -RegistryKeyword `$Keyword -RegistryValue `$Value -ErrorAction Stop | Out-Null
        return `$true
    } catch {
        return `$false
    }
}

function Get-WakeAdvancedState([string]$Name, [string]$Keyword) {
    try {
        `$normalizedKeyword = `$Keyword.Trim().TrimStart([char]'*')
        `$properties = @(Get-NetAdapterAdvancedProperty -Name `$Name -AllProperties -ErrorAction Stop)
        foreach (`$property in `$properties) {
            `$propertyKeyword = ([string]`$property.RegistryKeyword).Trim().TrimStart([char]'*')
            if (`$propertyKeyword -ieq `$normalizedKeyword) {
                return Get-SettingState (`$property.RegistryValue -join ',') 'wake'
            }
        }
    } catch {}
    return 'unknown'
}

function Resolve-WakeSettingState([object[]]$Values, [string]$Kind = 'wake') {
    `$hasEnabled = `$false
    `$hasDisabled = `$false
    `$hasUnsupported = `$false
    foreach (`$value in `$Values) {
        `$state = Get-SettingState `$value `$Kind
        if (`$state -eq 'enabled') { `$hasEnabled = `$true }
        elseif (`$state -eq 'disabled') { `$hasDisabled = `$true }
        elseif (`$state -eq 'unsupported') { `$hasUnsupported = `$true }
    }
    if (`$hasEnabled -and `$hasDisabled) { return 'conflict' }
    if (`$hasEnabled) { return 'enabled' }
    if (`$hasDisabled) { return 'disabled' }
    if (`$hasUnsupported) { return 'unsupported' }
    return 'unknown'
}

`$failures = New-Object System.Collections.Generic.List[string]
foreach (`$adapter in `$adapters) {
    `$adapterFailures = New-Object System.Collections.Generic.List[string]
    `$deviceArmed = `$false
    `$powerCfgName = ([string]`$adapter.InterfaceDescription).Trim()
    if (`$powerCfgName) {
        & powercfg /deviceenablewake "`$powerCfgName" | Out-Null
        if (`$LASTEXITCODE -ne 0) { [void]`$adapterFailures.Add('powercfg could not arm the device') }
        `$armedText = (& powercfg /devicequery wake_armed 2>`$null) -join [Environment]::NewLine
        if (`$LASTEXITCODE -ne 0 -or `$armedText -notmatch [regex]::Escape(`$powerCfgName)) {
            [void]`$adapterFailures.Add('device is not present in wake_armed')
        } else {
            `$deviceArmed = `$true
        }
    } else {
        [void]`$adapterFailures.Add('adapter interface description is unavailable')
    }

    `$powerSettingsApplied = `$false
    try {
        Set-NetAdapterPowerManagement -Name `$adapter.Name -WakeOnMagicPacket Enabled -WakeOnPattern Disabled -ErrorAction Stop | Out-Null
        `$powerSettingsApplied = `$true
    } catch {}

    # Use invariant standardized NDIS registry keywords as a fallback and
    # reinforcement. The values 1/0 mean Enabled/Disabled for the two
    # standardized wake keywords, independently of the Windows UI language.
    `$magicSet = Set-WakeAdvancedProperty `$adapter.Name '*WakeOnMagicPacket' '1'
    `$patternSet = Set-WakeAdvancedProperty `$adapter.Name '*WakeOnPattern' '0'
    if (-not `$powerSettingsApplied -and -not (`$magicSet -and `$patternSet)) {
        [void]`$adapterFailures.Add('driver rejected Wake-on-LAN properties')
    }

    if ([string]::IsNullOrWhiteSpace([string]`$adapter.PnPDeviceID)) {
        [void]`$adapterFailures.Add('adapter PnP device ID is unavailable')
    } else {
        `$pattern = '*' + `$adapter.PnPDeviceID + '*'
        try {
            `$deviceEnable = @(Get-CimInstance -Namespace root\wmi -ClassName MSPower_DeviceEnable -ErrorAction Stop |
                Where-Object { `$_.InstanceName -like `$pattern })
            foreach (`$device in `$deviceEnable) {
                `$device.Enable = `$false
                Set-CimInstance -InputObject `$device -ErrorAction Stop | Out-Null
            }
        } catch {
            # The final Get-NetAdapterPowerManagement check below is the
            # authority for this optional WMI setting.
        }
        try {
            `$wakeEnable = @(Get-CimInstance -Namespace root\wmi -ClassName MSPower_DeviceWakeEnable -ErrorAction Stop |
                Where-Object { `$_.InstanceName -like `$pattern })
            foreach (`$device in `$wakeEnable) {
                `$device.Enable = `$true
                Set-CimInstance -InputObject `$device -ErrorAction Stop | Out-Null
            }
        } catch {
            # powercfg /devicequery wake_armed below is the authoritative
            # check when this optional WMI class is unavailable.
        }
    }

    `$pm = Get-NetAdapterPowerManagement -Name `$adapter.Name -ErrorAction SilentlyContinue
    `$magicAdvancedState = Get-WakeAdvancedState `$adapter.Name '*WakeOnMagicPacket'
    `$patternAdvancedState = Get-WakeAdvancedState `$adapter.Name '*WakeOnPattern'
    `$magicState = Resolve-WakeSettingState @(`$pm.WakeOnMagicPacket, `$magicAdvancedState) 'wake'
    `$patternState = Resolve-WakeSettingState @(`$pm.WakeOnPattern, `$patternAdvancedState) 'wake'
    `$allowState = Get-SettingState `$pm.AllowComputerToTurnOffDevice 'allow'
    if (`$magicState -ne 'enabled') { [void]`$adapterFailures.Add('WakeOnMagicPacket is ' + `$magicState) }
    if (`$patternState -ne 'disabled') { [void]`$adapterFailures.Add('WakeOnPattern is ' + `$patternState) }
    if (`$allowState -eq 'enabled' -or `$allowState -eq 'unknown') { [void]`$adapterFailures.Add('AllowComputerToTurnOffDevice is ' + `$allowState) }
    if (`$adapterFailures.Count -gt 0) {
        [void]`$failures.Add((`$adapter.Name + ': ' + (`$adapterFailures -join '; ')))
    }
}

# Configure global power plan to avoid sleep on AC
& powercfg /change standby-timeout-ac 0 | Out-Null
& powercfg /change hibernate-timeout-ac 0 | Out-Null
if (`$failures.Count -gt 0) {
    `$failures | ForEach-Object { Write-Error `$_ }
    exit 1
}
        )"
        capture := LS_RunPowerShellCapture(script, "Configure Wake-on-LAN", LAB_STATION_LONG_COMMAND_TIMEOUT_MS)
        exitCode := capture["exitCode"]
        if (exitCode = 0) {
            LS_LogInfo("Wake-on-LAN configuration applied")
            return true
        }
        detail := LS_CaptureDetail(capture)
        if (detail != "")
            LS_LogError("Wake-on-LAN configuration failed (ExitCode=" . exitCode . "): " . detail)
        else
            LS_LogError("Wake-on-LAN configuration failed (ExitCode=" . exitCode . ")")
        return false
    }
}
