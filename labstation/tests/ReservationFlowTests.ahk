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
    static rebootResult := true

    static GetPrepareLocalSessions(managedUser) {
        return []
    }

    static Reset() {
        this.calls := []
        this.guardResult := true
        this.closeResult := true
        this.fmuResult := true
        this.clearResult := true
        this.resetResult := true
        this.logoffResult := true
        this.rebootResult := true
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

    static LogoffLabUser(user := "", force := true) {
        this.calls.Push(Map("name", "logoff", "user", user, "force", force))
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
        TestPrepareSessionFailsClosedWhenSessionInventoryUnavailable()
        TestPrepareLocalSessionPolicyMatchesSharedMatrix()
        TestPrepareCleanupClearsSharedEphemeralCategories()
        TestReleaseSessionWithoutReboot()
        TestReleaseSessionWithReboot()
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
    AssertCallSequence([
        "close-controller",
        "fmu-cleanup",
        "clear-profile",
        "reset-controller"
    ], "prepare-session continues cleanup after a failed operation")

    state := LS_ServiceState.ReadSection("prepare-session")
    LS_TestAssert(state.Has("success") && !state["success"], "prepare-session records failure")
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
        "close-controller",
        "fmu-cleanup",
        "logoff"
    ], "release-session does not reboot by default")

    state := LS_ServiceState.ReadSection("release-session")
    LS_TestAssert(state.Has("success") && state["success"], "release-session records success")
    LS_TestAssert(!state.Has("rebootRequested"), "release-session omits reboot metadata when not requested")
}

TestReleaseSessionWithReboot() {
    RecordingSessionManager.Reset()

    options := Map("user", "LABUSER", "reboot", true, "rebootTimeout", 15)
    success := RecordingSessionManager.ReleaseSession(options)

    LS_TestAssert(success, "release-session succeeds with reboot")
    AssertCallSequence([
        "close-controller",
        "fmu-cleanup",
        "logoff",
        "reboot"
    ], "release-session reboots after cleanup")
    LS_TestAssert(RecordingSessionManager.calls[4]["timeout"] = 15, "release-session forwards reboot timeout")

    state := LS_ServiceState.ReadSection("release-session")
    LS_TestAssert(state.Has("rebootRequested") && state["rebootRequested"], "release-session records reboot request")
    LS_TestAssert(state.Has("rebootTimeout") && state["rebootTimeout"] = 15, "release-session records reboot timeout")
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
    AssertCallSequence([
        "close-controller",
        "fmu-cleanup",
        "logoff",
        "reboot"
    ], "release-session attempts the requested reboot after a failed cleanup step")

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
