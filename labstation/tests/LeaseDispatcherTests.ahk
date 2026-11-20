#Requires AutoHotkey v2.0
#Include TestSupport.ahk
#Include ..\service\SessionGuard.ahk
#Include ..\service\FmuExecutor.ahk
#Include ..\service\SessionManager.ahk
#Include ..\service\LeaseDispatcher.ahk
#Include ParityTestSupport.ahk

global TEST_FAILURES := 0
global TEST_ROOT := A_Temp "\LabStation-LeaseDispatcherTests-" A_TickCount
global ORIGINAL_LEASE_STATE_FILE := LAB_STATION_LEASE_STATE_FILE
global LEASE_EXECUTOR_CALLS := []
global LEASE_EXECUTOR_RESULT := true
global LEASE_EXECUTOR_RETRYABLE := false
global LEASE_EXECUTOR_RELEASE_RETRYABLE := false
global LEASE_EXECUTOR_RELEASE_EXIT_CODE := 0

DirCreate(TEST_ROOT)
LAB_STATION_LEASE_STATE_FILE := TEST_ROOT "\lease-state.json"

try {
    TestLeasePreparePersistsAndReplaysIdempotently()
    TestLeaseOperationIdConflictFailsClosed()
    TestLeaseReleaseChecksGenerationAndReplays()
    TestLeaseReleaseWarningCompletesOnlyAfterTheLeaseIsReleased()
    TestAdministrativeSessionActionsRefuseActiveLease()
    TestLeaseFailedPrepareRequiresRecovery()
    TestRetryablePrepareRefusalDoesNotCacheOperationOrLease()
    TestLeaseRejectsExpiredRequestBeforeRunningSessionWork()
    TestLeaseCorruptJournalFailsClosed()
    TestLeaseExpiryWatchdogReleasesExpiredLease()
    TestLeaseExpiryRetriesKnownPreEffectFailures()
    TestLeaseExpiryDoesNotRetryPartialCleanupFailure()
    TestLeaseExpiryDoesNotReplayInterruptedCleanup()
    TestLeaseExpiryRequiresReconciliationForUnclassifiedRecoveryState()
    TestLeaseExpiryRetriesRecordedPreEffectReleaseFailure()
    TestLeaseExpiryRetryPreservesDisconnectGuardUntilReservationEnd()
    TestOperationStatusReturnsPersistedResult()
} catch as err {
    LS_TestFail("Unhandled lease-dispatch test exception: " . err.Message)
}

TestAdministrativeSessionActionsRefuseActiveLease() {
    global LEASE_EXECUTOR_CALLS
    ResetLeaseTestState()
    now := A_NowUTC
    active := Map(
        "kind", "reservation",
        "leaseId", "operator-conflict",
        "generation", 3,
        "state", "active",
        "notBefore", FormatTime(DateAdd(now, -60, "Seconds"), "yyyy-MM-ddTHH:mm:ssZ"),
        "expiresAt", FormatTime(DateAdd(now, 600, "Seconds"), "yyyy-MM-ddTHH:mm:ssZ"),
        "updatedAt", FormatTime(now, "yyyy-MM-ddTHH:mm:ssZ")
    )
    LS_LeaseDispatcher.SaveState(Map("nextGeneration", 3, "active", active, "operations", Map()))

    prepared := LS_LeaseDispatcher.ExecuteAdministrativePrepare(Map())
    released := LS_LeaseDispatcher.ExecuteAdministrativeRelease(Map())

    LS_TestAssert(prepared["exitCode"] = 2 && prepared["metadata"]["code"] = "STATION_LEASE_CONFLICT",
        "administrative Prepare refuses to bypass an active lease")
    LS_TestAssert(released["exitCode"] = 2 && released["metadata"]["code"] = "STATION_LEASE_CONFLICT",
        "administrative Release refuses to bypass an active lease")
    state := LS_LeaseDispatcher.LoadState()
    LS_TestAssert(state["active"]["leaseId"] = active["leaseId"] && state["active"]["state"] = "active",
        "administrative refusal preserves the reservation lease")
    LS_TestAssert(LEASE_EXECUTOR_CALLS.Length = 0,
        "administrative refusals make no session changes")
}

TestLeaseReleaseWarningCompletesOnlyAfterTheLeaseIsReleased() {
    global LEASE_EXECUTOR_RELEASE_EXIT_CODE
    ResetLeaseTestState()
    prepared := LS_LeaseDispatcher.Execute(LeaseRequest("prepare-session", "release-warning-prepare", 0), LeaseTestExecutor)
    LS_TestAssert(prepared["exitCode"] = 0, "warning-release fixture creates an active reservation lease")
    LEASE_EXECUTOR_RELEASE_EXIT_CODE := 1
    released := LS_LeaseDispatcher.Execute(LeaseRequest("release-session", "release-warning", 1), LeaseTestExecutor)
    LS_TestAssert(released["exitCode"] = 1 && released["outcome"] = "warning", "nonfatal release warnings keep exit code 1")
    LS_TestAssert(released["metadata"]["lease"]["state"] = "released", "a release warning is successful only after the lease is released")
    LS_TestAssert(released["metadata"]["rebootDeferred"], "Release warning metadata reports the deferred reboot")
    LS_TestAssert(!LS_LeaseDispatcher.LoadState().Has("active"), "a completed warning release clears the lease")
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

    LS_TestAssert(failed["exitCode"] = 2, "incomplete session preparation is a failure, not a successful warning")
    LS_TestAssert(failed["metadata"]["lease"]["state"] = "recovery-required", "failed prepare leaves an explicit recovery state")
    LS_TestAssert(conflict["exitCode"] = 2, "recovery-required lease prevents another prepare")
    LEASE_EXECUTOR_RESULT := true
    release := LS_LeaseDispatcher.Execute(LeaseRequest("release-session", "release-recovery", 1), LeaseTestExecutor)
    LS_TestAssert(release["exitCode"] = 0, "matching release can reconcile a recovery-required lease")
}

TestRetryablePrepareRefusalDoesNotCacheOperationOrLease() {
    global LEASE_EXECUTOR_RESULT, LEASE_EXECUTOR_RETRYABLE
    ResetLeaseTestState()
    LEASE_EXECUTOR_RESULT := false
    LEASE_EXECUTOR_RETRYABLE := true
    request := LeaseRequest("prepare-session", "retryable-refusal", 0)

    refused := LS_LeaseDispatcher.Execute(request, LeaseTestExecutor)
    state := LS_LeaseDispatcher.LoadState()
    LS_TestAssert(refused["exitCode"] = 2 && refused["metadata"]["retryable"], "known precondition refusal is returned to the caller")
    LS_TestAssert(!state.Has("active"), "known precondition refusal rolls back the preparing lease")
    LS_TestAssert(!state["operations"].Has(request["id"]), "known precondition refusal is not cached under the operation id")

    LEASE_EXECUTOR_RESULT := true
    LEASE_EXECUTOR_RETRYABLE := false
    retried := LS_LeaseDispatcher.Execute(request, LeaseTestExecutor)
    LS_TestAssert(retried["exitCode"] = 0 && retried["metadata"]["lease"]["state"] = "active",
        "the same operation id can be retried after the refusal condition is cleared")
    LS_TestAssert(LEASE_EXECUTOR_CALLS.Length = 2, "the retry executes after the refusal without reusing a cached failure")
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

TestLeaseExpiryWatchdogReleasesExpiredLease() {
    global LEASE_EXECUTOR_CALLS
    ResetLeaseTestState()
    matrix := LS_TestLoadParityMatrix()
    policy := matrix["leaseExpiry"]
    now := A_NowUTC
    active := Map(
        "kind", "reservation",
        "leaseId", "lease-watchdog",
        "generation", 7,
        "state", "active",
        "notBefore", FormatTime(DateAdd(now, -120, "Seconds"), "yyyy-MM-ddTHH:mm:ssZ"),
        "expiresAt", FormatTime(DateAdd(now, 120, "Seconds"), "yyyy-MM-ddTHH:mm:ssZ"),
        "updatedAt", FormatTime(now, "yyyy-MM-ddTHH:mm:ssZ"),
        "labId", "lab-1",
        "reservationKey", "reservation-7"
    )
    LS_LeaseDispatcher.SaveState(Map("nextGeneration", 7, "active", active, "operations", Map()))

    LS_LeaseDispatcher.EnforceLeaseExpiry(LeaseTestExecutor, LeaseAllowExpiryRelease)
    LS_TestAssert(policy["unexpiredLease"] = "retain", "shared policy retains a lease before expiry")
    LS_TestAssert(LEASE_EXECUTOR_CALLS.Length = 0, "watchdog leaves an unexpired lease untouched")

    active["expiresAt"] := FormatTime(DateAdd(now, -120, "Seconds"), "yyyy-MM-ddTHH:mm:ssZ")
    active["notBefore"] := FormatTime(DateAdd(now, -3600, "Seconds"), "yyyy-MM-ddTHH:mm:ssZ")
    LS_LeaseDispatcher.SaveState(Map("nextGeneration", 7, "active", active, "operations", Map()))
    LS_LeaseDispatcher.EnforceLeaseExpiry(LeaseTestExecutor, LeaseAllowExpiryRelease)
    LS_LeaseDispatcher.EnforceLeaseExpiry(LeaseTestExecutor, LeaseAllowExpiryRelease)

    state := LS_LeaseDispatcher.LoadState()
    LS_TestAssert(policy["expiredLease"] = "release", "shared policy releases an expired lease")
    LS_TestAssert(LEASE_EXECUTOR_CALLS.Length = 1, "watchdog runs release-session only once for the expired lease")
    LS_TestAssert(LEASE_EXECUTOR_CALLS[1]["command"] = "release-session", "expiry cleanup uses the shared release-session operation")
    LS_TestAssert(!state.Has("active"), "successful expiry cleanup clears the active lease")
    LS_TestAssert(state["operations"].Has("lease-expiry-7"), "expiry cleanup persists an operation result")
    LS_TestAssert(state["operations"]["lease-expiry-7"]["state"] = "completed", "expiry cleanup is durably completed")
}

TestLeaseExpiryRetriesKnownPreEffectFailures() {
    global LEASE_EXECUTOR_CALLS, LEASE_EXECUTOR_RESULT, LEASE_EXECUTOR_RELEASE_RETRYABLE
    ResetLeaseTestState()
    matrix := LS_TestLoadParityMatrix()
    now := A_NowUTC
    active := ExpiredLease("lease-watchdog-retry", 8, now)
    LS_LeaseDispatcher.SaveState(Map("nextGeneration", 8, "active", active, "operations", Map()))

    LEASE_EXECUTOR_RESULT := false
    LEASE_EXECUTOR_RELEASE_RETRYABLE := true
    LS_LeaseDispatcher.EnforceLeaseExpiry(LeaseTestExecutor, LeaseAllowExpiryRelease)
    state := LS_LeaseDispatcher.LoadState()
    first := state["operations"]["lease-expiry-8"]["result"]
    LS_TestAssert(matrix["leaseExpiry"]["knownPreEffectFailure"] = "retry", "shared policy retries known pre-effect failures")
    LS_TestAssert(first["metadata"]["retryable"] && state["active"]["state"] = "recovery-required",
        "a known pre-effect failure is recorded while the expired lease remains locked")

    AgeLeaseRecoveryRetry()
    LEASE_EXECUTOR_RESULT := true
    LEASE_EXECUTOR_RELEASE_RETRYABLE := false
    LS_LeaseDispatcher.EnforceLeaseExpiry(LeaseTestExecutor, LeaseAllowExpiryRelease)
    state := LS_LeaseDispatcher.LoadState()
    LS_TestAssert(LEASE_EXECUTOR_CALLS.Length = 2, "watchdog retries a known safe failure")
    LS_TestAssert(state["operations"].Has("lease-expiry-8-retry-2"), "retry attempt is durably recorded")
    LS_TestAssert(!state.Has("active"), "successful retry clears the expired lease")
}

TestLeaseExpiryDoesNotRetryPartialCleanupFailure() {
    global LEASE_EXECUTOR_CALLS, LEASE_EXECUTOR_RESULT, LEASE_EXECUTOR_RELEASE_RETRYABLE
    ResetLeaseTestState()
    matrix := LS_TestLoadParityMatrix()
    now := A_NowUTC
    active := ExpiredLease("lease-watchdog-partial", 9, now)
    LS_LeaseDispatcher.SaveState(Map("nextGeneration", 9, "active", active, "operations", Map()))

    LEASE_EXECUTOR_RESULT := false
    LEASE_EXECUTOR_RELEASE_RETRYABLE := false
    LS_LeaseDispatcher.EnforceLeaseExpiry(LeaseTestExecutor, LeaseAllowExpiryRelease)
    LS_LeaseDispatcher.EnforceLeaseExpiry(LeaseTestExecutor, LeaseAllowExpiryRelease)
    state := LS_LeaseDispatcher.LoadState()
    LS_TestAssert(matrix["leaseExpiry"]["partialOrUnknownFailure"] = "recovery-required",
        "shared policy requires reconciliation after partial cleanup")
    LS_TestAssert(LEASE_EXECUTOR_CALLS.Length = 1, "partial cleanup is not repeated automatically")
    LS_TestAssert(state.Has("active") && state["active"]["state"] = "recovery-required",
        "partial cleanup keeps station admission blocked")
}

TestLeaseExpiryDoesNotReplayInterruptedCleanup() {
    global LEASE_EXECUTOR_CALLS
    ResetLeaseTestState()
    now := A_NowUTC
    active := ExpiredLease("lease-watchdog-unknown", 10, now)
    operation := Map(
        "payload", "interrupted",
        "state", "processing",
        "command", "release-session",
        "leaseId", active["leaseId"],
        "generation", 10,
        "updatedAt", FormatTime(now, "yyyy-MM-ddTHH:mm:ssZ")
    )
    operations := Map("lease-expiry-10", operation)
    LS_LeaseDispatcher.SaveState(Map("nextGeneration", 10, "active", active, "operations", operations))

    LS_LeaseDispatcher.EnforceLeaseExpiry(LeaseTestExecutor, LeaseAllowExpiryRelease)
    state := LS_LeaseDispatcher.LoadState()
    LS_TestAssert(LEASE_EXECUTOR_CALLS.Length = 0, "an interrupted expiry operation is not replayed")
    LS_TestAssert(state["operations"]["lease-expiry-10"]["state"] = "recovery-required",
        "interrupted expiry operation is marked for reconciliation")
    LS_TestAssert(state["active"]["state"] = "recovery-required", "uncertain expiry outcome keeps station admission blocked")
}

TestLeaseExpiryRequiresReconciliationForUnclassifiedRecoveryState() {
    global LEASE_EXECUTOR_CALLS
    ResetLeaseTestState()
    now := A_NowUTC
    active := ExpiredLease("lease-watchdog-unclassified", 11, now)
    active["state"] := "recovery-required"
    LS_LeaseDispatcher.SaveState(Map("nextGeneration", 11, "active", active, "operations", Map()))

    LS_LeaseDispatcher.EnforceLeaseExpiry(LeaseTestExecutor, LeaseAllowExpiryRelease)
    LS_LeaseDispatcher.EnforceLeaseExpiry(LeaseTestExecutor, LeaseAllowExpiryRelease)
    state := LS_LeaseDispatcher.LoadState()
    LS_TestAssert(LEASE_EXECUTOR_CALLS.Length = 0, "a recovery lease without a recorded retryable Release is not retried")
    LS_TestAssert(state["operations"].Has("lease-expiry-recovery-11")
        && state["operations"]["lease-expiry-recovery-11"]["state"] = "recovery-required",
        "an unclassified recovery lease records why operator reconciliation is required")
}

TestLeaseExpiryRetriesRecordedPreEffectReleaseFailure() {
    global LEASE_EXECUTOR_CALLS
    ResetLeaseTestState()
    now := A_NowUTC
    active := ExpiredLease("lease-watchdog-recorded-retry", 12, now)
    active["state"] := "recovery-required"
    active["updatedAt"] := FormatTime(DateAdd(now, -180, "Seconds"), "yyyy-MM-ddTHH:mm:ssZ")
    failedResult := Map("exitCode", 2, "metadata", Map("code", "STATION_SESSION_QUERY_FAILED", "retryable", true))
    priorRelease := Map(
        "state", "completed",
        "command", "release-session",
        "leaseId", active["leaseId"],
        "generation", 12,
        "updatedAt", FormatTime(DateAdd(now, -120, "Seconds"), "yyyy-MM-ddTHH:mm:ssZ"),
        "result", failedResult
    )
    operations := Map("gateway-release-12", priorRelease)
    LS_LeaseDispatcher.SaveState(Map("nextGeneration", 12, "active", active, "operations", operations))

    LS_LeaseDispatcher.EnforceLeaseExpiry(LeaseTestExecutor, LeaseAllowExpiryRelease)
    state := LS_LeaseDispatcher.LoadState()
    LS_TestAssert(LEASE_EXECUTOR_CALLS.Length = 1, "a recorded pre-effect release failure may be retried by expiry cleanup")
    LS_TestAssert(state["operations"].Has("lease-expiry-12"), "expiry cleanup persists a new release operation")
    LS_TestAssert(!state.Has("active"), "successful retry clears the expired lease")
}

TestLeaseExpiryRetryPreservesDisconnectGuardUntilReservationEnd() {
    global LEASE_EXECUTOR_CALLS
    ResetLeaseTestState()
    now := A_NowUTC
    active := ExpiredLease("lease-watchdog-disconnect-guard", 13, now)
    active["state"] := "recovery-required"
    active["expiresAt"] := FormatTime(DateAdd(now, 300, "Seconds"), "yyyy-MM-ddTHH:mm:ssZ")
    active["nextReconcileAt"] := FormatTime(DateAdd(now, -120, "Seconds"), "yyyy-MM-ddTHH:mm:ssZ")
    active["updatedAt"] := FormatTime(DateAdd(now, -180, "Seconds"), "yyyy-MM-ddTHH:mm:ssZ")
    priorRequest := Map("command", "release-session", "args", ["--require-rdp-disconnected"])
    failedResult := Map("exitCode", 2, "metadata", Map("code", "STATION_RDP_CLIENT_CONNECTED", "retryable", true))
    priorRelease := Map(
        "payload", LS_ToJson(priorRequest),
        "state", "completed",
        "command", "release-session",
        "leaseId", active["leaseId"],
        "generation", 13,
        "updatedAt", FormatTime(DateAdd(now, -120, "Seconds"), "yyyy-MM-ddTHH:mm:ssZ"),
        "result", failedResult
    )
    LS_LeaseDispatcher.SaveState(Map(
        "nextGeneration", 13,
        "active", active,
        "operations", Map("gateway-release-13", priorRelease)
    ))

    LS_LeaseDispatcher.EnforceLeaseExpiry(LeaseTestExecutor, LeaseAllowExpiryRelease)
    LS_TestAssert(LEASE_EXECUTOR_CALLS.Length = 1, "watchdog retries a guarded early release")
    args := LEASE_EXECUTOR_CALLS.Length > 0 ? LEASE_EXECUTOR_CALLS[1]["args"] : []
    hasGuard := false
    for arg in args {
        if (arg = "--require-rdp-disconnected")
            hasGuard := true
    }
    LS_TestAssert(hasGuard, "early watchdog retry keeps the reconnect guard")

    ResetLeaseTestState()
    now := A_NowUTC
    active := ExpiredLease("lease-watchdog-disconnect-guard-end", 14, now)
    active["state"] := "recovery-required"
    active["updatedAt"] := FormatTime(DateAdd(now, -180, "Seconds"), "yyyy-MM-ddTHH:mm:ssZ")
    priorRequest := Map("command", "release-session", "args", ["--require-rdp-disconnected"])
    failedResult := Map("exitCode", 2, "metadata", Map("code", "STATION_RDP_CLIENT_CONNECTED", "retryable", true))
    priorRelease := Map(
        "payload", LS_ToJson(priorRequest),
        "state", "completed",
        "command", "release-session",
        "leaseId", active["leaseId"],
        "generation", 14,
        "updatedAt", FormatTime(DateAdd(now, -120, "Seconds"), "yyyy-MM-ddTHH:mm:ssZ"),
        "result", failedResult
    )
    LS_LeaseDispatcher.SaveState(Map(
        "nextGeneration", 14,
        "active", active,
        "operations", Map("gateway-release-14", priorRelease)
    ))

    LS_LeaseDispatcher.EnforceLeaseExpiry(LeaseTestExecutor, LeaseAllowExpiryRelease)
    LS_TestAssert(LEASE_EXECUTOR_CALLS.Length = 1, "watchdog retries the release when scheduled expiry arrives")
    args := LEASE_EXECUTOR_CALLS.Length > 0 ? LEASE_EXECUTOR_CALLS[1]["args"] : []
    hasGuard := false
    for arg in args {
        if (arg = "--require-rdp-disconnected")
            hasGuard := true
    }
    LS_TestAssert(!hasGuard,
        "scheduled expiry owns final release and does not preserve the early-disconnect guard")
}

ExpiredLease(leaseId, generation, now) {
    return Map(
        "kind", "reservation",
        "leaseId", leaseId,
        "generation", generation,
        "state", "active",
        "notBefore", FormatTime(DateAdd(now, -3600, "Seconds"), "yyyy-MM-ddTHH:mm:ssZ"),
        "expiresAt", FormatTime(DateAdd(now, -120, "Seconds"), "yyyy-MM-ddTHH:mm:ssZ"),
        "updatedAt", FormatTime(now, "yyyy-MM-ddTHH:mm:ssZ"),
        "labId", "lab-1",
        "reservationKey", "reservation-" . generation
    )
}

TestOperationStatusReturnsPersistedResult() {
    global LEASE_EXECUTOR_CALLS
    ResetLeaseTestState()
    matrix := LS_TestLoadParityMatrix()
    policy := matrix["operationStatus"]
    request := LeaseRequest("prepare-session", "status-prepare", 0)
    prepared := LS_LeaseDispatcher.Execute(request, LeaseTestExecutor)
    query := Map("schemaVersion", 2, "id", "status-query", "operation", "operation.status", "operationId", request["id"])
    status := LS_LeaseDispatcher.Execute(query)
    operation := LS_ParseJson(status["stdout"])

    LS_TestAssert(prepared["exitCode"] = 0, "operation.status fixture prepare completes successfully")
    LS_TestAssert(policy["persistedOperation"] = "return-record", "shared policy returns the persisted operation record")
    LS_TestAssert(operation["operationId"] = request["id"] && operation["state"] = "completed",
        "Windows operation.status returns the completed operation record")
    LS_TestAssert(operation["result"]["exitCode"] = 0, "operation.status returns the durable command result")
    LS_TestAssert(LEASE_EXECUTOR_CALLS.Length = 1, "status lookup does not repeat the operation")

    missing := LS_LeaseDispatcher.Execute(Map(
        "schemaVersion", 2,
        "id", "status-missing",
        "operation", "operation.status",
        "operationId", "missing-operation"
    ))
    missingRecord := LS_ParseJson(missing["stdout"])
    LS_TestAssert(policy["missingOperation"] = "not-found", "shared policy reports absent operation ids as not found")
    LS_TestAssert(missing["exitCode"] = 1 && missingRecord["state"] = "not-found",
        "Windows operation.status distinguishes an absent operation from a transport failure")
    LS_TestAssert(LEASE_EXECUTOR_CALLS.Length = 1, "missing status lookup causes no session side effect")
}

ResetLeaseTestState() {
    global LEASE_EXECUTOR_CALLS, LEASE_EXECUTOR_RESULT, LEASE_EXECUTOR_RETRYABLE
    global LEASE_EXECUTOR_RELEASE_RETRYABLE
    global LEASE_EXECUTOR_RELEASE_EXIT_CODE
    LEASE_EXECUTOR_CALLS := []
    LEASE_EXECUTOR_RESULT := true
    LEASE_EXECUTOR_RETRYABLE := false
    LEASE_EXECUTOR_RELEASE_RETRYABLE := false
    LEASE_EXECUTOR_RELEASE_EXIT_CODE := 0
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
    global LEASE_EXECUTOR_CALLS, LEASE_EXECUTOR_RESULT, LEASE_EXECUTOR_RETRYABLE
    global LEASE_EXECUTOR_RELEASE_RETRYABLE
    global LEASE_EXECUTOR_RELEASE_EXIT_CODE
    LEASE_EXECUTOR_CALLS.Push(Map("command", command, "args", args))
    if (command = "prepare-session") {
        LS_SessionManager.LastPrepareExitCode := 0
        LS_SessionManager.LastPrepareRetryable := LEASE_EXECUTOR_RETRYABLE
    } else {
        LS_SessionManager.LastReleaseExitCode := LEASE_EXECUTOR_RELEASE_EXIT_CODE
        LS_SessionManager.LastReleaseRetryable := LEASE_EXECUTOR_RELEASE_RETRYABLE
        LS_SessionManager.LastReleaseMetadata := Map("retryable", LEASE_EXECUTOR_RELEASE_RETRYABLE)
        if (LEASE_EXECUTOR_RELEASE_EXIT_CODE = 1) {
            LS_SessionManager.LastReleaseMessage := "station released with warnings"
            LS_SessionManager.LastReleaseMetadata := Map("rebootRequested", true, "rebootScheduled", false,
                "rebootDeferred", true, "rebootReason", "physical console session remains active", "rebootTimeout", 0)
        }
    }
    return LEASE_EXECUTOR_RESULT
}

LeaseAllowExpiryRelease() {
    return ""
}

AgeLeaseRecoveryRetry() {
    state := LS_LeaseDispatcher.LoadState()
    retryDue := FormatTime(DateAdd(A_NowUTC, -120, "Seconds"), "yyyy-MM-ddTHH:mm:ssZ")
    active := state["active"]
    active["nextReconcileAt"] := retryDue
    active["updatedAt"] := retryDue
    state["active"] := active
    operations := state["operations"]
    for operationId, operation in operations {
        if (!operation.Has("leaseId") || operation["leaseId"] != active["leaseId"]
            || !operation.Has("generation") || operation["generation"] != active["generation"])
            continue
        operation["updatedAt"] := retryDue
        operations[operationId] := operation
    }
    state["operations"] := operations
    LS_LeaseDispatcher.SaveState(state)
}
