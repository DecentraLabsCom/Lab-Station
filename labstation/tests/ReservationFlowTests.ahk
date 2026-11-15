#Requires AutoHotkey v2.0
#Include TestSupport.ahk
#Include ..\service\SessionGuard.ahk
#Include ..\service\FmuExecutor.ahk
#Include ..\service\SessionManager.ahk
#Include ParityTestSupport.ahk

global TEST_FAILURES := 0
global TEST_ROOT := A_Temp "\LabStation-ReservationFlowTests-" A_TickCount
global ORIGINAL_STATE_FILE := LAB_STATION_SERVICE_STATE_FILE
global ORIGINAL_LOCAL_MODE_FLAG := LAB_STATION_LOCAL_MODE_FLAG

DirCreate(TEST_ROOT)
LAB_STATION_SERVICE_STATE_FILE := TEST_ROOT "\service-state.ini"
LAB_STATION_LOCAL_MODE_FLAG := TEST_ROOT "\local-mode.flag"

RunReservationFlowTests()

class RecordingSessionManager extends LS_SessionManager {
    static calls := []
    static guardResult := true
    static closeResult := true
    static fmuResult := true
    static clearResult := true
    static resetResult := true
    static logoffResult := true
    static releaseInventoryError := false
    static rebootResult := true
    static releaseSessions := []
    static prepareRemoteSessions := []
    static prepareRemoteSessionSnapshots := []
    static prepareRemoteSessionSnapshotIndex := 0

    static GetPrepareLocalSessions(managedUser) {
        return []
    }

    static GetPrepareRemoteLabUserSessions(managedUser) {
        if (this.prepareRemoteSessionSnapshots.Length > 0) {
            index := Min(this.prepareRemoteSessionSnapshotIndex + 1, this.prepareRemoteSessionSnapshots.Length)
            this.prepareRemoteSessionSnapshotIndex := index
            return this.prepareRemoteSessionSnapshots[index]
        }
        return this.prepareRemoteSessions
    }

    static Reset() {
        this.calls := []
        this.guardResult := true
        this.closeResult := true
        this.fmuResult := true
        this.clearResult := true
        this.resetResult := true
        this.logoffResult := true
        this.releaseInventoryError := false
        this.rebootResult := true
        this.LastReleaseExitCode := 0
        this.prepareRemoteSessions := []
        this.prepareRemoteSessionSnapshots := []
        this.prepareRemoteSessionSnapshotIndex := 0
        this.releaseSessions := [Map("user", "LABUSER", "session", "rdp-tcp#1", "id", "4", "state", "Active")]
        try FileDelete(LAB_STATION_SERVICE_STATE_FILE)
    }

    static RunSessionGuard(options) {
        this.calls.Push(Map("name", "guard", "options", options))
        return this.guardResult
    }

    static CloseControllerProcesses() {
        this.calls.Push(Map("name", "close-controller"))
        return this.closeResult
    }

    static CleanFmuExecutorState() {
        this.calls.Push(Map("name", "fmu-cleanup"))
        return this.fmuResult
    }

    static ClearLabUserWorkingDirs(user := "") {
        this.calls.Push(Map("name", "clear-profile", "user", user))
        return this.clearResult
    }

    static ResetControllerLogs() {
        this.calls.Push(Map("name", "reset-controller"))
        return this.resetResult
    }

    static GetReleaseSessionInventory() {
        this.calls.Push(Map("name", "query-sessions"))
        if (this.releaseInventoryError)
            throw Error("synthetic session inventory failure")
        return this.releaseSessions
    }

    static LogoffRemoteSession(session) {
        this.calls.Push(Map("name", "logoff-remote", "id", session["id"]))
        if (this.logoffResult) {
            remaining := []
            for item in this.releaseSessions {
                if (item["id"] != session["id"])
                    remaining.Push(item)
            }
            this.releaseSessions := remaining
        }
        return this.logoffResult
    }

    static TriggerReboot(timeout := 0) {
        this.calls.Push(Map("name", "reboot", "timeout", timeout))
        return this.rebootResult
    }
}

class RecordingProfileCleaner extends LS_SessionManager {
    static profileRoot := ""
    static cleanCalls := []

    static GetUserProfilePath(user) {
        return this.profileRoot
    }

    static CleanDirectory(path) {
        this.cleanCalls.Push(path)
        if (!DirExist(path))
            return true
        try {
            Loop Files, path . "\*", "FD" {
                if InStr(A_LoopFileAttrib, "D")
                    DirDelete(A_LoopFileFullPath, true)
                else
                    FileDelete(A_LoopFileFullPath)
            }
            return true
        } catch {
            return false
        }
    }
}

class FailingInventorySessionManager extends LS_SessionManager {
    static GetPrepareLocalSessions(managedUser) {
        throw Error("synthetic session inventory failure")
    }
}

RunReservationFlowTests() {
    global ORIGINAL_STATE_FILE, ORIGINAL_LOCAL_MODE_FLAG, LAB_STATION_SERVICE_STATE_FILE, LAB_STATION_LOCAL_MODE_FLAG, TEST_ROOT

    try {
        TestPrepareSessionSuccess()
        TestPrepareSessionFailureStillRunsCleanup()
        TestManualPrepareRefusesRemoteLabUserSession()
        TestManualPrepareRechecksRemoteLabUserBeforeCleanup()
        TestLeasePrepareKeepsItsReservationFlow()
        TestPrepareSessionFailsClosedWhenSessionInventoryUnavailable()
        TestPrepareLocalSessionPolicyMatchesSharedMatrix()
        TestPrepareCleanupClearsSharedEphemeralCategories()
        TestReleaseSessionWithoutReboot()
        TestReleaseTargetsOnlyRemoteLabUserSessions()
        TestReleaseSessionWithReboot()
        TestReleaseSessionDefersRebootForLocalConsoleUser()
        TestReleaseFMUCleanupFailureBlocksReboot()
        TestReleaseSessionInventoryFailureIsRetryable()
        TestReleaseSessionFailureStillRecordsFailure()
    } catch as err {
        LS_TestFail("Unhandled reservation-flow test exception: " . err.Message)
    }

    LAB_STATION_SERVICE_STATE_FILE := ORIGINAL_STATE_FILE
    LAB_STATION_LOCAL_MODE_FLAG := ORIGINAL_LOCAL_MODE_FLAG
    try DirDelete(TEST_ROOT, true)

    if (TEST_FAILURES > 0) {
        LS_TestOutput("ReservationFlowTests failed: " . TEST_FAILURES . " failure(s)`n")
        ExitApp(1)
    }

    LS_TestOutput("ReservationFlowTests passed`n")
    ExitApp(0)
}

TestPrepareSessionSuccess() {
    RecordingSessionManager.Reset()

    options := Map(
        "user", "LABUSER",
        "guard", false,
        "extraCleaners", [TestExtraCleaner]
    )

    success := RecordingSessionManager.PrepareSession(options)

    LS_TestAssert(success, "prepare-session succeeds when all operations succeed")
    AssertCallSequence([
        "close-controller",
        "fmu-cleanup",
        "clear-profile",
        "reset-controller",
        "extra-cleaner"
    ], "prepare-session operation order")

    LS_TestAssert(RecordingSessionManager.calls[3]["user"] = "LABUSER", "prepare-session forwards the selected user")

    state := LS_ServiceState.ReadSection("prepare-session")
    LS_TestAssert(state.Has("success") && state["success"], "prepare-session records success")
    LS_TestAssert(state.Has("user") && state["user"] = "LABUSER", "prepare-session records the selected user")
}

TestPrepareSessionFailureStillRunsCleanup() {
    RecordingSessionManager.Reset()
    RecordingSessionManager.clearResult := false

    success := RecordingSessionManager.PrepareSession(Map("user", "LABUSER"))

    LS_TestAssert(!success, "prepare-session reports failure when profile cleanup fails")
    LS_TestAssert(RecordingSessionManager.LastPrepareExitCode = 2, "incomplete cleanup is a hard failure rather than a successful warning")
    AssertCallSequence([
        "close-controller",
        "fmu-cleanup",
        "clear-profile",
        "reset-controller"
    ], "prepare-session continues cleanup after a failed operation")

    state := LS_ServiceState.ReadSection("prepare-session")
    LS_TestAssert(state.Has("success") && !state["success"], "prepare-session records failure")
}

TestManualPrepareRefusesRemoteLabUserSession() {
    RecordingSessionManager.Reset()
    RecordingSessionManager.prepareRemoteSessions := [Map(
        "user", "LABUSER",
        "session", "rdp-tcp#1",
        "id", "4",
        "state", "Active"
    )]

    success := RecordingSessionManager.PrepareSession(Map("user", "LABUSER"), true)

    LS_TestAssert(!success, "manual Prepare refuses to clean an active remote LABUSER workspace")
    LS_TestAssert(RecordingSessionManager.LastPrepareExitCode = 2, "remote LABUSER use is a hard Prepare refusal")
    LS_TestAssert(RecordingSessionManager.LastPrepareMetadata["code"] = "STATION_REMOTE_SESSION_ACTIVE",
        "manual Prepare identifies the active remote LABUSER session")
    LS_TestAssert(RecordingSessionManager.LastPrepareMetadata["cleanupSkipped"],
        "manual Prepare identifies that no cleanup ran")
    LS_TestAssert(InStr(RecordingSessionManager.LastPrepareMessage, "Downloads") > 0,
        "manual Prepare explains which working data it would delete")
    LS_TestAssert(InStr(RecordingSessionManager.LastPrepareMessage, "no cleanup ran") > 0,
        "manual Prepare confirms that it made no cleanup changes")
    LS_TestAssert(RecordingSessionManager.calls.Length = 0,
        "manual Prepare does not close apps or clear working data while LABUSER is connected")
}

TestManualPrepareRechecksRemoteLabUserBeforeCleanup() {
    RecordingSessionManager.Reset()
    remoteLabUser := Map("user", "LABUSER", "session", "rdp-tcp#1", "id", "4", "state", "Active")
    RecordingSessionManager.prepareRemoteSessionSnapshots := [[], [remoteLabUser]]

    success := RecordingSessionManager.PrepareSession(Map("user", "LABUSER"), true)

    LS_TestAssert(!success, "manual Prepare rechecks remote LABUSER immediately before cleanup")
    LS_TestAssert(RecordingSessionManager.LastPrepareMetadata["code"] = "STATION_REMOTE_SESSION_ACTIVE",
        "the second session inventory blocks cleanup")
    LS_TestAssert(RecordingSessionManager.calls.Length = 0,
        "no workspace cleanup runs after the remote session appears")
}

TestLeasePrepareKeepsItsReservationFlow() {
    RecordingSessionManager.Reset()
    RecordingSessionManager.prepareRemoteSessions := [Map(
        "user", "LABUSER",
        "session", "rdp-tcp#1",
        "id", "4",
        "state", "Active"
    )]

    success := RecordingSessionManager.PrepareSession(Map("user", "LABUSER"))

    LS_TestAssert(success, "reservation Prepare keeps its existing lifecycle when LABUSER is connected")
    LS_TestAssert(RecordingSessionManager.calls.Length > 0,
        "reservation Prepare continues its configured cleanup flow")
}

TestPrepareSessionFailsClosedWhenSessionInventoryUnavailable() {
    FailingInventorySessionManager.LastPrepareExitCode := 0
    success := FailingInventorySessionManager.PrepareSession(Map("user", "LABUSER"))
    state := LS_ServiceState.ReadSection("prepare-session")

    LS_TestAssert(!success, "prepare-session refuses when local sessions cannot be inspected")
    LS_TestAssert(FailingInventorySessionManager.LastPrepareExitCode = 2, "unknown local-session state is a hard refusal")
    LS_TestAssert(state.Has("success") && !state["success"], "session inventory failure is recorded as an unsuccessful prepare")
    LS_TestAssert(state.Has("reason") && InStr(state["reason"], "session inventory unavailable"),
        "prepare result records why admission was refused")
}

TestPrepareLocalSessionPolicyMatchesSharedMatrix() {
    matrix := LS_TestLoadParityMatrix()
    policy := matrix["sessionSafety"]["prepareDecision"]

    LS_TestAssert(
        LS_SessionManager.PrepareLocalSessionDecision("hybrid", 0, false) = policy["noLocalSession"],
        "preparation continues when the local-session inventory is empty"
    )
    LS_TestAssert(
        LS_SessionManager.PrepareLocalSessionDecision("dedicated", 1, false) = policy["dedicatedLocalSession"],
        "dedicated stations refuse preparation while a local user is active"
    )
    LS_TestAssert(
        LS_SessionManager.PrepareLocalSessionDecision("hybrid", 1, false) = policy["hybridLocalSessionWithoutAuthorization"],
        "hybrid stations protect local users unless eviction is authorized"
    )
    LS_TestAssert(
        LS_SessionManager.PrepareLocalSessionDecision("hybrid", 1, true) = policy["hybridLocalSessionWithAuthorization"],
        "hybrid stations evict local users only after explicit authorization"
    )
}

TestPrepareCleanupClearsSharedEphemeralCategories() {
    global TEST_ROOT
    matrix := LS_TestLoadParityMatrix()
    cleanup := matrix["prepareCleanup"]
    RecordingProfileCleaner.profileRoot := TEST_ROOT . "\profile-fixture"
    RecordingProfileCleaner.cleanCalls := []

    categoryPaths := Map(
        "temporary", "AppData\Local\Temp",
        "application-cache", "AppData\Local\Microsoft\Windows\INetCache",
        "downloads", "Downloads",
        "scratch", "Documents\LabStationScratch",
        "recent-items", "AppData\Roaming\Microsoft\Windows\Recent"
    )
    for _, category in cleanup["requiredCategories"] {
        LS_TestAssert(categoryPaths.Has(category), "Windows cleanup maps shared category " . category)
        if (!categoryPaths.Has(category))
            continue
        path := RecordingProfileCleaner.profileRoot . "\" . categoryPaths[category]
        DirCreate(path)
        FileAppend("reservation data", path . "\session-data.tmp", "UTF-8")
    }
    managedSettings := RecordingProfileCleaner.profileRoot . "\Documents\LabStationManaged\application.json"
    DirCreate(RecordingProfileCleaner.profileRoot . "\Documents\LabStationManaged")
    FileAppend("managed configuration", managedSettings, "UTF-8")

    success := RecordingProfileCleaner.ClearLabUserWorkingDirs("fixture-user")

    LS_TestAssert(success, "Windows cleanup succeeds for a disposable profile tree")
    for _, category in cleanup["requiredCategories"] {
        if (!categoryPaths.Has(category))
            continue
        cleanedFile := RecordingProfileCleaner.profileRoot . "\" . categoryPaths[category] . "\session-data.tmp"
        LS_TestAssert(!FileExist(cleanedFile), "Windows cleanup removes " . category . " data")
    }
    LS_TestAssert(LS_TestArrayContains(cleanup["preserveCategories"], "managed-application-configuration"),
        "shared cleanup policy protects managed application configuration")
    LS_TestAssert(FileExist(managedSettings), "Windows cleanup preserves managed application configuration")
    LS_TestAssert(RecordingProfileCleaner.cleanCalls.Length = cleanup["requiredCategories"].Length,
        "Windows cleanup visits each shared ephemeral category")
}

TestReleaseSessionWithoutReboot() {
    RecordingSessionManager.Reset()

    success := RecordingSessionManager.ReleaseSession(Map("user", "LABUSER"))

    LS_TestAssert(success, "release-session succeeds without reboot")
    AssertCallSequence([
        "query-sessions",
        "logoff-remote",
        "fmu-cleanup"
    ], "release-session closes only the remote lab-user session by default")
    LS_TestAssert(RecordingSessionManager.LastReleaseMetadata["fmuCleanupCompleted"],
        "release-session records completed FMU cleanup")

    state := LS_ServiceState.ReadSection("release-session")
    LS_TestAssert(state.Has("success") && state["success"], "release-session records success")
    LS_TestAssert(!state.Has("rebootRequested"), "release-session omits reboot metadata when not requested")
}

TestReleaseTargetsOnlyRemoteLabUserSessions() {
    RecordingSessionManager.Reset()
    RecordingSessionManager.releaseSessions := [
        Map("user", "LABUSER", "session", "console", "id", "1", "state", "Active"),
        Map("user", "LABUSER", "session", "rdp-tcp#1", "id", "4", "state", "Active"),
        Map("user", "LABUSER", "session", "rdp-tcp#2", "id", "5", "state", "Disc"),
        Map("user", "Instructor", "session", "rdp-tcp#3", "id", "6", "state", "Active")
    ]

    success := RecordingSessionManager.LogoffRemoteLabUser("LABUSER")

    LS_TestAssert(success, "remote LABUSER sessions are logged off")
    LS_TestAssert(RecordingSessionManager.calls.Length = 3
        && RecordingSessionManager.calls[2]["id"] = "4"
        && RecordingSessionManager.calls[3]["id"] = "5",
        "release logs off active and disconnected LABUSER RDP sessions only")
    LS_TestAssert(RecordingSessionManager.releaseSessions.Length = 2
        && RecordingSessionManager.releaseSessions[1]["session"] = "console"
        && RecordingSessionManager.releaseSessions[2]["user"] = "Instructor",
        "release preserves the physical LABUSER console and other remote users")
}

TestReleaseSessionWithReboot() {
    RecordingSessionManager.Reset()

    options := Map("user", "LABUSER", "reboot", true, "rebootTimeout", 15)
    success := RecordingSessionManager.ReleaseSession(options)

    LS_TestAssert(success, "release-session succeeds with reboot")
    AssertCallSequence([
        "query-sessions",
        "logoff-remote",
        "fmu-cleanup",
        "query-sessions",
        "reboot"
    ], "release-session reboots after confirming the local console is clear")
    LS_TestAssert(RecordingSessionManager.calls[5]["timeout"] = 0, "release-session requests reboot only after the safe-session wait")

    state := LS_ServiceState.ReadSection("release-session")
    LS_TestAssert(state.Has("rebootRequested") && state["rebootRequested"], "release-session records the explicit reboot request")
    LS_TestAssert(state.Has("rebootScheduled") && state["rebootScheduled"], "release-session records that reboot was scheduled")
    LS_TestAssert(state.Has("rebootDeferred") && !state["rebootDeferred"], "release-session records that reboot was not deferred")
    LS_TestAssert(state.Has("rebootTimeout") && state["rebootTimeout"] = 15, "release-session records reboot timeout")
}

TestReleaseSessionDefersRebootForLocalConsoleUser() {
    RecordingSessionManager.Reset()
    RecordingSessionManager.releaseSessions.Push(Map(
        "user", "LABUSER",
        "session", "console",
        "id", "1",
        "state", "Active"
    ))
    RecordingSessionManager.releaseSessions.Push(Map(
        "user", "Instructor",
        "session", "console",
        "id", "2",
        "state", "Active"
    ))

    success := RecordingSessionManager.ReleaseSession(Map(
        "user", "LABUSER",
        "reboot", true,
        "rebootTimeout", 0
    ))

    LS_TestAssert(success, "remote release succeeds when an instructor remains at the console")
    LS_TestAssert(RecordingSessionManager.releaseSessions.Length = 2
        && RecordingSessionManager.releaseSessions[1]["user"] = "LABUSER"
        && RecordingSessionManager.releaseSessions[1]["session"] = "console"
        && RecordingSessionManager.releaseSessions[2]["user"] = "Instructor",
        "release-session preserves the local LABUSER and instructor console sessions")
    LS_TestAssert(RecordingSessionManager.calls.Length = 4
        && RecordingSessionManager.calls[4]["name"] = "query-sessions",
        "release-session defers reboot while a physical console session remains")
    state := LS_ServiceState.ReadSection("release-session")
    LS_TestAssert(state.Has("rebootRequested") && state["rebootRequested"], "release-session records the explicit reboot request")
    LS_TestAssert(state.Has("rebootScheduled") && !state["rebootScheduled"], "deferred reboot is not reported as scheduled")
    LS_TestAssert(state.Has("rebootDeferred") && state["rebootDeferred"], "release-session records the deferred reboot")
    LS_TestAssert(RecordingSessionManager.LastReleaseExitCode = 1, "deferred reboot is reported as a warning while release succeeds")
    LS_TestAssert(state.Has("rebootReason") && state["rebootReason"] = "physical console session remains active",
        "release-session records why reboot was deferred")
}

TestReleaseFMUCleanupFailureBlocksReboot() {
    RecordingSessionManager.Reset()
    RecordingSessionManager.fmuResult := false

    success := RecordingSessionManager.ReleaseSession(Map(
        "user", "LABUSER",
        "reboot", true,
        "rebootTimeout", 20
    ))

    LS_TestAssert(!success, "release-session reports FMU cleanup failure")
    LS_TestAssert(RecordingSessionManager.LastReleaseExitCode = 2,
        "incomplete FMU cleanup is a hard release failure")
    LS_TestAssert(RecordingSessionManager.LastReleaseMetadata["fmuCleanupAttempted"]
        && !RecordingSessionManager.LastReleaseMetadata["fmuCleanupCompleted"],
        "release records FMU cleanup failure")
    AssertCallSequence([
        "query-sessions",
        "logoff-remote",
        "fmu-cleanup"
    ], "release-session does not reboot after FMU cleanup fails")
    LS_TestAssert(RecordingSessionManager.LastReleaseMetadata["rebootDeferred"],
        "release defers a requested reboot after FMU cleanup fails")
    LS_TestAssert(!RecordingSessionManager.LastReleaseMetadata["retryable"],
        "a partial FMU cleanup failure requires reconciliation instead of automatic retry")
}

TestReleaseSessionInventoryFailureIsRetryable() {
    RecordingSessionManager.Reset()
    RecordingSessionManager.releaseInventoryError := true

    success := RecordingSessionManager.ReleaseSession(Map("user", "LABUSER"))

    LS_TestAssert(!success && RecordingSessionManager.LastReleaseExitCode = 2,
        "unavailable session inventory fails Release")
    LS_TestAssert(RecordingSessionManager.LastReleaseMetadata["retryable"],
        "a known session inventory failure before cleanup is retryable")
    AssertCallSequence(["query-sessions"], "Release does not start session or FMU cleanup when inventory is unavailable")
}

TestReleaseSessionFailureStillRecordsFailure() {
    RecordingSessionManager.Reset()
    RecordingSessionManager.logoffResult := false

    success := RecordingSessionManager.ReleaseSession(Map(
        "user", "LABUSER",
        "reboot", true,
        "rebootTimeout", 20
    ))

    LS_TestAssert(!success, "release-session reports failure when logoff fails")
    LS_TestAssert(RecordingSessionManager.LastReleaseExitCode = 2, "failed remote-session release is a hard failure")
    LS_TestAssert(!RecordingSessionManager.LastReleaseMetadata["retryable"],
        "an attempted remote-session logoff failure requires reconciliation")
    AssertCallSequence([
        "query-sessions",
        "logoff-remote"
    ], "release-session never reboots after remote logoff fails")

    state := LS_ServiceState.ReadSection("release-session")
    LS_TestAssert(state.Has("success") && !state["success"], "release-session records failure")
}

TestExtraCleaner(*) {
    RecordingSessionManager.calls.Push(Map("name", "extra-cleaner"))
    return true
}

AssertCallSequence(expectedNames, description) {
    actualNames := []
    for call in RecordingSessionManager.calls
        actualNames.Push(call["name"])

    if (actualNames.Length != expectedNames.Length) {
        LS_TestFail(description . " expected " . expectedNames.Length . " calls but got " . actualNames.Length)
        return
    }

    for index, expectedName in expectedNames {
        if (actualNames[index] != expectedName) {
            LS_TestFail(description . " mismatch at position " . index . " (expected " . expectedName . ", got " . actualNames[index] . ")")
        }
    }
}
