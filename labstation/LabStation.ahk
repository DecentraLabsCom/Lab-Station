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
#Include system\WinRM.ahk
#Include system\EnergyAudit.ahk
#Include system\PowerManager.ahk
#Include system\ServiceManager.ahk
#Include service\SessionManager.ahk
#Include service\SessionGuard.ahk
#Include service\Telemetry.ahk
#Include service\Recovery.ahk
#Include service\FmuExecutor.ahk
#Include diagnostics\Status.ahk
#Include service\CommandQueue.ahk
#Include setup\Wizard.ahk
#Include ui\Tray.ahk
#Include ui\MainGui.ahk

; Entry point - call main function
if (A_Args.Length > 0) {
    commandExitCode := LabStationMain(A_Args)
    if (commandExitCode >= 0)
        ExitApp(commandExitCode)
} else {
    ExitApp
}

LabStationMain(args) {
    if (args.Length = 0) {
        LS_ShowHelp()
        return 2
    }

    command := StrLower(args[1])
    remaining := []
    if (args.Length > 1) {
        loop args.Length - 1
            remaining.Push(args[A_Index + 1])
    }

    exitCode := 0
    switch command {
        case "setup":
            exitCode := LS_RunSetupWizard() ? 0 : 1
        case "remoteapp":
            exitCode := LS_RegistryManager.SetRemoteAppPolicy() ? 0 : 2
        case "wol":
            exitCode := LS_WakeOnLan.Configure() ? 0 : 2
        case "winrm":
            exitCode := LS_HandleWinRMCommand(remaining)
        case "autostart":
            target := remaining.Length >= 1 ? remaining[1] : ""
            if (target != "") {
                exitCode := LS_Autostart.Configure(target) ? 0 : 2
            } else {
                exitCode := LS_Autostart.Configure() ? 0 : 2
            }
        case "status":
            LS_ShowMessage(LS_Status.SummaryText(), "Lab Station")
            exitCode := 0
        case "status-json":
            exitCode := LS_RunStatusJsonCommand(remaining)
        case "diagnostics":
            exitCode := LS_RunDiagnosticsCommand(remaining)
        case "tray":
            LS_StartTrayUI()
            return -1
        case "gui":
            LS_StartMainGui()
            return -1
        case "launch-app-control":
            exitCode := LS_LaunchAppControl(remaining) ? 0 : 2
        case "account":
            exitCode := LS_HandleAccountCommand(remaining)
        case "session":
            exitCode := LS_HandleSessionCommand(remaining)
        case "prepare-session":
            exitCode := LS_RunPrepareSession(remaining)
        case "release-session":
            exitCode := LS_RunReleaseSession(remaining)
        case "energy":
            exitCode := LS_HandleEnergyCommand(remaining)
        case "power":
            exitCode := LS_HandlePowerCommand(remaining)
        case "service":
            exitCode := LS_HandleServiceCommand(remaining)
        case "recovery":
            exitCode := LS_HandleRecoveryCommand(remaining)
        case "fmu-executor":
            exitCode := LS_HandleFmuExecutorCommand(remaining)
        case "service-loop":
            LS_ServiceLoop()
            return 0
        default:
            LS_LogWarning("Unknown command: " . command)
            LS_ShowHelp()
            exitCode := 2
    }
    return exitCode
}

LS_ShowHelp() {
    text := "Lab Station " . LAB_STATION_VERSION . "`n" .
        "Usage:" . "`n" .
        "  LabStation.exe setup                 # Interactive wizard" . "`n" .
        "  LabStation.exe remoteapp            # Configure fAllowUnlistedRemotePrograms" . "`n" .
        "  LabStation.exe wol                  # Configure Wake-on-LAN" . "`n" .
        "  LabStation.exe winrm [configure|status] # Configure or inspect WinRM" . "`n" .
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
        "  LabStation.exe fmu-executor [start|stop|restart|status]" . "`n" .
        "  LabStation.exe energy audit [--json=path]" . "`n"
    LS_ShowMessage(text, "Lab Station", "OK")
}

LS_HandleWinRMCommand(args) {
    action := args.Length >= 1 ? StrLower(args[1]) : "status"
    switch action {
        case "configure":
            pass := ""
            if (LS_WinRM.Configure("", &pass)) {
                LS_ShowMessage("WinRM HTTPS configured on port 5986.`nUser: " . LS_WinRM.DefaultGatewayUser . "`nPassword: " . pass . "`nGateway must trust the station certificate thumbprint shown in the log.", "Lab Station", "OK Iconi")
                return 0
            } else {
                LS_ShowMessage("WinRM HTTPS configuration failed. See the log for details.", "Lab Station", "OK Iconx")
                return 1
            }
        case "status":
            status := LS_WinRM.GetStatus()
            text := "Ready: " . (status.Has("ready") && status["ready"] ? "yes" : "no") . "`n"
            text .= "Service running: " . (status.Has("serviceRunning") && status["serviceRunning"] ? "yes" : "no") . "`n"
            text .= "HTTP listener: " . (status.Has("httpListener") && status["httpListener"] ? "yes" : "no") . "`n"
            text .= "HTTPS listener: " . (status.Has("httpsListener") && status["httpsListener"] ? "yes" : "no") . "`n"
            text .= "HTTPS port: " . (status.Has("httpsPort") && status["httpsPort"] ? "yes" : "no") . "`n"
            text .= "Certificate: " . (status.Has("certificateConfigured") && status["certificateConfigured"] ? "yes" : "no") . "`n"
            text .= "Firewall enabled: " . (status.Has("firewallEnabled") && status["firewallEnabled"] ? "yes" : "no")
            LS_ShowMessage(text, "Lab Station - WinRM")
            return (status.Has("ready") && status["ready"]) ? 0 : 1
        default:
            LS_ShowMessage("Usage: LabStation.exe winrm [configure|status]", "Lab Station", "OK Iconi")
            return 2
    }
}

LS_LaunchAppControl(args) {
    controllerExe := LAB_STATION_CONTROLLER_DIR "\AppControl.exe"
    controllerScript := LAB_STATION_CONTROLLER_DIR "\AppControl.ahk"
    if (FileExist(controllerExe)) {
        Run Format('"{1}" {2}', controllerExe, LS_BuildCliFromArgs(args))
        return true
    }
    if (!FileExist(controllerScript)) {
        LS_ShowMessage("AppControl was not found next to Lab Station.", "Lab Station", "OK Iconx")
        LS_LogError("AppControl.* not available")
        return false
    }
    Run Format('"{1}" "{2}" {3}', A_AhkPath, controllerScript, LS_BuildCliFromArgs(args))
    return true
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
        LS_ShowMessage("Report saved to " . target, "Lab Station")
        return 0
    } else {
        LS_ShowMessage("Unable to export report", "Lab Station", "OK Iconx")
        return 1
    }
}

LS_RunStatusJsonCommand(args) {
    target := args.Length >= 1 ? args[1] : ""
    if (target = "") {
        status := LS_Status.Collect()
        FileAppend(LS_ToJson(status), "*", "UTF-8")
        return 0
    }
    return LS_Status.ExportJson(target) ? 0 : 1
}

LS_HandleServiceCommand(args) {
    action := args.Length >= 1 ? StrLower(args[1]) : ""
    if (action = "install") {
        return LS_ServiceManager.Install() ? 0 : 1
    } else if (action = "uninstall") {
        return LS_ServiceManager.Uninstall() ? 0 : 1
    } else if (action = "start") {
        if (!LS_ServiceManager.Start()) {
            LS_ShowMessage("Service could not be started", "Lab Station", "OK Iconx")
            return 1
        }
        return 0
    } else if (action = "stop") {
        if (!LS_ServiceManager.Stop()) {
            LS_ShowMessage("Service could not be stopped", "Lab Station", "OK Iconx")
            return 1
        }
        return 0
    } else {
        status := LS_ServiceManager.StatusText()
        LS_ShowMessage(status, "Lab Station")
        return 0
    }
}

LS_HandleAccountCommand(args) {
    if (args.Length = 0) {
        LS_ShowMessage("Usage: LabStation.exe account [create|autologon|lockdown|setup] [user] [password]", "Lab Station", "OK Iconi")
        return 2
    }
    action := StrLower(args[1])
    user := args.Length >= 2 ? args[2] : ""
    password := args.Length >= 3 ? args[3] : ""
    switch action {
        case "create":
            pass := password
            if (LS_AccountManager.EnsureAccount(user, &pass)) {
                LS_ShowMessage(Format("Account ready: {1}`nPassword: {2}", (user && user != "") ? user : LS_AccountManager.DefaultUser, pass), "Lab Station", "OK Iconi")
                return 0
            } else {
                LS_ShowMessage("Account could not be created/updated", "Lab Station", "OK Iconx")
                return 1
            }
        case "autologon":
            if (!LS_AccountManager.ConfigureAutologon(user, password)) {
                LS_ShowMessage("Autologon could not be configured", "Lab Station", "OK Iconx")
                return 1
            } else {
                LS_ShowMessage("Autologon configured", "Lab Station", "OK Iconi")
                return 0
            }
        case "lockdown":
            if (!LS_AccountManager.ApplyLockdown(user)) {
                LS_ShowMessage("Lockdown could not be applied", "Lab Station", "OK Iconx")
                return 1
            } else {
                LS_ShowMessage("Lockdown applied", "Lab Station", "OK Iconi")
                return 0
            }
        case "setup":
            pass := password
            if (LS_AccountManager.Setup(user, &pass)) {
                LS_ShowMessage(Format("Account + Autologon ready. User: {1}`nPassword: {2}", (user && user != "") ? user : LS_AccountManager.DefaultUser, pass), "Lab Station", "OK Iconi")
                return 0
            } else {
                LS_ShowMessage("Account setup failed", "Lab Station", "OK Iconx")
                return 1
            }
        default:
            LS_ShowMessage("Unknown account subcommand", "Lab Station", "OK Iconx")
            return 2
    }
}

LS_RunPrepareSession(args := []) {
    opts := LS_ParseSessionOptions(args)
    if (LS_SessionManager.PrepareSession(opts)) {
        LS_ShowMessage("Session prepared successfully", "Lab Station", "OK Iconi")
        return 0
    } else {
        LS_ShowMessage("Prepare-session finished with warnings (see log)", "Lab Station", "OK Iconx")
        return 1
    }
}

LS_RunReleaseSession(args := []) {
    opts := LS_ParseSessionOptions(args)
    if (LS_SessionManager.ReleaseSession(opts)) {
        LS_ShowMessage("Session released successfully", "Lab Station", "OK Iconi")
        return 0
    } else {
        LS_ShowMessage("Release-session finished with warnings (see log)", "Lab Station", "OK Iconx")
        return 1
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
        LS_ShowMessage("Usage: LabStation.exe session guard [--grace=120] [--user=LABUSER]", "Lab Station", "OK Iconi")
        return 2
    }
    sub := StrLower(args[1])
    subArgs := []
    if (args.Length > 1) {
        loop args.Length - 1
            subArgs.Push(args[A_Index + 1])
    }
    switch sub {
        case "guard":
            return LS_RunSessionGuard(subArgs)
        default:
            LS_ShowMessage("Unknown session subcommand", "Lab Station", "OK Iconx")
            return 2
    }
}

LS_RunSessionGuard(args := []) {
    opts := LS_ParseGuardOptions(args)
    if (LS_SessionGuard.Run(opts)) {
        LS_ShowMessage("Local sessions cleared", "Lab Station", "OK Iconi")
        return 0
    } else {
        LS_ShowMessage("Session guard finished with warnings (see log)", "Lab Station", "OK Iconx")
        return 1
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
        return LS_RunEnergyAudit(subArgs)
    } else {
        LS_ShowMessage("Usage: LabStation.exe energy audit [--json=path]", "Lab Station", "OK Iconi")
        return 2
    }
}

LS_RunEnergyAudit(args := []) {
    opts := LS_ParseEnergyOptions(args)
    report := LS_EnergyAudit.Run()
    if (opts.Has("json")) {
        LS_EnergyAudit.SaveJson(opts["json"], report)
    }
    summary := LS_EnergyAudit.RenderSummary(report)
    LS_ShowMessage(summary, "Lab Station", "OK")
    return 0
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
        LS_ShowMessage("Usage: LabStation.exe power [shutdown|hibernate] [--delay=0] [--reason=text]", "Lab Station", "OK Iconi")
        return 2
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
            LS_ShowMessage("Unknown power subcommand", "Lab Station", "OK Iconx")
            return 2
    }
    if (success) {
        LS_ShowMessage("Power action scheduled", "Lab Station", "OK Iconi")
        return 0
    } else {
        LS_ShowMessage("Power action failed (see log)", "Lab Station", "OK Iconx")
        return 1
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
        LS_ShowMessage("Usage: LabStation.exe recovery reboot-if-needed [--force] [--timeout=20]", "Lab Station", "OK Iconi")
        return 2
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
            LS_ShowMessage(result["message"], "Lab Station", icon)
            return (result.Has("success") && result["success"]) ? 0 : 1
        default:
            LS_ShowMessage("Unknown recovery subcommand", "Lab Station", "OK Iconx")
            return 2
    }
}

LS_ParseRecoveryOptions(args) {
    opts := Map()
    for arg in args {
        lower := StrLower(arg)
        if (lower = "--force" || lower = "force") {
            opts["force"] := true
        } else if RegExMatch(arg, "^--timeout=(\d+)$", &m) {
            opts["timeout"] := m[1] + 0
        } else if RegExMatch(arg, "^--user=(.+)$", &m2) {
            opts["user"] := m2[1]
        } else if RegExMatch(arg, "^--reason=(.+)$", &m3) {
            opts["reason"] := m3[1]
        }
    }
    return opts
}

LS_HandleFmuExecutorCommand(args) {
    action := args.Length >= 1 ? StrLower(args[1]) : "status"
    switch action {
        case "start":
            if (LS_FmuExecutor.Start()) {
                LS_ShowMessage("FMU executor started", "Lab Station", "OK Iconi")
                return 0
            } else {
                LS_ShowMessage("FMU executor could not be started", "Lab Station", "OK Iconx")
                return 1
            }
        case "stop":
            return LS_FmuExecutor.Stop() ? 0 : 1
        case "restart":
            if (LS_FmuExecutor.Restart()) {
                LS_ShowMessage("FMU executor restarted", "Lab Station", "OK Iconi")
                return 0
            } else {
                LS_ShowMessage("FMU executor could not be restarted", "Lab Station", "OK Iconx")
                return 1
            }
        case "status":
            summary := LS_FmuExecutor.GetHealthSummary()
            text := "Available: " . (summary["available"] ? "yes" : "no") . "`n"
            text .= "Running: " . (summary["running"] ? "yes" : "no") . "`n"
            text .= "PID: " . summary["pid"] . "`n"
            text .= "Port: " . summary["port"] . "`n"
            text .= "Token configured: " . (summary["tokenConfigured"] ? "yes" : "no")
            LS_ShowMessage(text, "Lab Station - FMU Executor")
            return (summary["available"] && summary["running"] && summary["tokenConfigured"]) ? 0 : 1
        default:
            LS_ShowMessage("Usage: LabStation.exe fmu-executor [start|stop|restart|status]", "Lab Station", "OK Iconi")
            return 2
    }
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
        try {
            LS_FmuExecutor.Tick()
        } catch as e {
            LS_LogError("FMU executor tick error: " . e.Message)
        }
        Sleep sleepInterval
    }
    LS_FmuExecutor.Stop()
    LS_LogInfo("Background loop exiting")
}

LS_StopServiceLoop(*) {
    global LS_SERVICE_LOOP_ACTIVE
    LS_SERVICE_LOOP_ACTIVE := false
}
