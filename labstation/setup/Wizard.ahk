; ============================================================================
; Lab Station - Setup wizard
; ============================================================================
#Requires AutoHotkey v2.0
#Include ..\core\Config.ahk
#Include ..\core\Logger.ahk
#Include ..\core\Admin.ahk
#Include ..\system\RegistryManager.ahk
#Include ..\system\WakeOnLan.ahk
#Include ..\system\AccountManager.ahk
#Include ..\system\WinRM.ahk
#Include ..\system\ServiceManager.ahk
#Include ..\system\RemoteAppWorkspaceStore.ahk
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
    if (!LS_RegistryManager.EnsureRdpDisconnectedSessionLimit()) {
        LS_LogError("Setup wizard stopped because the " . LAB_STATION_RDP_DISCONNECTED_SESSION_LIMIT_SECONDS
            . "-second RDP disconnected-session safety limit could not be verified")
        return false
    }
    if (!LS_WizardSaveProfile(mode)) {
        LS_LogError("Setup wizard stopped because the selected station profile could not be saved safely")
        MsgBox "The selected station profile could not be applied safely.`n`nCheck " . LAB_STATION_LOG . " for details.", "Lab Station Setup", "OK Iconx"
        return false
    }
    LS_LogInfo("Setup wizard profile selected: " . mode)
    if (!LS_FirewallManager.ConfigureGatewayScopes()) {
        LS_LogError("Setup wizard stopped because the Gateway firewall scopes were not configured")
        MsgBox "The station requires explicit Gateway source IP addresses for RDP and WinRM before setup can continue.", "Lab Station Setup", "OK Iconx"
        return false
    }
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
    dedicatedBtn := profileGui.AddButton("x20 y90 w300 h36", "Dedicated Lab Station")
    profileGui.SetFont("s8 cC08A2B")
    profileGui.AddText("x20 y130 w300", "Dedicated remote station; restricted LABUSER, no autologon")
    
    profileGui.SetFont("s10 cFFFFFF")
    hybridBtn := profileGui.AddButton("x20 y160 w300 h36", "Hybrid Lab Station")
    profileGui.SetFont("s8 cC08A2B")
    profileGui.AddText("x20 y200 w300", "Shared with local users; LABUSER has no autologon")

    result := ""
    ; Keep the legacy internal profile value; Station Contract v3 reports it as "dedicated".
    dedicatedBtn.OnEvent("Click", (*) => (result := "server", profileGui.Destroy()))
    hybridBtn.OnEvent("Click", (*) => (result := "hybrid", profileGui.Destroy()))
    profileGui.OnEvent("Close", (*) => (result := "cancel", profileGui.Destroy()))

    profileGui.Show("w340 h230")
    while (result = "") {
        Sleep 50
    }
    return result = "cancel" ? "" : result
}

LS_WizardSaveProfile(mode) {
    previousProfile := ""
    hybridRestrictionsRestored := false
    profileWriteAttempted := false
    profileRolledBack := false
    try {
        EnsureDir(LAB_STATION_DATA_DIR)
        previousProfile := Trim(IniRead(LAB_STATION_PROFILE_FILE, "Station", "Profile", ""))
        if (mode = "hybrid") {
            if (!LS_AccountManager.RestoreHybridInteractiveLogon(
                LS_AccountManager.DefaultUser,
                LS_WinRM.DefaultGatewayUser
            )) {
                if (previousProfile = "server" && !LS_AccountManager.ConfigureDenyInteractiveLogon(LS_AccountManager.DefaultUser))
                    LS_LogError("Unable to restore dedicated interactive-logon restrictions after hybrid migration failed")
                return false
            }
            hybridRestrictionsRestored := true
        }

        profileWriteAttempted := true
        IniWrite(mode, LAB_STATION_PROFILE_FILE, "Station", "Profile")
        evictionPolicy := Trim(IniRead(LAB_STATION_PROFILE_FILE, "Station", "AllowLocalSessionEviction", ""))
        if (evictionPolicy = "")
            IniWrite("true", LAB_STATION_PROFILE_FILE, "Station", "AllowLocalSessionEviction")
        LS_LogInfo("Station profile saved: " . mode)
        return true
    } catch as e {
        LS_LogWarning("Unable to save station profile: " . e.Message)
        if (profileWriteAttempted) {
            try {
                if (previousProfile = "")
                    IniDelete(LAB_STATION_PROFILE_FILE, "Station", "Profile")
                else
                    IniWrite(previousProfile, LAB_STATION_PROFILE_FILE, "Station", "Profile")
                currentProfile := Trim(IniRead(LAB_STATION_PROFILE_FILE, "Station", "Profile", ""))
                profileRolledBack := currentProfile = previousProfile
            } catch as rollbackError {
                LS_LogError("Unable to roll back station profile after save failure: " . rollbackError.Message)
            }
        }
        if (hybridRestrictionsRestored && profileRolledBack && previousProfile = "server"
            && !LS_AccountManager.ConfigureDenyInteractiveLogon(LS_AccountManager.DefaultUser)) {
            LS_LogError("Unable to restore dedicated interactive-logon restrictions after profile save failed")
        }
        return false
    }
}

LS_WizardServerSteps() {
    return [
        Map("label", "Create/configure LABUSER + scoped RDP + RemoteApp restrictions (no autologon)", "action", (*) => LS_WizardAccountServer()),
        Map("label", "Remove legacy AppControl autostart; launch it from the Gateway Remote App connection", "action", (*) => LS_WizardClearLegacyAppControlAutostart()),
        Map("label", "Place AppControl in the remote-app launcher directory", "action", (*) => LS_WizardEnsureRemoteAppLauncher()),
        Map("label", "Create protected RemoteApp workspace configuration store", "action", (*) => LS_RemoteAppWorkspaceStore.Ensure()),
        Map("label", "Enable RemoteApp (fAllowUnlistedRemotePrograms)", "action", (*) => LS_RegistryManager.SetRemoteAppPolicy()),
        Map("label", "Configure WinRM for Lab Gateway", "action", (*) => LS_WizardWinRM()),
        Map("label", "Configure Wake-on-LAN", "action", (*) => LS_WakeOnLan.Configure()),
        Map("label", "Install/start background service", "action", (*) => LS_WizardService()),
        Map("label", "Export diagnostics report", "action", (*) => LS_WizardDiagnostics())
    ]
}

LS_WizardHybridSteps() {
    return [
        Map("label", "Create/update LABUSER + scoped RDP (no autologon)", "action", (*) => LS_WizardAccountHybrid()),
        Map("label", "Remove legacy AppControl autostart; launch it from the Gateway Remote App connection", "action", (*) => LS_WizardClearLegacyAppControlAutostart()),
        Map("label", "Place AppControl in the remote-app launcher directory", "action", (*) => LS_WizardEnsureRemoteAppLauncher()),
        Map("label", "Create protected RemoteApp workspace configuration store", "action", (*) => LS_RemoteAppWorkspaceStore.Ensure()),
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
        LS_WizardShowAccountInfo(pass)
        return true
    }
    return false
}

LS_WizardAccountHybrid() {
    pass := ""
    if (LS_AccountManager.EnsureAccount("", &pass)) {
        LS_WizardShowAccountInfo(pass)
        return true
    }
    return false
}

LS_WizardShowAccountInfo(password) {
    text := "User: " . LS_AccountManager.DefaultUser . "`nPassword: " . password
    text .= "`nAutologon is disabled. Use these credentials when Lab Gateway prepares remote sessions."
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

LS_WizardClearLegacyAppControlAutostart() {
    return LS_RegistryManager.RemoveRunEntry("LabStationAppControl")
}

LS_WizardEnsureRemoteAppLauncher() {
    targetDir := LAB_STATION_REMOTE_APP_DIR
    targetExe := targetDir "\AppControl.exe"
    targetScript := targetDir "\AppControl.ahk"
    sourceExe := LAB_STATION_PROJECT_ROOT "\AppControl.exe"

    try {
        if (FileExist(targetExe) || FileExist(targetScript)) {
            LS_LogInfo("Remote App launcher available at: " . (FileExist(targetExe) ? targetExe : targetScript))
            return true
        }

        if (FileExist(sourceExe)) {
            EnsureDir(targetDir)
            FileMove(sourceExe, targetExe, true)
            LS_LogInfo("Moved AppControl.exe to the canonical Remote App directory: " . targetExe)
        }

        if (FileExist(targetExe) || FileExist(targetScript)) {
            LS_LogInfo("Remote App launcher available at: " . (FileExist(targetExe) ? targetExe : targetScript))
            return true
        }

        LS_LogError("AppControl launcher was not found at the project root or remote-app directory")
        return false
    } catch as e {
        LS_LogError("Unable to place AppControl.exe in the remote-app directory: " . e.Message)
        return false
    }
}
