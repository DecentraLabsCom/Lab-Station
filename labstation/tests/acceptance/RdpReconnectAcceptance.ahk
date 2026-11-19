#Requires AutoHotkey v2.0
#Include ..\..\core\Json.ahk
#Include ..\..\..\remote-app\lib\RdpMonitoring.ahk

; Manual Windows RDP acceptance check. Run inside the active LabUSER RDP
; session with LABSTATION_RDP_ACCEPTANCE=1, disconnect the RDP client, then
; reconnect before the 120-second grace expires. This harness never closes
; laboratory applications.

if (A_Args.Length >= 1 && A_Args[1] = "--validate")
    ExitApp(0)

if (EnvGet("LABSTATION_RDP_ACCEPTANCE") != "1") {
    MsgBox("Set LABSTATION_RDP_ACCEPTANCE=1 after confirming this is the intended test station.", "RDP acceptance test", "Icon!")
    ExitApp(2)
}

global ACCEPTANCE_ROOT := A_Temp "\LabStation-RdpReconnectAcceptance"
global ACCEPTANCE_RESULT_FILE := ACCEPTANCE_ROOT "\result.txt"
global ACCEPTANCE_GUI := 0
global ACCEPTANCE_DISCONNECT_TICK := 0
global ACCEPTANCE_SAW_GRACE := false
global ACCEPTANCE_FINISHED := false
global ACCEPTANCE_EXIT_CODE := 1

DirCreate(ACCEPTANCE_ROOT)
try FileDelete(ACCEPTANCE_RESULT_FILE)

if (RDP_DISCONNECT_GRACE_MS != 120000) {
    MsgBox("Expected the production RDP reconnect grace to be 120 seconds.", "RDP acceptance test", "Iconx")
    ExitApp(2)
}

ACCEPTANCE_GUI := Gui("+AlwaysOnTop", "Lab Station RDP reconnect acceptance")
ACCEPTANCE_GUI.AddText("w520", "Disconnect this RDP client, then reconnect within 119 seconds.`n`nThe test observes Windows session events and AppControl's grace state. It does not close lab applications.`n`nResult file: " ACCEPTANCE_RESULT_FILE)
ACCEPTANCE_GUI.OnEvent("Close", (*) => ExitApp(2))
ACCEPTANCE_GUI.Show("AutoSize")

SetupRdpMonitoring(ACCEPTANCE_GUI.Hwnd)
if (!WTS_NOTIFICATIONS_ACTIVE) {
    AcceptanceFinish("FAIL", "Windows did not register WTS session notifications.", 2)
} else {
    SetTimer(AcceptanceObserve, 100)
}

AcceptanceObserve(*) {
    global ACCEPTANCE_DISCONNECT_TICK, ACCEPTANCE_SAW_GRACE, ACCEPTANCE_FINISHED
    global CONTROLLER_DISCONNECT_GRACE_ACTIVE, CONTROLLER_DISCONNECT_GRACE_STARTED_TICK
    global RDP_DISCONNECT_GRACE_MS

    if (ACCEPTANCE_FINISHED)
        return

    if (CONTROLLER_DISCONNECT_GRACE_ACTIVE) {
        if (!ACCEPTANCE_SAW_GRACE) {
            ACCEPTANCE_SAW_GRACE := true
            ACCEPTANCE_DISCONNECT_TICK := CONTROLLER_DISCONNECT_GRACE_STARTED_TICK
        }

        elapsed := AcceptanceElapsed(ACCEPTANCE_DISCONNECT_TICK)
        if (elapsed >= RDP_DISCONNECT_GRACE_MS - 1000) {
            ControllerCancelDisconnectGrace("RDP acceptance safety cutoff")
            AcceptanceFinish("FAIL", "No reconnect was observed before the 120-second deadline.", 1)
        }
        return
    }

    if (ACCEPTANCE_SAW_GRACE && CONTROLLER_DISCONNECT_GRACE_STARTED_TICK = 0) {
        elapsed := AcceptanceElapsed(ACCEPTANCE_DISCONNECT_TICK)
        if (elapsed < RDP_DISCONNECT_GRACE_MS) {
            AcceptanceFinish("PASS", "RDP reconnect cancelled the disconnect grace; the workspace was retained.", 0)
        } else {
            AcceptanceFinish("FAIL", "Reconnect occurred after the grace deadline.", 1)
        }
    }
}

AcceptanceElapsed(startedTick) {
    elapsed := A_TickCount - startedTick
    return elapsed < 0 ? elapsed + 4294967296 : elapsed
}

AcceptanceFinish(status, message, exitCode) {
    global ACCEPTANCE_RESULT_FILE, ACCEPTANCE_GUI, ACCEPTANCE_FINISHED, ACCEPTANCE_EXIT_CODE

    if (ACCEPTANCE_FINISHED)
        return
    ACCEPTANCE_FINISHED := true
    ACCEPTANCE_EXIT_CODE := exitCode
    SetTimer(AcceptanceObserve, 0)
    FileAppend(status . " | " . message . "`n", ACCEPTANCE_RESULT_FILE, "UTF-8")
    ACCEPTANCE_GUI.AddText("w520 c" . (status = "PASS" ? "008000" : "B00020"), "`n" . status . ": " . message)
    SetTimer(AcceptanceExit, -5000)
}

AcceptanceExit(*) {
    global ACCEPTANCE_EXIT_CODE
    ExitApp(ACCEPTANCE_EXIT_CODE)
}
