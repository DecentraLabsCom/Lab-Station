; ============================================================================
; Lab Station - Desktop GUI
; ============================================================================
#Requires AutoHotkey v2.0
#Include ..\core\Config.ahk
#Include ..\core\Logger.ahk
#Include ..\core\Admin.ahk
#Include ..\diagnostics\Status.ahk
#Include ..\service\Telemetry.ahk
#Include ..\service\SessionManager.ahk
#Include ..\service\SessionGuard.ahk
#Include ..\system\ServiceManager.ahk

; Entry point for LabStation.exe gui
LS_StartMainGui() {
    global LS_GUI
    if (IsSet(LS_GUI) && LS_GUI && LS_GUI.Visible) {
        LS_GUI.Show()
        return
    }
    LS_GUI := LS_BuildGui()
    LS_GUI.Show()
}

LS_BuildGui() {
    myGui := Gui("+Resize", "Lab Station Control Panel")
    myGui.BackColor := "0F1419"
    myGui.SetFont("s10", "Segoe UI")

    myGui.StatusBox := ""
    myGui.SetupButton := ""
    myGui.SetupChip := ""
    myGui.LocalModeButton := ""
    myGui.ServiceStatusText := ""
    myGui.ServiceRestartButton := ""

    ; Header
    myGui.SetFont("s17 Bold cFFFFFF", "Bahnschrift")
    myGui.AddText("x24 y16", "🖥️ Lab Station")
    myGui.SetFont("s9 c9CA3AF")
    myGui.AddText("x24 yp+28", "Workstation management console")
    logoPaths := [
        LAB_STATION_PROJECT_ROOT "\img\DecentraLabs.png",
        A_ScriptDir "\img\DecentraLabs.png",
        A_ScriptDir "\DecentraLabs.png"
    ]
    for path in logoPaths {
        if (FileExist(path)) {
            myGui.AddPicture("x500 y12 w196 h40 +BackgroundTrans", path)
            break
        }
    }

    ; Status section
    myGui.SetFont("s11 Bold cFFFFFF")
    myGui.AddText("x24 y82", "📊 System Status")

    myGui.SetFont("s8 cC08A2B")
    myGui.SetupChip := myGui.AddText("x150 y85 w200", "(checking)")

    myGui.SetFont("s9 cE5E7EB")
    myGui.StatusBox := myGui.AddEdit("x24 y110 w420 h180 -Wrap ReadOnly -TabStop cD1FAE5 Background1F2937 +Border")
    myGui.StatusBox.Value := "Loading system status..."

    ; Status action buttons
    myGui.SetFont("s9 cFFFFFF")
    refreshBtn := myGui.AddButton("x24 y300 w130 h32", "🔄 Refresh")
    refreshBtn.OnEvent("Click", LS_GuiRefreshStatus_Handler)

    exportBtn := myGui.AddButton("x164 y300 w150 h32", "💾 Export JSON")
    exportBtn.OnEvent("Click", LS_GuiExportStatus_Handler)

    logBtn := myGui.AddButton("x324 y300 w120 h32", "📄 Open Log")
    logBtn.OnEvent("Click", LS_GuiOpenLog_Handler)

    ; Separator
    myGui.SetFont("s1 c374151")
    myGui.AddText("x470 y16 w2 h370", "│")

    ; Actions
    myGui.SetFont("s11 Bold cFFFFFF")
    myGui.AddText("x485 y65", "⚡ Quick Actions")

    myGui.SetFont("s8 cC08A2B")
    myGui.AddText("x495 y85 w230", "⚠️ Actions require admin privileges")

    myGui.SetFont("s9 Bold c9CA3AF")
    myGui.AddText("x490 y110", "Setup")

    myGui.SetFont("s9 cFFFFFF")
    myGui.SetupButton := myGui.AddButton("x490 y130 w220 h34", "🛠️ Run Setup Wizard")
    myGui.SetupButton.OnEvent("Click", LS_GuiRunSetup_Handler)

    myGui.SetFont("s9 Bold c9CA3AF")
    myGui.AddText("x490 y180", "Local mode (on-site)")

    myGui.SetFont("s9 cFFFFFF")
    myGui.LocalModeButton := myGui.AddButton("x490 y200 w220 h34", "🔒 Enable local mode")
    myGui.LocalModeButton.OnEvent("Click", LS_GuiToggleLocalMode_Handler)

    myGui.SetFont("s9 cE5E7EB")
    myGui.ServiceStatusText := myGui.AddText("x490 y240 w220", "(checking)")

    myGui.SetFont("s9 cFFFFFF")
    myGui.ServiceRestartButton := myGui.AddButton("x490 y260 w220 h34", "⟳ Restart service")
    myGui.ServiceRestartButton.OnEvent("Click", LS_GuiRestartService_Handler)

    myGui.SetFont("s9 Bold c9CA3AF")
    myGui.AddText("x490 y305 w220 Center", "Background service")

    ; Footer
    myGui.SetFont("s8 c6B7280")
    myGui.AddText("x24 y360 w686 Center", "DecentraLabs © 2025 · Lab Station v3.0.0")
    refreshBtn.Focus()

    myGui.OnEvent("Close", (*) => myGui.Destroy())
    myGui.OnEvent("Size", LS_GuiSize_Handler)
    LS_GuiRefreshStatus(myGui)
    return myGui
}

LS_GuiNeedsSetup(status) {
    ; Basic readiness check: summary.ready false OR missing core features
    if (status.Has("summary") && status["summary"].Has("ready") && !status["summary"]["ready"])
        return true
    if (status.Has("remoteAppEnabled") && !status["remoteAppEnabled"])
        return true
    if (status.Has("autoStartConfigured") && !status["autoStartConfigured"])
        return true
    if (status.Has("wake")) {
        wake := status["wake"]
        if (wake.Has("armedCount") && wake["armedCount"] = 0)
            return true
    }
    return false
}

LS_GuiRefreshStatus(gui) {
    status := LS_Status.Collect()
    needsSetup := LS_GuiNeedsSetup(status)
    gui.SetupButton.Enabled := needsSetup
    gui.SetupButton.Text := needsSetup ? "🛠️ Run Setup Wizard" : "🛠️ Setup already applied"
    gui.SetupChip.Text := needsSetup ? "(Needs action)" : "(OK)"
    gui.SetupChip.Opt("c" . (needsSetup ? "FFB020" : "9CA3AF"))

    summary := []
    summary.Push("═══════════════════════════════════════")
    summary.Push("  SYSTEM STATUS REPORT")
    summary.Push("═══════════════════════════════════════")
    summary.Push("")
    summary.Push("🖥️  Host: " . (status.Has("host") ? status["host"] : A_ComputerName))
    summary.Push("")
    ready := (status.Has("summary") && status["summary"].Has("ready")) ? status["summary"]["ready"] : false
    readyIcon := ready ? "✅" : "⚠️"
    summary.Push(readyIcon . "  Ready: " . (ready ? "Yes" : "Needs attention"))
    summary.Push("")
    localMode := status.Has("localModeEnabled") ? status["localModeEnabled"] : false
    localIcon := localMode ? "🔒" : "🌐"
    summary.Push(localIcon . "  Local mode: " . (localMode ? "Enabled" : "Disabled"))
    if (gui.HasProp("LocalModeButton") && gui.LocalModeButton) {
        gui.LocalModeButton.Text := localMode ? "🌐 Disable local mode" : "🔒 Enable local mode"
    }
    summary.Push("")
    hasUsers := status.Has("sessions") && status["sessions"].Has("hasOtherUsers") && status["sessions"]["hasOtherUsers"]
    userIcon := hasUsers ? "👤" : "○"
    summary.Push(userIcon . "  Active sessions: " . (hasUsers ? "Present" : "None"))
    summary.Push("")
    if (status.Has("summary") && status["summary"].Has("issues") && status["summary"]["issues"].Length > 0) {
        summary.Push("⚠️  ISSUES DETECTED:")
        for issue in status["summary"]["issues"] {
            summary.Push("   • " . issue)
        }
    } else {
        summary.Push("✓  No issues detected")
    }
    summary.Push("")
    summary.Push("Last refresh: " . FormatTime(A_Now, "yyyy-MM-dd HH:mm:ss"))
    gui.StatusBox.Value := LS_StrJoin(summary, "`r`n")
    if (gui.HasProp("ServiceStatusText") && gui.ServiceStatusText)
        LS_GuiRefreshServiceState(gui)
}

LS_GuiExportStatus(gui) {
    target := LAB_STATION_STATUS_FILE
    if (LS_Status.ExportJson(target)) {
        MsgBox "Report saved to " . target, "Lab Station", "OK Iconi"
    } else {
        MsgBox "Unable to export report", "Lab Station", "OK Iconx"
    }
}

LS_GuiOpenLog() {
    if (!FileExist(LAB_STATION_LOG)) {
        MsgBox "Log file not found at " . LAB_STATION_LOG, "Lab Station", "OK Iconx"
        return
    }
    Run Format('notepad.exe "{1}"', LAB_STATION_LOG)
}

LS_GuiEnsureAdmin() {
    if (!LS_EnsureAdmin(false)) {
        MsgBox "Admin privileges required for this action.", "Lab Station", "OK Iconx"
        return false
    }
    return true
}

LS_GuiRunSetup() {
    if (!LS_GuiEnsureAdmin())
        return
    LS_RunSetupWizard()
    ; Refresh status after setup
    if (IsSet(LS_GUI) && LS_GUI)
        LS_GuiRefreshStatus(LS_GUI)
    LS_GuiPublishStatus()
}

LS_GuiRunGuard() {
    if (!LS_GuiEnsureAdmin())
        return
    success := LS_SessionGuard.Run(Map("grace", 90))
    icon := success ? "OK Iconi" : "OK Iconx"
    MsgBox (success ? "Session guard finished" : "Session guard reported warnings"), "Lab Station", icon
    LS_GuiPublishStatus()
    if (IsSet(LS_GUI) && LS_GUI)
        LS_GuiRefreshStatus(LS_GUI)
}

LS_GuiRunPrepare() {
    if (!LS_GuiEnsureAdmin())
        return
    success := LS_SessionManager.PrepareSession()
    icon := success ? "OK Iconi" : "OK Iconx"
    MsgBox (success ? "Prepare-session completed" : "Prepare-session finished with warnings"), "Lab Station", icon
    LS_GuiPublishStatus()
    if (IsSet(LS_GUI) && LS_GUI)
        LS_GuiRefreshStatus(LS_GUI)
}

LS_GuiRunRelease() {
    if (!LS_GuiEnsureAdmin())
        return
    success := LS_SessionManager.ReleaseSession(Map("reboot", true))
    icon := success ? "OK Iconi" : "OK Iconx"
    MsgBox (success ? "Release-session completed" : "Release-session finished with warnings"), "Lab Station", icon
    LS_GuiPublishStatus()
    if (IsSet(LS_GUI) && LS_GUI)
        LS_GuiRefreshStatus(LS_GUI)
}

LS_GuiSize_Handler(guiObj, minMax, w, h) {
    if (minMax = -1) { ; minimized
        guiObj.Hide()
        LS_EnsureTrayMenu()
    }
}

LS_GuiPublishStatus(status := "") {
    try {
        status := IsObject(status) ? status : LS_Status.Collect()
        LS_Status.ExportJson(LAB_STATION_STATUS_FILE, status)
        LS_Telemetry.Publish(status)
    } catch as e {
        LS_LogWarning("Unable to refresh telemetry from GUI: " . e.Message)
    }
}

LS_GuiGetServiceStatus() {
    result := Map("running", false, "label", "Unknown", "unknown", true)
    capture := LS_ServiceManager.StatusText()
    label := Trim(capture)
    if (RegExMatch(capture, "Status:\\s*([^\\r\\n]+)", &m)) {
        label := Trim(m[1])
    }
    lower := StrLower(label)
    running := InStr(lower, "running") > 0
    result["running"] := running
    result["label"] := label != "" ? label : "Unknown"
    result["unknown"] := (label = "")
    return result
}

LS_GuiRefreshServiceState(gui) {
    status := LS_GuiGetServiceStatus()
    color := status["running"] ? "22C55E" : "F97316"
    if (status["unknown"])
        color := "D1D5DB"
    gui.ServiceStatusText.Text := "Status: " . status["label"]
    gui.ServiceStatusText.Opt("c" . color)
    if (gui.HasProp("ServiceRestartButton") && gui.ServiceRestartButton)
        gui.ServiceRestartButton.Enabled := !status["unknown"]
}

LS_GuiRestartService(gui) {
    if (!LS_GuiEnsureAdmin())
        return
    try {
        LS_ServiceManager.Stop()
        Sleep 500
        ok := LS_ServiceManager.Start()
        MsgBox (ok ? "Service restarted." : "Service restart reported an issue (check log)."), "Lab Station", ok ? "OK Iconi" : "OK Iconx"
    } catch as e {
        MsgBox "Unable to restart service: " . e.Message, "Lab Station", "OK Iconx"
    }
    if (IsSet(gui) && gui)
        LS_GuiRefreshServiceState(gui)
}

LS_GuiToggleTray(gui) {
    try {
        A_IconHidden := !A_IconHidden
        if (!A_IconHidden)
            LS_EnsureTrayMenu()
    } catch as e {
        MsgBox "Unable to toggle tray icon: " . e.Message, "Lab Station", "OK Iconx"
        return
    }
}

LS_GuiToggleLocalMode(gui) {
    flag := LAB_STATION_LOCAL_MODE_FLAG
    message := ""
    try {
        EnsureDir(LAB_STATION_DATA_DIR)
        if (FileExist(flag)) {
            FileDelete(flag)
            message := "Local mode disabled. Remote reservations can proceed."
        } else {
            file := FileOpen(flag, "w", "UTF-8")
            file.Write("local-mode")
            file.Close()
            message := "Local mode enabled. Remote reservations should be paused."
        }
    } catch as e {
        MsgBox "Unable to toggle local mode: " . e.Message, "Lab Station", "OK Iconx"
        return
    }
    MsgBox message, "Lab Station", "OK Iconi"
    LS_GuiPublishStatus()
    if (IsSet(gui) && gui)
        LS_GuiRefreshStatus(gui)
}

LS_EnsureTrayMenu() {
    static trayReady := false
    if (trayReady)
        return
    ; Set tray icon if available
    logo := ""
    possible := [
        A_ScriptDir "\img\DecentraLabs.png",
        A_ScriptDir "\DecentraLabs.png"
    ]
    for p in possible {
        if (FileExist(p)) {
            logo := p
            break
        }
    }
    if (logo != "")
        TraySetIcon(logo)
    A_TrayMenu.Delete()
    A_TrayMenu.Add("Show Lab Station", (*) => (LS_StartMainGui(), LS_GUI.Show()))
    A_TrayMenu.Add()
    A_TrayMenu.Add("Exit", (*) => ExitApp)
    trayReady := true
}

; Event handlers
LS_GuiRefreshStatus_Handler(ctrl, info) {
    LS_GuiRefreshStatus(ctrl.Gui)
}

LS_GuiExportStatus_Handler(ctrl, info) {
    LS_GuiExportStatus(ctrl.Gui)
}

LS_GuiOpenLog_Handler(ctrl, info) {
    LS_GuiOpenLog()
}

LS_GuiRunSetup_Handler(ctrl, info) {
    LS_GuiRunSetup()
}

LS_GuiRunGuard_Handler(ctrl, info) {
    LS_GuiRunGuard()
}

LS_GuiRunPrepare_Handler(ctrl, info) {
    LS_GuiRunPrepare()
}

LS_GuiRunRelease_Handler(ctrl, info) {
    LS_GuiRunRelease()
}

LS_GuiRestartService_Handler(ctrl, info) {
    LS_GuiRestartService(ctrl.Gui)
}

LS_GuiToggleLocalMode_Handler(ctrl, info) {
    LS_GuiToggleLocalMode(ctrl.Gui)
}
