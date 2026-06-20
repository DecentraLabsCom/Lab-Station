; ============================================================================
; Lab Station - Connectors panel
; ============================================================================
#Requires AutoHotkey v2.0
#Include ..\connectors\Connectors.ahk

LS_ShowConnectorsPanel(*) {
    global LS_CONNECTORS_PANEL
    if (IsSet(LS_CONNECTORS_PANEL) && IsObject(LS_CONNECTORS_PANEL)) {
        try {
            LS_CONNECTORS_PANEL.Show()
            LS_ConnectorsPanelRefresh()
            return
        } catch {
            LS_CONNECTORS_PANEL := ""
        }
    }
    LS_CONNECTORS_PANEL := LS_BuildConnectorsPanel()
    LS_CONNECTORS_PANEL.Show()
    LS_ConnectorsPanelSelect("fmi")
}

LS_BuildConnectorsPanel() {
    panel := Gui("-Resize -MaximizeBox", "Lab Station Connectors")
    panel.BackColor := "0F1419"
    panel.SetFont("s10", "Segoe UI")
    panel.SelectedConnectorId := "fmi"
    panel.ConnectorButtons := Map()

    panel.SetFont("s16 Bold cFFFFFF", "Bahnschrift")
    panel.AddText("x24 y16 w520", "Connectors")
    panel.SetFont("s9 c9CA3AF")
    panel.AddText("x24 y46 w560", "Local integration surfaces served from this Lab Station")

    panel.SetFont("s9 Bold c9CA3AF")
    panel.AddText("x24 y82 w170", "Available connectors")

    y := 106
    for connector in LS_ConnectorRegistry.List() {
        label := connector["label"]
        if (connector["planned"])
            label .= " (planned)"
        btn := panel.AddButton("x24 y" . y . " w180 h32", label)
        btn.ConnectorId := connector["id"]
        btn.Enabled := !connector["planned"]
        btn.OnEvent("Click", LS_ConnectorsPanelSelect_Handler)
        panel.ConnectorButtons[connector["id"]] := btn
        y += 40
    }

    panel.SetFont("s11 Bold cFFFFFF")
    panel.ConnectorTitle := panel.AddText("x230 y82 w430", "")
    panel.SetFont("s9 c9CA3AF")
    panel.ConnectorState := panel.AddText("x230 y108 w430", "")

    panel.SetFont("s9 cE5E7EB")
    panel.ConnectorDetails := panel.AddEdit("x230 y136 w440 h126 -Wrap ReadOnly -TabStop cD1FAE5 Background1F2937 +Border")

    panel.SetFont("s9 Bold c9CA3AF")
    panel.AddText("x230 y278 w440", "Gateway configuration")
    panel.SetFont("s9 cE5E7EB")
    panel.GatewayConfig := panel.AddEdit("x230 y300 w440 h78 -Wrap ReadOnly -TabStop cD1FAE5 Background111827 +Border")

    panel.SetFont("s9 cFFFFFF")
    panel.StartButton := panel.AddButton("x230 y394 w82 h30", "Start")
    panel.StartButton.OnEvent("Click", LS_ConnectorsPanelStart_Handler)
    panel.StopButton := panel.AddButton("x320 y394 w82 h30", "Stop")
    panel.StopButton.OnEvent("Click", LS_ConnectorsPanelStop_Handler)
    panel.RestartButton := panel.AddButton("x410 y394 w82 h30", "Restart")
    panel.RestartButton.OnEvent("Click", LS_ConnectorsPanelRestart_Handler)
    panel.OpenFolderButton := panel.AddButton("x500 y394 w82 h30", "Folder")
    panel.OpenFolderButton.OnEvent("Click", LS_ConnectorsPanelOpenFolder_Handler)
    panel.CopyConfigButton := panel.AddButton("x590 y394 w80 h30", "Copy")
    panel.CopyConfigButton.OnEvent("Click", LS_ConnectorsPanelCopyConfig_Handler)

    panel.SetFont("s8 c6B7280")
    panel.AddText("x24 y440 w646 Center", "Connector configuration is local; public routing remains owned by Lab Gateway.")
    panel.OnEvent("Close", LS_ConnectorsPanelClose_Handler)
    return panel
}

LS_ConnectorsPanelSelect(id) {
    global LS_CONNECTORS_PANEL
    if (!IsSet(LS_CONNECTORS_PANEL) || !IsObject(LS_CONNECTORS_PANEL))
        return
    LS_CONNECTORS_PANEL.SelectedConnectorId := id
    LS_ConnectorsPanelRender(LS_CONNECTORS_PANEL, LS_ConnectorRegistry.Get(id))
}

LS_ConnectorsPanelRefresh(*) {
    global LS_CONNECTORS_PANEL
    if (!IsSet(LS_CONNECTORS_PANEL) || !IsObject(LS_CONNECTORS_PANEL))
        return
    id := LS_CONNECTORS_PANEL.HasProp("SelectedConnectorId") ? LS_CONNECTORS_PANEL.SelectedConnectorId : "fmi"
    LS_ConnectorsPanelSelect(id)
}

LS_ConnectorsPanelRender(panel, connector) {
    panel.ConnectorTitle.Text := connector["label"]
    panel.ConnectorState.Text := LS_ConnectorsPanelStateText(connector)
    panel.ConnectorState.Opt("c" . LS_ConnectorsPanelStateColor(connector))
    panel.ConnectorDetails.Value := connector["summary"] . "`r`n`r`n" . LS_StrJoin(connector["details"], "`r`n")
    panel.GatewayConfig.Value := connector["gatewayConfig"] != "" ? connector["gatewayConfig"] : "No Gateway environment required yet."

    actions := LS_ConnectorsPanelActionMap(connector)
    panel.StartButton.Enabled := actions.Has("start")
    panel.StopButton.Enabled := actions.Has("stop") && connector["state"] = "running"
    panel.RestartButton.Enabled := actions.Has("restart")
    panel.OpenFolderButton.Enabled := actions.Has("open-folder")
    panel.CopyConfigButton.Enabled := actions.Has("copy-config")

    for id, btn in panel.ConnectorButtons {
        btn.Text := (id = connector["id"] ? "> " : "") . LS_ConnectorRegistry.Get(id)["label"]
        if (LS_ConnectorRegistry.Get(id)["planned"])
            btn.Text .= " (planned)"
    }
}

LS_ConnectorsPanelActionMap(connector) {
    actions := Map()
    for action in connector["actions"]
        actions[action] := true
    return actions
}

LS_ConnectorsPanelStateText(connector) {
    state := connector["state"]
    switch state {
        case "running":
            return "Running"
        case "available":
            return "Available"
        case "stopped":
            return "Stopped"
        case "missing":
            return "Missing local components"
        case "planned":
            return "Planned"
        default:
            return state
    }
}

LS_ConnectorsPanelStateColor(connector) {
    state := connector["state"]
    if (state = "running" || state = "available")
        return "22C55E"
    if (state = "stopped" || state = "planned")
        return "C08A2B"
    return "EF4444"
}

LS_ConnectorsPanelCurrentId(ctrl) {
    panel := ctrl.Gui
    return panel.HasProp("SelectedConnectorId") ? panel.SelectedConnectorId : "fmi"
}

LS_ConnectorsPanelSelect_Handler(ctrl, info) {
    LS_ConnectorsPanelSelect(ctrl.ConnectorId)
}

LS_ConnectorsPanelStart_Handler(ctrl, info) {
    ok := LS_ConnectorRegistry.Start(LS_ConnectorsPanelCurrentId(ctrl))
    MsgBox (ok ? "Connector started." : "Connector could not be started."), "Lab Station Connectors", (ok ? "OK Iconi" : "OK Iconx")
    LS_ConnectorsPanelRefresh()
}

LS_ConnectorsPanelStop_Handler(ctrl, info) {
    ok := LS_ConnectorRegistry.Stop(LS_ConnectorsPanelCurrentId(ctrl))
    MsgBox (ok ? "Connector stopped." : "Connector could not be stopped."), "Lab Station Connectors", (ok ? "OK Iconi" : "OK Iconx")
    LS_ConnectorsPanelRefresh()
}

LS_ConnectorsPanelRestart_Handler(ctrl, info) {
    ok := LS_ConnectorRegistry.Restart(LS_ConnectorsPanelCurrentId(ctrl))
    MsgBox (ok ? "Connector restarted." : "Connector could not be restarted."), "Lab Station Connectors", (ok ? "OK Iconi" : "OK Iconx")
    LS_ConnectorsPanelRefresh()
}

LS_ConnectorsPanelOpenFolder_Handler(ctrl, info) {
    ok := LS_ConnectorRegistry.OpenFolder(LS_ConnectorsPanelCurrentId(ctrl))
    if (!ok)
        MsgBox "Connector folder could not be opened.", "Lab Station Connectors", "OK Iconx"
}

LS_ConnectorsPanelCopyConfig_Handler(ctrl, info) {
    ok := LS_ConnectorRegistry.CopyGatewayConfig(LS_ConnectorsPanelCurrentId(ctrl))
    MsgBox (ok ? "Gateway configuration copied." : "No Gateway configuration available."), "Lab Station Connectors", (ok ? "OK Iconi" : "OK Iconx")
}

LS_ConnectorsPanelClose_Handler(guiObj) {
    global LS_CONNECTORS_PANEL
    LS_CONNECTORS_PANEL := ""
}
