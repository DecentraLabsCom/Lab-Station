; ============================================================================
; Lab Station - Setup wizard
; ============================================================================
#Requires AutoHotkey v2.0
#Include ..\core\Config.ahk
#Include ..\core\Logger.ahk
#Include ..\core\Admin.ahk
#Include ..\system\RegistryManager.ahk
#Include ..\system\WakeOnLan.ahk
#Include ..\system\Autostart.ahk
#Include ..\system\AccountManager.ahk
#Include ..\system\WinRM.ahk
#Include ..\system\ServiceManager.ahk
#Include ..\diagnostics\Status.ahk

LS_RunSetupWizard() {
    if (!LS_EnsureAdmin()) {
        return false
    }
    LS_LogInfo("Setup wizard started")
    mode := LS_WizardSelectMode()
    if (mode = "") {
        LS_LogInfo("Setup wizard cancelled before profile selection")
        return false
    }
    LS_WizardSaveProfile(mode)
    LS_LogInfo("Setup wizard profile selected: " . mode)
    steps := mode = "server" ? LS_WizardServerSteps() : LS_WizardHybridSteps()

    for step in steps {
        label := step["label"]
        LS_LogInfo("Setup wizard prompting step: " . label)
        response := MsgBox(label . "?", "Lab Station Setup", "YesNo Iconi")
        if (response = "Yes") {
            LS_LogInfo("Setup wizard running step: " . label)
            success := false
            try {
                success := step["action"].Call()
            } catch as e {
                LS_LogError("Setup wizard step threw: " . label . " - " . e.Message)
                success := false
            }
            if (success) {
                LS_LogInfo("Setup wizard completed step: " . label)
                MsgBox "Completed: " . label, "Lab Station", "OK Iconi"
            } else {
                LS_LogError("Setup wizard failed step: " . label)
                MsgBox "There was an issue executing: " . label . "`n`nCheck " . LAB_STATION_LOG . " for details.", "Lab Station", "OK Iconx"
            }
        } else {
            LS_LogInfo("Setup wizard skipped step: " . label)
        }
    }

    LS_LogInfo("Setup wizard finished")
    MsgBox "Setup completed. Check labstation.log for details.", "Lab Station", "OK Iconi"
    return true
}

LS_WizardSelectMode() {
    profileGui := Gui("+AlwaysOnTop +ToolWindow", "Lab Station Setup")
    profileGui.BackColor := "0F1419"
    profileGui.SetFont("s10", "Segoe UI")

    profileGui.SetFont("s14 Bold cFFFFFF", "Segoe UI Variable Display")
    profileGui.AddText("x20 y14", "⚙️ Select station profile")
    profileGui.SetFont("s9 c9CA3AF")
    profileGui.AddText("x20 yp+30", "Choose the operating mode for this lab station.")

    profileGui.SetFont("s10 cFFFFFF")
    serverBtn := profileGui.AddButton("x20 y90 w300 h36", "Dedicated Lab Server")
    profileGui.SetFont("s8 cC08A2B")
    profileGui.AddText("x20 y130 w300", "Full lockdown: LABUSER autologon + restricted mode")
    
    profileGui.SetFont("s10 cFFFFFF")
    hybridBtn := profileGui.AddButton("x20 y160 w300 h36", "Hybrid Lab Station")
    profileGui.SetFont("s8 cC08A2B")
    profileGui.AddText("x20 y200 w300", "LABUSER without autologon, shared with local users")

    result := ""
    serverBtn.OnEvent("Click", (*) => (result := "server", profileGui.Destroy()))
    hybridBtn.OnEvent("Click", (*) => (result := "hybrid", profileGui.Destroy()))
    profileGui.OnEvent("Close", (*) => (result := "cancel", profileGui.Destroy()))

    profileGui.Show("w340 h230")
    while (result = "") {
        Sleep 50
    }
    return result = "cancel" ? "" : result
}

LS_WizardSaveProfile(mode) {
    try {
        EnsureDir(LAB_STATION_DATA_DIR)
        IniWrite(mode, LAB_STATION_PROFILE_FILE, "Station", "Profile")
        LS_LogInfo("Station profile saved: " . mode)
        return true
    } catch as e {
        LS_LogWarning("Unable to save station profile: " . e.Message)
        return false
    }
}

LS_WizardServerSteps() {
    return [
        Map("label", "Create/configure LABUSER + Remote Desktop Users + Autologon", "action", (*) => LS_WizardAccountServer()),
        Map("label", "Register AppControl autostart", "action", (*) => LS_WizardAutostartServer()),
        Map("label", "Enable RemoteApp (fAllowUnlistedRemotePrograms)", "action", (*) => LS_RegistryManager.SetRemoteAppPolicy()),
        Map("label", "Configure WinRM for Lab Gateway", "action", (*) => LS_WizardWinRM()),
        Map("label", "Configure Wake-on-LAN", "action", (*) => LS_WakeOnLan.Configure()),
        Map("label", "Install/start background service", "action", (*) => LS_WizardService()),
        Map("label", "Export diagnostics report", "action", (*) => LS_WizardDiagnostics())
    ]
}

LS_WizardHybridSteps() {
    return [
        Map("label", "Create/update LABUSER + Remote Desktop Users (no autologon)", "action", (*) => LS_WizardAccountHybrid()),
        Map("label", "Register autostart only for LABUSER", "action", (*) => LS_WizardAutostartHybrid()),
        Map("label", "Enable RemoteApp (fAllowUnlistedRemotePrograms)", "action", (*) => LS_RegistryManager.SetRemoteAppPolicy()),
        Map("label", "Configure WinRM for Lab Gateway", "action", (*) => LS_WizardWinRM()),
        Map("label", "Configure Wake-on-LAN", "action", (*) => LS_WakeOnLan.Configure()),
        Map("label", "Install/start background service", "action", (*) => LS_WizardService()),
        Map("label", "Export diagnostics report", "action", (*) => LS_WizardDiagnostics())
    ]
}

LS_WizardService() {
    if (!LS_ServiceManager.Install())
        return false
    return LS_ServiceManager.Start()
}

LS_WizardDiagnostics() {
    if (LS_Status.ExportJson(LAB_STATION_STATUS_FILE)) {
        MsgBox "Report saved to " . LAB_STATION_STATUS_FILE, "Lab Station", "OK Iconi"
        return true
    }
    MsgBox "Unable to export report", "Lab Station", "OK Iconx"
    return false
}

LS_WizardAccountServer() {
    pass := ""
    if (LS_AccountManager.Setup("", &pass)) {
        LS_WizardShowAccountInfo(pass, true)
        return true
    }
    return false
}

LS_WizardAccountHybrid() {
    pass := ""
    if (LS_AccountManager.EnsureAccount("", &pass)) {
        LS_WizardShowAccountInfo(pass, false)
        return true
    }
    return false
}

LS_WizardShowAccountInfo(password, autologon := false) {
    text := "User: " . LS_AccountManager.DefaultUser . "`nPassword: " . password
    if (autologon) {
        text .= "`nAutologon enabled. Store the credentials safely."
    } else {
        text .= "`nUse these credentials when Lab Gateway prepares remote sessions."
    }
    MsgBox text, "Lab Station", "OK Iconi"
}

LS_WizardWinRM() {
    pass := ""
    if (LS_WinRM.Configure("", &pass)) {
        text := "WinRM is ready for Lab Gateway operations." . "`n`n"
        text .= "User: .\" . LS_WinRM.DefaultGatewayUser . "`n"
        text .= "Password: " . pass . "`n`n"
        text .= "In Lab Gateway, open Lab Manager -> Lab Station Ops and save these in WinRM Credentials for this host address."
        MsgBox text, "Lab Station", "OK Iconi"
        return true
    }
    return false
}

LS_WizardAutostartServer() {
    return LS_Autostart.Configure()
}

LS_WizardAutostartHybrid() {
    return LS_Autostart.Configure("", LS_AccountManager.DefaultUser)
}
