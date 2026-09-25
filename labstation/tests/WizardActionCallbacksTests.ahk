#Requires AutoHotkey v2.0
#Include TestSupport.ahk
#Include ..\setup\Wizard.ahk

CheckSteps(modeName, steps, expectedLen, &errors) {
    if !IsObject(steps) {
        errors.Push(modeName . ": steps is not an object")
        return
    }

    if (steps.Length != expectedLen) {
        errors.Push(modeName . ": expected " . expectedLen . " steps but got " . steps.Length)
    }

    for index, step in steps {
        if !IsObject(step) {
            errors.Push(modeName . " step " . index . ": step is not an object")
            continue
        }

        if (!step.Has("label")) {
            errors.Push(modeName . " step " . index . ": missing label")
        }

        if (!step.Has("action")) {
            errors.Push(modeName . " step " . index . ": missing action")
            continue
        }

        action := step["action"]
        if !HasMethod(action, "Call") {
            errors.Push(modeName . " step " . index . ": action is not callable")
        }
    }
}

CheckNoNativeProbeAbort(path, &errors) {
    try {
        content := FileRead(path, "UTF-8")
        if InStr(content, "*> `$null") || InStr(content, "*> $null") {
            errors.Push(path . ": must not use *> $null for native command probes")
        }
        if RegExMatch(content, "&\s+net\s+(user|localgroup)\b") {
            errors.Push(path . ": use net.exe with explicit stderr handling")
        }
        if InStr(content, 'InStr(capture["stdout"], "1")') {
            errors.Push(path . ": user probes must check an explicit success marker")
        }
    } catch as e {
        errors.Push(path . ": cannot read file - " . e.Message)
    }
}

errors := []

try {
    serverSteps := LS_WizardServerSteps()
    CheckSteps("server", serverSteps, 8, &errors)
} catch as e {
    errors.Push("server: exception while building steps - " . e.Message)
}

try {
    hybridSteps := LS_WizardHybridSteps()
    CheckSteps("hybrid", hybridSteps, 8, &errors)
    if (IsSet(serverSteps) && serverSteps.Length >= 2 && hybridSteps.Length >= 2
        && serverSteps[2]["label"] != hybridSteps[2]["label"]) {
        errors.Push("wizard: dedicated and hybrid profiles must share the Remote App AppControl launch policy")
    }
} catch as e {
    errors.Push("hybrid: exception while building steps - " . e.Message)
}

wizardSource := FileRead(A_ScriptDir "\..\setup\Wizard.ahk", "UTF-8")
if InStr(wizardSource, "LS_WizardAutostart") {
    errors.Push("wizard: setup must not register AppControl autostart")
}
if !InStr(wizardSource, "LS_WizardClearLegacyAppControlAutostart") {
    errors.Push("wizard: setup must remove legacy AppControl autostart")
}
if !InStr(wizardSource, "LS_WizardEnsureRemoteAppLauncher") || !InStr(wizardSource, "LAB_STATION_REMOTE_APP_DIR") {
    errors.Push("wizard: setup must place AppControl.exe in the canonical remote-app directory")
}

CheckNoNativeProbeAbort(A_ScriptDir "\..\system\AccountManager.ahk", &errors)
CheckNoNativeProbeAbort(A_ScriptDir "\..\system\WinRM.ahk", &errors)
CheckNoNativeProbeAbort(A_ScriptDir "\..\diagnostics\Status.ahk", &errors)

accountScript := LS_AccountManager.BuildDenyInteractiveScript("LABUSER")
if !InStr(accountScript, 'signature="$CHICAGO$"') {
    errors.Push("account: generated secedit INF must preserve the literal CHICAGO signature")
}
if !InStr(accountScript, "SeDenyInteractiveLogonRight = __DENY_SIDS__") {
    errors.Push("account: generated secedit INF must retain its runtime SID placeholder")
}
if InStr(accountScript, "SeDenyInteractiveLogonRight = {0}") {
    errors.Push("account: generated secedit INF must not use an unresolved Format placeholder")
}

sessionEntries := LS_Status.ParseSessionEntries(
    " USUARIO              NOMBRESESION      ID  ESTADO  TIEMPO OCIOSO  INICIO`n"
    . "LABUSER                rdp-tcp#1           7  Activo       .  8/25/2026 09:00 AM`n"
)
if (sessionEntries.Length != 1 || sessionEntries[1]["id"] != "7") {
    errors.Push("status: session parser must ignore localized headers and keep numeric IDs")
}

emptySummary := LS_Status.BuildSessionSummary([], "LABUSER")
if (emptySummary["active"] || emptySummary["kind"] != "none") {
    errors.Push("status: no sessions must report an empty active-session summary")
}

labUserConsoleEntries := []
labUserConsoleEntries.Push(Map("user", "LABUSER", "session", "console", "id", "1", "state", "Activo"))
labUserConsole := LS_Status.BuildSessionSummary(labUserConsoleEntries, "LABUSER")
if (!labUserConsole["active"] || !labUserConsole["labUserActive"] || labUserConsole["labUserRemoteActive"]
    || labUserConsole["remoteSessionActive"] || labUserConsole["kind"] != "labuser-local") {
    errors.Push("status: a local LABUSER session must be classified separately from remote LABUSER")
}

labUserRemoteEntries := []
labUserRemoteEntries.Push(Map("user", "LABUSER", "session", "rdp-tcp#1", "id", "7", "state", "Active"))
labUserRemote := LS_Status.BuildSessionSummary(labUserRemoteEntries, "LABUSER")
if (!labUserRemote["active"] || !labUserRemote["labUserActive"] || !labUserRemote["labUserRemoteActive"]
    || !labUserRemote["remoteSessionActive"] || labUserRemote["kind"] != "labuser-remote") {
    errors.Push("status: a remote LABUSER session must imply an active LABUSER session")
}

disconnectedEntries := []
disconnectedEntries.Push(Map("user", "LABUSER", "session", "rdp-tcp#1", "id", "7", "state", "Disc"))
disconnected := LS_Status.BuildSessionSummary(disconnectedEntries, "LABUSER")
if (disconnected["active"] || disconnected["labUserActive"] || disconnected["remoteSessionActive"]) {
    errors.Push("status: disconnected sessions must not be reported as active")
}

mixedEntries := []
mixedEntries.Push(Map("user", "LABUSER", "session", "rdp-tcp#1", "id", "7", "state", "Active"))
mixedEntries.Push(Map("user", "alice", "session", "console", "id", "2", "state", "Active"))
mixed := LS_Status.BuildSessionSummary(mixedEntries, "LABUSER")
if (!mixed["active"] || !mixed["labUserActive"] || !mixed["labUserRemoteActive"]
    || !mixed["localUserActive"] || !mixed["remoteSessionActive"] || mixed["kind"] != "mixed") {
    errors.Push("status: simultaneous remote LABUSER and local user sessions must be mixed")
}

winrmConfigureScript := LS_WinRM.BuildConfigureScript("LabGatewaySvc", "test-password")
winrmSource := FileRead(A_ScriptDir "\..\system\WinRM.ahk", "UTF-8")
if !InStr(winrmSource, "Test-WinRMCertificate") {
    errors.Push("winrm: certificate reuse must validate SANs and current IP addresses")
}
if InStr(winrmConfigureScript, "New-SelfSignedCertificate -DnsName ($dnsNames | Select-Object -Unique)") {
    errors.Push("winrm: certificate generation must not encode IP addresses as DNS names")
}
if !InStr(winrmConfigureScript, "2.5.29.17={text}") || !InStr(winrmConfigureScript, "IPAddress=") {
    errors.Push("winrm: certificate generation must include typed IP SAN entries")
}
if !InStr(winrmConfigureScript, "$certParams = @{") || !InStr(winrmConfigureScript, "New-SelfSignedCertificate @certParams") {
    errors.Push("winrm: certificate generation must use splatted parameters")
}
if InStr(winrmConfigureScript, "New-SelfSignedCertificate " . Chr(96)) {
    errors.Push("winrm: certificate generation must not depend on backtick continuations")
}

guiSource := FileRead(A_ScriptDir "\..\ui\MainGui.ahk", "UTF-8")
if InStr(guiSource, "Ready: ") || InStr(guiSource, "Needs attention") {
    errors.Push("gui: status panel must use State instead of Ready/Needs attention")
}
if !InStr(guiSource, "ConnectorsButton") || !InStr(guiSource, "LS_ShowConnectorsPanel") {
    errors.Push("gui: main panel must expose the Connectors panel")
}
if !InStr(guiSource, '"ConnectorsButton"') {
    errors.Push("gui: Connectors button must be disabled while status checks are running")
}
if !InStr(guiSource, "LS_GuiSetQuickActionsEnabled(gui, false)") {
    errors.Push("gui: quick actions must be disabled while status checks are running")
}
if !RegExMatch(guiSource, "s)LS_GuiEndRefresh\(gui\).*ServiceRestartButton\.Enabled\s*:=\s*true") {
    ; Service restart should be restored by LS_GuiRefreshServiceState(), not blindly.
} else {
    errors.Push("gui: service restart must not be blindly re-enabled after status checks")
}

connectorSource := FileRead(A_ScriptDir "\..\connectors\Connectors.ahk", "UTF-8")
connectorsPanelSource := FileRead(A_ScriptDir "\..\ui\ConnectorsPanel.ahk", "UTF-8")
for expected in ['"fmi"', '"remote-app"', '"opc-ua"', '"tango"', '"epics"'] {
    if !InStr(connectorSource, expected) {
        errors.Push("connectors: registry missing " . expected)
    }
}
if !InStr(connectorSource, 'this.Planned("epics", "EPICS"') {
    errors.Push("connectors: EPICS must be a separate planned connector")
}
for expected in ["FMU_BACKEND_MODE=station", "FMU_STATION_BASE_URL=", "FMU_STATION_INTERNAL_TOKEN="] {
    if !InStr(connectorSource, expected) {
        errors.Push("connectors: FMI gateway config missing " . expected)
    }
}
if !InStr(connectorsPanelSource, "LS_ConnectorsPanelSelect") || !InStr(connectorsPanelSource, "LS_ConnectorsPanelRefresh") {
    errors.Push("connectors: panel must support selection and refresh")
}
if !InStr(connectorSource, '"label", "Remote App"') {
    errors.Push("connectors: local interactive surface must be labelled Remote App")
}
if !InStr(connectorSource, "LS_IsRemoteAppPolicyEnabled()") || !InStr(connectorSource, "fAllowUnlistedRemotePrograms") {
    errors.Push("connectors: Remote App availability must include the Windows policy check")
}
if !InStr(connectorsPanelSource, "+Wrap ReadOnly") {
    errors.Push("connectors: detail fields must wrap text inside the panel")
}

; Verify the wizard migrates a release-style root launcher into remote-app.
originalProjectRoot := LAB_STATION_PROJECT_ROOT
originalRemoteAppDir := LAB_STATION_REMOTE_APP_DIR
originalLogPath := LAB_STATION_LOG
wizardTestRoot := A_Temp "\LabStation-RemoteAppWizardTests-" A_TickCount
try {
    DirCreate(wizardTestRoot)
    FileAppend("fixture", wizardTestRoot "\AppControl.exe", "UTF-8")
    LAB_STATION_PROJECT_ROOT := wizardTestRoot
    LAB_STATION_REMOTE_APP_DIR := wizardTestRoot "\remote-app"
    LAB_STATION_LOG := wizardTestRoot "\wizard.log"

    if (!LS_WizardEnsureRemoteAppLauncher()) {
        errors.Push("wizard: remote-app launcher migration failed")
    }
    if (!FileExist(wizardTestRoot "\remote-app\AppControl.exe")) {
        errors.Push("wizard: migrated AppControl.exe is missing from remote-app")
    }
    if (FileExist(wizardTestRoot "\AppControl.exe")) {
        errors.Push("wizard: root AppControl.exe was not moved")
    }
} catch as e {
    errors.Push("wizard: remote-app launcher migration threw - " . e.Message)
} finally {
    LAB_STATION_PROJECT_ROOT := originalProjectRoot
    LAB_STATION_REMOTE_APP_DIR := originalRemoteAppDir
    LAB_STATION_LOG := originalLogPath
    try DirDelete(wizardTestRoot, true)
}

; An already packaged canonical launcher must not be overwritten by a stray
; root-level build artifact.
originalProjectRoot := LAB_STATION_PROJECT_ROOT
originalRemoteAppDir := LAB_STATION_REMOTE_APP_DIR
originalLogPath := LAB_STATION_LOG
wizardPackagedRoot := A_Temp "\LabStation-RemoteAppPackagedTests-" A_TickCount
try {
    DirCreate(wizardPackagedRoot "\remote-app")
    FileAppend("root-build", wizardPackagedRoot "\AppControl.exe", "UTF-8")
    FileAppend("packaged-release", wizardPackagedRoot "\remote-app\AppControl.exe", "UTF-8")
    LAB_STATION_PROJECT_ROOT := wizardPackagedRoot
    LAB_STATION_REMOTE_APP_DIR := wizardPackagedRoot "\remote-app"
    LAB_STATION_LOG := wizardPackagedRoot "\wizard.log"

    if (!LS_WizardEnsureRemoteAppLauncher()) {
        errors.Push("wizard: packaged remote-app launcher was not accepted")
    }
    if (FileRead(wizardPackagedRoot "\remote-app\AppControl.exe") != "packaged-release") {
        errors.Push("wizard: packaged AppControl.exe was unexpectedly overwritten")
    }
    if (!FileExist(wizardPackagedRoot "\AppControl.exe")) {
        errors.Push("wizard: root build artifact was unexpectedly moved")
    }
} catch as e {
    errors.Push("wizard: packaged remote-app launcher check threw - " . e.Message)
} finally {
    LAB_STATION_PROJECT_ROOT := originalProjectRoot
    LAB_STATION_REMOTE_APP_DIR := originalRemoteAppDir
    LAB_STATION_LOG := originalLogPath
    try DirDelete(wizardPackagedRoot, true)
}

if (!LS_Status.EqualsUser("LABUSER`r`n", "LABUSER")) {
    errors.Push("status: CR/LF-padded principals must match")
}

lines := LS_Status.ParseLines("LABUSER`r`n")
if (lines.Length != 1 || lines[1] != "LABUSER") {
    errors.Push("status: ParseLines must trim CR/LF from command output")
}

inactiveNic := Map(
    "wakeOnMagicPacket", "Enabled",
    "wakeOnPattern", "Enabled",
    "allowTurnOff", "Enabled",
    "advancedWakeOnMagicPacketRegistryValue", "",
    "advancedWakeOnPatternRegistryValue", "",
    "advancedWakeOnMagicPacket", "",
    "advancedWakeOnPattern", "",
    "status", "Disconnected",
    "isOperational", false
)
LS_EnergyAudit.DecorateNicCompliance(inactiveNic)
if (!inactiveNic["wolReady"]) {
    errors.Push("energy: inactive NIC must not make station readiness fail")
}

enabledPowerManagementNic := Map(
    "wakeOnMagicPacket", "Enabled",
    "wakeOnPattern", "Disabled",
    "allowTurnOff", "Enabled",
    "advancedWakeOnMagicPacketRegistryValue", "",
    "advancedWakeOnPatternRegistryValue", "",
    "advancedWakeOnMagicPacket", "",
    "advancedWakeOnPattern", "",
    "status", "Up",
    "isOperational", true
)
LS_EnergyAudit.DecorateNicCompliance(enabledPowerManagementNic)
if (!enabledPowerManagementNic["wolReady"] || enabledPowerManagementNic["complianceIssues"].Length != 0) {
    errors.Push("energy: enabled adapter power management must be WoL compliant")
}

disabledPowerManagementNic := Map(
    "wakeOnMagicPacket", "Enabled",
    "wakeOnPattern", "Disabled",
    "allowTurnOff", "Disabled",
    "advancedWakeOnMagicPacketRegistryValue", "",
    "advancedWakeOnPatternRegistryValue", "",
    "advancedWakeOnMagicPacket", "",
    "advancedWakeOnPattern", "",
    "status", "Up",
    "isOperational", true
)
LS_EnergyAudit.DecorateNicCompliance(disabledPowerManagementNic)
if (disabledPowerManagementNic["wolReady"] || !InStr(disabledPowerManagementNic["complianceIssues"][1], "Allow computer to turn off")) {
    errors.Push("energy: disabled adapter power management must remain non-compliant")
}

unsupportedNic := Map(
    "wakeOnMagicPacket", "Unsupported",
    "wakeOnPattern", "Unsupported",
    "allowTurnOff", "Unsupported",
    "advancedWakeOnMagicPacketRegistryValue", "",
    "advancedWakeOnPatternRegistryValue", "",
    "advancedWakeOnMagicPacket", "",
    "advancedWakeOnPattern", "",
    "status", "Up",
    "isOperational", true
)
LS_EnergyAudit.DecorateNicCompliance(unsupportedNic)
if (unsupportedNic["wolReady"]) {
    errors.Push("energy: active unsupported NIC must remain non-compliant")
}

registryFallbackNic := Map(
    "wakeOnMagicPacket", "Unsupported",
    "wakeOnPattern", "Unsupported",
    "allowTurnOff", "Enabled",
    "advancedWakeOnMagicPacketRegistryValue", "1",
    "advancedWakeOnPatternRegistryValue", "0",
    "advancedWakeOnMagicPacket", "",
    "advancedWakeOnPattern", "",
    "status", "Up",
    "isOperational", true
)
LS_EnergyAudit.DecorateNicCompliance(registryFallbackNic)
if (!registryFallbackNic["wolReady"]) {
    errors.Push("energy: standardized registry values must be accepted as a NIC fallback")
}

sampleStatus := Map(
    "stationProfile", "hybrid",
    "identity", Map("labUserExists", true),
    "remoteAppEnabled", true,
    "winrm", Map("ready", true),
    "legacyAppControlAutostart", false,
    "policy", Map(
        "autoLogon", Map("enabled", false, "userMatches", false, "passwordSet", false),
        "remoteDesktopUsers", Map("labUserPresent", true, "otherMembers", []),
        "denyInteractive", Map("configured", false, "labUserDenied", false)
    ),
    "sessions", Map("hasOtherUsers", true),
    "wake", Map("armedCount", 1, "nicNonCompliant", []),
    "power", Map("sleepCompliant", true, "hibernateCompliant", true)
)
sampleSummary := LS_Status.BuildSummary(sampleStatus)
if (sampleSummary["state"] != "ready" || sampleSummary["issues"].Length != 0) {
    errors.Push("status: another logged-on user must not create a needs-action issue")
}

sampleStatus["fmuExecutor"] := Map("available", true, "tokenConfigured", false, "running", false)
sampleReadiness := LS_Status.BuildCapabilityReadiness(sampleStatus)
if (!sampleReadiness["physicalLab"]["ready"]) {
    errors.Push("status: FMU issues must not block physical-lab readiness")
}
if (sampleReadiness["fmu"]["ready"] || sampleReadiness["fmu"]["issues"].Length != 2) {
    errors.Push("status: FMU readiness must retain its executor issues")
}

statusSource := FileRead(A_ScriptDir "\\..\\diagnostics\\Status.ahk", "UTF-8")
if !InStr(statusSource, 'data["readiness"] := this.BuildCapabilityReadiness(data)') {
    errors.Push("status: exported diagnostics must include capability readiness")
}

telemetrySource := FileRead(A_ScriptDir "\\..\\service\\Telemetry.ahk", "UTF-8")
if !InStr(telemetrySource, 'payload["readiness"] := status["readiness"]') {
    errors.Push("telemetry: heartbeat must publish capability readiness")
}

if (errors.Length > 0) {
    for _, msg in errors {
        LS_TestOutput(msg . "`n")
    }
    ExitApp(1)
}

LS_TestOutput("WizardActionCallbacksTests passed`n")
ExitApp(0)
