; ============================================================================
; Lab Station - Dedicated lab workstation controller
; ============================================================================
#Requires AutoHotkey v2.0
#SingleInstance Force

#Include core\Config.ahk
#Include core\Logger.ahk
#Include core\Admin.ahk
#Include core\Shell.ahk
#Include core\Json.ahk
#Include system\RegistryManager.ahk
#Include system\WakeOnLan.ahk
#Include system\Autostart.ahk
#Include system\AccountManager.ahk
#Include system\EnergyAudit.ahk
#Include system\PowerManager.ahk
#Include system\ServiceManager.ahk
#Include system\AccountManager.ahk
#Include system\EnergyAudit.ahk
#Include system\PowerManager.ahk
#Include system\ServiceManager.ahk
#Include service\SessionManager.ahk
#Include service\SessionGuard.ahk
#Include service\Telemetry.ahk
#Include service\Recovery.ahk
#Include diagnostics\Status.ahk
#Include service\CommandQueue.ahk
#Include setup\Wizard.ahk
#Include ui\Tray.ahk
#Include ui\MainGui.ahk
#Include ui\Tray.ahk

; Entry point - call main function
if (A_Args.Length > 0 || !A_IsCompiled) {
    LabStationMain(A_Args)
}

LabStationMain(args) {
    if (args.Length = 0) {
        LS_ShowHelp()
        return
    }

    command := StrLower(args[1])
    remaining := []
    if (args.Length > 1) {
        loop args.Length - 1
            remaining.Push(args[A_Index + 1])
    }

    switch command {
        case "setup":
            LS_RunSetupWizard()
        case "remoteapp":
            LS_RegistryManager.SetRemoteAppPolicy()
        case "wol":
            LS_WakeOnLan.Configure()
        case "autostart":
            target := remaining.Length >= 1 ? remaining[1] : ""
            if (target != "") {
                LS_Autostart.Configure(target)
            } else {
                LS_Autostart.Configure()
            }
        case "status":
            MsgBox LS_Status.SummaryText(), "Lab Station"
        case "status-json":
            target := remaining.Length >= 1 ? remaining[1] : LAB_STATION_STATUS_FILE
            if (LS_Status.ExportJson(target)) {
                MsgBox "Report saved to " . target, "Lab Station"
            } else {
                MsgBox "Unable to export report", "Lab Station", "OK Iconx"
            }
        case "diagnostics":
            LS_RunDiagnosticsCommand(remaining)
        case "tray":
            LS_StartTrayUI()
        case "gui":
            LS_StartMainGui()
        case "launch-app-control":
            LS_LaunchAppControl(remaining)
        case "account":
            LS_HandleAccountCommand(remaining)
        case "session":
            LS_HandleSessionCommand(remaining)
        case "prepare-session":
            LS_RunPrepareSession(remaining)
        case "release-session":
            LS_RunReleaseSession(remaining)
        case "energy":
            LS_HandleEnergyCommand(remaining)
        case "power":
            LS_HandlePowerCommand(remaining)
        case "service":
            LS_HandleServiceCommand(remaining)
        case "recovery":
            LS_HandleRecoveryCommand(remaining)
        case "service-loop":
            LS_ServiceLoop()
        default:
            LS_LogWarning("Unknown command: " . command)
            LS_ShowHelp()
    }
}

LS_ShowHelp() {
    text := "Lab Station " . LAB_STATION_VERSION . "`n" .
        "Usage:" . "`n" .
        "  LabStation.exe setup                 # Interactive wizard" . "`n" .
        "  LabStation.exe remoteapp            # Configure fAllowUnlistedRemotePrograms" . "`n" .
        "  LabStation.exe wol                  # Configure Wake-on-LAN" . "`n" .
        "  LabStation.exe autostart [path]     # Register controller autostart" . "`n" .
        "  LabStation.exe status               # Quick summary" . "`n" .
        "  LabStation.exe status-json [path]   # Export diagnostics" . "`n" .
        "  LabStation.exe gui                  # Launch desktop GUI" . "`n" .
        "  LabStation.exe tray                 # Tray UI" . "`n" .
        "  LabStation.exe service [install|uninstall|start|stop]" . "`n" .
        "  LabStation.exe launch-app-control [args...]" . "`n" .
        "  LabStation.exe account [create|autologon|lockdown|setup] [user] [password]" . "`n" .
        "  LabStation.exe session guard [--grace=120] [--user=LABUSER]" . "`n" .
        "  LabStation.exe prepare-session [--user=LABUSER] [--reboot]" . "`n" .
        "  LabStation.exe release-session [--user=LABUSER] [--reboot]" . "`n" .
        "  LabStation.exe power [shutdown|hibernate] [--delay=0] [--reason=txt]" . "`n" .
        "  LabStation.exe recovery reboot-if-needed [--force] [--timeout=20]" . "`n" .
        "  LabStation.exe energy audit [--json=path]" . "`n"
    MsgBox text, "Lab Station", "OK"
}

LS_LaunchAppControl(args) {
    controllerExe := LAB_STATION_CONTROLLER_DIR "\AppControl.exe"
    controllerScript := LAB_STATION_CONTROLLER_DIR "\AppControl.ahk"
    if (FileExist(controllerExe)) {
        Run Format('"{1}" {2}', controllerExe, LS_BuildCliFromArgs(args))
        return
    }
    if (!FileExist(controllerScript)) {
        MsgBox "AppControl was not found next to Lab Station.", "Lab Station", "OK Iconx"
        LS_LogError("AppControl.* not available")
        return
    }
    Run Format('"{1}" "{2}" {3}', A_AhkPath, controllerScript, LS_BuildCliFromArgs(args))
}

LS_BuildCliFromArgs(args) {
    cli := ""
    for arg in args {
        cli .= (cli = "" ? "" : " ") . LS_EscapeCliArgument(arg)
    }
    return cli
}

LS_RunDiagnosticsCommand(args) {
    target := args.Length >= 1 ? args[1] : LAB_STATION_STATUS_FILE
    if (LS_Status.ExportJson(target)) {
        MsgBox "Report saved to " . target, "Lab Station"
    } else {
        MsgBox "Unable to export report", "Lab Station", "OK Iconx"
    }
}

LS_HandleServiceCommand(args) {
    action := args.Length >= 1 ? StrLower(args[1]) : ""
    if (action = "install") {
        LS_ServiceManager.Install()
    } else if (action = "uninstall") {
        LS_ServiceManager.Uninstall()
    } else if (action = "start") {
        if (!LS_ServiceManager.Start())
            MsgBox "Service could not be started", "Lab Station", "OK Iconx"
    } else if (action = "stop") {
        if (!LS_ServiceManager.Stop())
            MsgBox "Service could not be stopped", "Lab Station", "OK Iconx"
    } else {
        status := LS_ServiceManager.StatusText()
        MsgBox status, "Lab Station"
    }
}

LS_HandleAccountCommand(args) {
    if (args.Length = 0) {
        MsgBox "Usage: LabStation.exe account [create|autologon|lockdown|setup] [user] [password]", "Lab Station", "OK Iconi"
        return
    }
    action := StrLower(args[1])
    user := args.Length >= 2 ? args[2] : ""
    password := args.Length >= 3 ? args[3] : ""
    switch action {
        case "create":
            pass := password
            if (LS_AccountManager.EnsureAccount(user, pass)) {
                MsgBox Format("Account ready: {1}`nPassword: {2}", (user && user != "") ? user : LS_AccountManager.DefaultUser, pass), "Lab Station", "OK Iconi"
            } else {
                MsgBox "Account could not be created/updated", "Lab Station", "OK Iconx"
            }
        case "autologon":
            if (!LS_AccountManager.ConfigureAutologon(user, password)) {
                MsgBox "Autologon could not be configured", "Lab Station", "OK Iconx"
            } else {
                MsgBox "Autologon configured", "Lab Station", "OK Iconi"
            }
        case "lockdown":
            if (!LS_AccountManager.ApplyLockdown(user)) {
                MsgBox "Lockdown could not be applied", "Lab Station", "OK Iconx"
            } else {
                MsgBox "Lockdown applied", "Lab Station", "OK Iconi"
            }
        case "setup":
            pass := password
            if (LS_AccountManager.Setup(user, pass)) {
                MsgBox Format("Account + Autologon ready. User: {1}`nPassword: {2}", (user && user != "") ? user : LS_AccountManager.DefaultUser, pass), "Lab Station", "OK Iconi"
            } else {
                MsgBox "Account setup failed", "Lab Station", "OK Iconx"
            }
        default:
            MsgBox "Unknown account subcommand", "Lab Station", "OK Iconx"
    }
}

LS_RunPrepareSession(args := []) {
    opts := LS_ParseSessionOptions(args)
    if (LS_SessionManager.PrepareSession(opts)) {
        MsgBox "Session prepared successfully", "Lab Station", "OK Iconi"
    } else {
        MsgBox "Prepare-session finished with warnings (see log)", "Lab Station", "OK Iconx"
    }
}

LS_RunReleaseSession(args := []) {
    opts := LS_ParseSessionOptions(args)
    if (LS_SessionManager.ReleaseSession(opts)) {
        MsgBox "Session released successfully", "Lab Station", "OK Iconi"
    } else {
        MsgBox "Release-session finished with warnings (see log)", "Lab Station", "OK Iconx"
    }
}

LS_ParseSessionOptions(args) {
    opts := Map()
    for arg in args {
        lower := StrLower(arg)
        if (lower = "--reboot" || lower = "reboot") {
            opts["reboot"] := true
        } else if RegExMatch(lower, "^--reboot-timeout=(\d+)$", &m) {
            opts["reboot"] := true
            opts["rebootTimeout"] := m[1] + 0
        } else if RegExMatch(arg, "^--user=(.+)$", &m2) {
            opts["user"] := m2[1]
        } else if (lower = "--no-guard" || lower = "--guard=no") {
            opts["guard"] := false
        } else if (lower = "--guard" || lower = "--guard=yes") {
            opts["guard"] := true
        } else if RegExMatch(lower, "^--guard-grace=(\d+)$", &mg) {
            opts["guardGrace"] := mg[1] + 0
        } else if RegExMatch(arg, "^--guard-message=(.+)$", &mm) {
            opts["guardMessage"] := mm[1]
        } else if (lower = "--guard-silent" || lower = "--guard-notify=no") {
            opts["guardNotify"] := false
        } else if (lower = "--guard-notify" || lower = "--guard-notify=yes") {
            opts["guardNotify"] := true
        }
    }
    return opts
}

LS_HandleSessionCommand(args) {
    if (args.Length = 0) {
        MsgBox "Usage: LabStation.exe session guard [--grace=120] [--user=LABUSER]", "Lab Station", "OK Iconi"
        return
    }
    sub := StrLower(args[1])
    subArgs := []
    if (args.Length > 1) {
        loop args.Length - 1
            subArgs.Push(args[A_Index + 1])
    }
    switch sub {
        case "guard":
            LS_RunSessionGuard(subArgs)
        default:
            MsgBox "Unknown session subcommand", "Lab Station", "OK Iconx"
    }
}

LS_RunSessionGuard(args := []) {
    opts := LS_ParseGuardOptions(args)
    if (LS_SessionGuard.Run(opts)) {
        MsgBox "Local sessions cleared", "Lab Station", "OK Iconi"
    } else {
        MsgBox "Session guard finished with warnings (see log)", "Lab Station", "OK Iconx"
    }
}

LS_ParseGuardOptions(args) {
    opts := Map()
    for arg in args {
        lower := StrLower(arg)
        if RegExMatch(lower, "^--grace=(\d+)$", &m) {
            opts["grace"] := m[1] + 0
        } else if RegExMatch(arg, "^--user=(.+)$", &m2) {
            opts["user"] := m2[1]
        } else if RegExMatch(arg, "^--message=(.+)$", &m3) {
            opts["message"] := m3[1]
        } else if (lower = "--no-notify") {
            opts["notify"] := false
        } else if (lower = "--silent") {
            opts["notify"] := false
        } else if (lower = "--soft") {
            opts["force"] := false
        }
    }
    return opts
}

LS_HandleEnergyCommand(args) {
    sub := args.Length >= 1 ? StrLower(args[1]) : "audit"
    subArgs := []
    if (args.Length > 1) {
        loop args.Length - 1
            subArgs.Push(args[A_Index + 1])
    }
    if (sub = "" || sub = "audit") {
        LS_RunEnergyAudit(subArgs)
    } else {
        MsgBox "Usage: LabStation.exe energy audit [--json=path]", "Lab Station", "OK Iconi"
    }
}

LS_RunEnergyAudit(args := []) {
    opts := LS_ParseEnergyOptions(args)
    report := LS_EnergyAudit.Run()
    if (opts.Has("json")) {
        LS_EnergyAudit.SaveJson(opts["json"], report)
    }
    summary := LS_EnergyAudit.RenderSummary(report)
    MsgBox summary, "Lab Station", "OK"
}

LS_ParseEnergyOptions(args) {
    opts := Map()
    for arg in args {
        if RegExMatch(arg, "^--json=(.+)$", &m) {
            opts["json"] := m[1]
        }
    }
    return opts
}

LS_HandlePowerCommand(args) {
    if (args.Length = 0) {
        MsgBox "Usage: LabStation.exe power [shutdown|hibernate] [--delay=0] [--reason=text]", "Lab Station", "OK Iconi"
        return
    }
    sub := StrLower(args[1])
    powerArgs := []
    if (args.Length > 1) {
        loop args.Length - 1
            powerArgs.Push(args[A_Index + 1])
    }
    opts := LS_ParsePowerOptions(powerArgs)
    success := false
    switch sub {
        case "shutdown":
            success := LS_PowerManager.Shutdown(opts)
        case "hibernate":
            success := LS_PowerManager.Hibernate(opts)
        default:
            MsgBox "Unknown power subcommand", "Lab Station", "OK Iconx"
            return
    }
    if (success) {
        MsgBox "Power action scheduled", "Lab Station", "OK Iconi"
    } else {
        MsgBox "Power action failed (see log)", "Lab Station", "OK Iconx"
    }
}

LS_ParsePowerOptions(args) {
    opts := Map()
    for arg in args {
        lower := StrLower(arg)
        if RegExMatch(lower, "^--delay=(\d+)$", &d) {
            opts["delay"] := d[1] + 0
        } else if RegExMatch(arg, "^--reason=(.+)$", &r) {
            opts["reason"] := r[1]
        } else if (lower = "--no-force" || lower = "--soft") {
            opts["force"] := false
        } else if (lower = "--force") {
            opts["force"] := true
        } else if (lower = "--skip-wake-check") {
            opts["skipWakeCheck"] := true
        } else if (lower = "--require-wake") {
            opts["failOnWakeIssues"] := true
        } else if (lower = "--repair-wake=no" || lower = "--no-repair-wake") {
            opts["repairWake"] := false
        } else if (lower = "--repair-wake" || lower = "--repair-wake=yes") {
            opts["repairWake"] := true
        }
    }
    return opts
}

LS_HandleRecoveryCommand(args) {
    if (args.Length = 0) {
        MsgBox "Usage: LabStation.exe recovery reboot-if-needed [--force] [--timeout=20]", "Lab Station", "OK Iconi"
        return
    }
    sub := StrLower(args[1])
    subArgs := []
    if (args.Length > 1) {
        loop args.Length - 1
            subArgs.Push(args[A_Index + 1])
    }
    switch sub {
        case "reboot-if-needed":
            opts := LS_ParseRecoveryOptions(subArgs)
            result := LS_Recovery.RebootIfNeeded(opts)
            icon := (result.Has("success") && !result["success"]) ? "OK Iconx" : "OK Iconi"
            MsgBox result["message"], "Lab Station", icon
        default:
            MsgBox "Unknown recovery subcommand", "Lab Station", "OK Iconx"
    }
}

LS_ParseRecoveryOptions(args) {
    opts := Map()
    for arg in args {
        lower := StrLower(arg)
        if (lower = "--force" || lower = "force") {
            opts["force"] := true
        } else if RegExMatch(arg, "^--timeout=(\\d+)$", &m) {
            opts["timeout"] := m[1] + 0
        } else if RegExMatch(arg, "^--user=(.+)$", &m2) {
            opts["user"] := m2[1]
        } else if RegExMatch(arg, "^--reason=(.+)$", &m3) {
            opts["reason"] := m3[1]
        }
    }
    return opts
}

global LS_SERVICE_LOOP_ACTIVE := true

LS_ServiceLoop() {
    global LS_SERVICE_LOOP_ACTIVE
    LS_LogInfo("Background loop started")
    OnExit(LS_StopServiceLoop)
    statusInterval := 60000
    sleepInterval := 5000
    nextStatus := 0
    while LS_SERVICE_LOOP_ACTIVE {
        now := A_TickCount
        if (nextStatus = 0 || now >= nextStatus) {
            status := LS_Status.Collect()
            LS_Status.ExportJson(LAB_STATION_STATUS_FILE, status)
            LS_Telemetry.Publish(status)
            nextStatus := now + statusInterval
        }
        try {
            LS_CommandQueue.ProcessPending()
        } catch as e {
            LS_LogError("Command loop error: " . e.Message)
        }
        Sleep sleepInterval
    }
    LS_LogInfo("Background loop exiting")
}

LS_StopServiceLoop(*) {
    global LS_SERVICE_LOOP_ACTIVE
    LS_SERVICE_LOOP_ACTIVE := false
}
