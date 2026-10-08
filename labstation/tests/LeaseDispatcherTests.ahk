#Requires AutoHotkey v2.0
#Include TestSupport.ahk
#Include ..\service\SessionGuard.ahk
#Include ..\service\FmuExecutor.ahk
#Include ..\service\SessionManager.ahk
#Include ..\service\LeaseDispatcher.ahk

global TEST_FAILURES := 0
global TEST_ROOT := A_Temp "\LabStation-LeaseDispatcherTests-" A_TickCount
global ORIGINAL_LEASE_STATE_FILE := LAB_STATION_LEASE_STATE_FILE
global LEASE_EXECUTOR_CALLS := []
global LEASE_EXECUTOR_RESULT := true

DirCreate(TEST_ROOT)
LAB_STATION_LEASE_STATE_FILE := TEST_ROOT "\lease-state.json"

try {
    TestLeasePreparePersistsAndReplaysIdempotently()
    TestLeaseOperationIdConflictFailsClosed()
    TestLeaseReleaseChecksGenerationAndReplays()
    TestLeaseFailedPrepareRequiresRecovery()
    TestLeaseRejectsExpiredRequestBeforeRunningSessionWork()
    TestLeaseCorruptJournalFailsClosed()
} catch as err {
    LS_TestFail("Unhandled lease-dispatch test exception: " . err.Message)
}

LAB_STATION_LEASE_STATE_FILE := ORIGINAL_LEASE_STATE_FILE
try DirDelete(TEST_ROOT, true)

if (TEST_FAILURES > 0) {
    LS_TestOutput("LeaseDispatcherTests failed: " . TEST_FAILURES . " failure(s)`n")
    ExitApp(1)
}
LS_TestOutput("LeaseDispatcherTests passed`n")
ExitApp(0)

TestLeasePreparePersistsAndReplaysIdempotently() {
    global LEASE_EXECUTOR_CALLS
    ResetLeaseTestState()
    request := LeaseRequest("prepare-session", "prepare-once", 0)

    first := LS_LeaseDispatcher.Execute(request, LeaseTestExecutor)
    second := LS_LeaseDispatcher.Execute(request, LeaseTestExecutor)

    if (first["exitCode"] != 0)
        LS_TestFail("prepare response: " . LS_ToJson(first))
    LS_TestAssert(first["exitCode"] = 0, "prepare lease succeeds")
    if (first["metadata"].Has("lease")) {
        LS_TestAssert(first["metadata"]["lease"]["generation"] = 1, "prepare lease persists generation 1")
        LS_TestAssert(first["metadata"]["lease"]["state"] = "active", "successful prepare marks lease active")
    }
    LS_TestAssert(second["id"] = first["id"], "duplicate prepare returns the recorded operation")
    LS_TestAssert(LEASE_EXECUTOR_CALLS.Length = 1, "duplicate prepare does not repeat session side effects")
    LS_TestAssert(FileExist(LAB_STATION_LEASE_STATE_FILE), "lease state is durably written")
}

TestLeaseOperationIdConflictFailsClosed() {
    ResetLeaseTestState()
    request := LeaseRequest("prepare-session", "reused-operation", 0)
    LS_LeaseDispatcher.Execute(request, LeaseTestExecutor)
    request["args"] := ["--guard-grace=10"]

    result := LS_LeaseDispatcher.Execute(request, LeaseTestExecutor)

    LS_TestAssert(result["exitCode"] = 2, "reusing an operation id with a different payload fails")
    LS_TestAssert(result["metadata"]["code"] = "STATION_OPERATION_ID_CONFLICT", "operation conflict has a stable error code")
    LS_TestAssert(LEASE_EXECUTOR_CALLS.Length = 1, "conflicting operation does not run session side effects")
}

TestLeaseReleaseChecksGenerationAndReplays() {
    global LEASE_EXECUTOR_CALLS
    ResetLeaseTestState()
    prepare := LeaseRequest("prepare-session", "prepare-release", 0)
    LS_LeaseDispatcher.Execute(prepare, LeaseTestExecutor)
    stale := LeaseRequest("release-session", "release-stale", 2)
    staleResult := LS_LeaseDispatcher.Execute(stale, LeaseTestExecutor)
    LS_TestAssert(staleResult["exitCode"] = 2, "release rejects a stale generation")
    LS_TestAssert(staleResult["metadata"]["code"] = "STATION_LEASE_STALE", "stale release has a stable error code")

    release := LeaseRequest("release-session", "release-once", 1)
    first := LS_LeaseDispatcher.Execute(release, LeaseTestExecutor)
    duplicate := LS_LeaseDispatcher.Execute(release, LeaseTestExecutor)
    secondOperation := LeaseRequest("release-session", "release-retry", 1)
    alreadyReleased := LS_LeaseDispatcher.Execute(secondOperation, LeaseTestExecutor)

    LS_TestAssert(first["exitCode"] = 0 && first["metadata"]["lease"]["state"] = "released", "matching release clears active lease")
    LS_TestAssert(duplicate["id"] = first["id"], "same release operation replays its durable result")
    LS_TestAssert(alreadyReleased["exitCode"] = 0, "release retry remains idempotent after a lost response")
    LS_TestAssert(LEASE_EXECUTOR_CALLS.Length = 2, "release retries do not repeat session side effects")
}

TestLeaseFailedPrepareRequiresRecovery() {
    global LEASE_EXECUTOR_RESULT
    ResetLeaseTestState()
    LEASE_EXECUTOR_RESULT := false
    failed := LS_LeaseDispatcher.Execute(LeaseRequest("prepare-session", "prepare-fails", 0), LeaseTestExecutor)
    conflict := LS_LeaseDispatcher.Execute(LeaseRequest("prepare-session", "prepare-again", 0), LeaseTestExecutor)

    LS_TestAssert(failed["exitCode"] = 1, "session preparation warning remains a warning result")
    LS_TestAssert(failed["metadata"]["lease"]["state"] = "recovery-required", "failed prepare leaves an explicit recovery state")
    LS_TestAssert(conflict["exitCode"] = 2, "recovery-required lease prevents another prepare")
    LEASE_EXECUTOR_RESULT := true
    release := LS_LeaseDispatcher.Execute(LeaseRequest("release-session", "release-recovery", 1), LeaseTestExecutor)
    LS_TestAssert(release["exitCode"] = 0, "matching release can reconcile a recovery-required lease")
}

TestLeaseRejectsExpiredRequestBeforeRunningSessionWork() {
    global LEASE_EXECUTOR_CALLS
    ResetLeaseTestState()
    request := LeaseRequest("prepare-session", "expired-request", 0, true)

    result := LS_LeaseDispatcher.Execute(request, LeaseTestExecutor)

    LS_TestAssert(result["exitCode"] = 2, "expired dispatcher window is rejected")
    LS_TestAssert(result["metadata"]["code"] = "STATION_DISPATCHER_DEADLINE_EXPIRED", "expired request has stable error code")
    LS_TestAssert(LEASE_EXECUTOR_CALLS.Length = 0, "expired request never runs session work")
}

TestLeaseCorruptJournalFailsClosed() {
    global LEASE_EXECUTOR_CALLS
    ResetLeaseTestState()
    FileAppend("{not-json", LAB_STATION_LEASE_STATE_FILE, "UTF-8")

    result := LS_LeaseDispatcher.Execute(LeaseRequest("prepare-session", "bad-journal", 0), LeaseTestExecutor)

    LS_TestAssert(result["exitCode"] = 2, "corrupt lease journal rejects operations")
    LS_TestAssert(result["metadata"]["code"] = "STATION_JOURNAL_UNAVAILABLE", "corrupt journal has stable error code")
    LS_TestAssert(LEASE_EXECUTOR_CALLS.Length = 0, "corrupt journal never runs session work")
}

ResetLeaseTestState() {
    global LEASE_EXECUTOR_CALLS, LEASE_EXECUTOR_RESULT
    LEASE_EXECUTOR_CALLS := []
    LEASE_EXECUTOR_RESULT := true
    try FileDelete(LAB_STATION_LEASE_STATE_FILE)
}

LeaseRequest(command, operationId, generation, expired := false) {
    now := A_NowUTC
    issue := expired ? DateAdd(now, -600, "Seconds") : DateAdd(now, -2, "Seconds")
    deadline := expired ? DateAdd(now, -300, "Seconds") : DateAdd(now, 240, "Seconds")
    leaseExpiry := DateAdd(now, 1800, "Seconds")
    return Map(
        "schemaVersion", 2,
        "id", operationId,
        "operation", "execute",
        "command", command,
        "args", command = "prepare-session" ? ["--no-guard"] : [],
        "issuedAt", FormatTime(issue, "yyyy-MM-ddTHH:mm:ssZ"),
        "executeBefore", FormatTime(deadline, "yyyy-MM-ddTHH:mm:ssZ"),
        "context", Map(
            "kind", "reservation",
            "labId", "lab-1",
            "reservationKey", "reservation-1",
            "leaseId", "lease-1",
            "generation", generation,
            "notBefore", FormatTime(DateAdd(now, -120, "Seconds"), "yyyy-MM-ddTHH:mm:ssZ"),
            "expiresAt", FormatTime(leaseExpiry, "yyyy-MM-ddTHH:mm:ssZ")
        )
    )
}

LeaseTestExecutor(command, args) {
    global LEASE_EXECUTOR_CALLS, LEASE_EXECUTOR_RESULT
    LEASE_EXECUTOR_CALLS.Push(Map("command", command, "args", args))
    return LEASE_EXECUTOR_RESULT
}
