#Requires AutoHotkey v2.0
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
    CheckSteps("server", serverSteps, 7, &errors)
} catch as e {
    errors.Push("server: exception while building steps - " . e.Message)
}

try {
    hybridSteps := LS_WizardHybridSteps()
    CheckSteps("hybrid", hybridSteps, 7, &errors)
} catch as e {
    errors.Push("hybrid: exception while building steps - " . e.Message)
}

CheckNoNativeProbeAbort(A_ScriptDir "\..\system\AccountManager.ahk", &errors)
CheckNoNativeProbeAbort(A_ScriptDir "\..\system\WinRM.ahk", &errors)
CheckNoNativeProbeAbort(A_ScriptDir "\..\diagnostics\Status.ahk", &errors)

guiSource := FileRead(A_ScriptDir "\..\ui\MainGui.ahk", "UTF-8")
if InStr(guiSource, "Ready: ") || InStr(guiSource, "Needs attention") {
    errors.Push("gui: status panel must use State instead of Ready/Needs attention")
}
if !InStr(guiSource, "LS_GuiSetQuickActionsEnabled(gui, false)") {
    errors.Push("gui: quick actions must be disabled while status checks are running")
}
if !RegExMatch(guiSource, "s)LS_GuiEndRefresh\(gui\).*ServiceRestartButton\.Enabled\s*:=\s*true") {
    ; Service restart should be restored by LS_GuiRefreshServiceState(), not blindly.
} else {
    errors.Push("gui: service restart must not be blindly re-enabled after status checks")
}

if (!LS_Status.EqualsUser("LABUSER`r`n", "LABUSER")) {
    errors.Push("status: CR/LF-padded principals must match")
}

lines := LS_Status.ParseLines("LABUSER`r`n")
if (lines.Length != 1 || lines[1] != "LABUSER") {
    errors.Push("status: ParseLines must trim CR/LF from command output")
}

sampleStatus := Map(
    "stationProfile", "hybrid",
    "identity", Map("labUserExists", true),
    "remoteAppEnabled", true,
    "winrm", Map("ready", true),
    "autoStartConfigured", true,
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

if (errors.Length > 0) {
    for _, msg in errors {
        FileAppend(msg . "`n", "*")
    }
    ExitApp(1)
}

FileAppend("WizardActionCallbacksTests passed`n", "*")
ExitApp(0)
