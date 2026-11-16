; Durable dispatcher v2 reservation lease lifecycle for the Windows station.
#Requires AutoHotkey v2.0
#Include ..\core\Config.ahk
#Include ..\core\Json.ahk
#Include ..\core\Logger.ahk
#Include SessionManager.ahk
#Include ..\diagnostics\Status.ahk
#Include Telemetry.ahk

class LS_LeaseDispatcher {
    static MutexName := "Global\DecentraLabs.LabStation.ReservationLease"
    static ReconciliationRetrySeconds := 60

    static ExecuteAdministrativeLocalMode(ttlSeconds := 28800) {
        request := Map("id", "operator-local-mode", "command", "local-mode")
        if (LS_Status.GetStationProfile() != "hybrid")
            return this.ErrorResult(request, "STATION_PROFILE_UNSUPPORTED", "local mode can only be enabled on a hybrid Station")
        if (ttlSeconds < 60 || ttlSeconds > 86400)
            return this.ErrorResult(request, "STATION_COMMAND_REJECTED", "local-mode TTL must be between 60 and 86400 seconds")

        mutex := DllCall("CreateMutexW", "Ptr", 0, "Int", 0, "WStr", this.MutexName, "Ptr")
        if (!mutex)
            return this.ErrorResult(request, "STATION_JOURNAL_UNAVAILABLE", "lease journal lock is unavailable")
        waitResult := DllCall("WaitForSingleObject", "Ptr", mutex, "UInt", 180000, "UInt")
        if (waitResult != 0 && waitResult != 0x80) {
            DllCall("CloseHandle", "Ptr", mutex)
            return this.ErrorResult(request, "STATION_OPERATION_IN_PROGRESS", "another lease operation is still running")
        }

        try {
            try {
                state := this.LoadState()
            } catch {
                return this.ErrorResult(request, "STATION_JOURNAL_UNAVAILABLE", "lease journal is invalid or unavailable")
            }
            if (state.Has("active"))
                return this.ErrorResult(request, "STATION_LEASE_CONFLICT", "an active reservation prevents enabling local mode")

            try {
                sessions := LS_Status.GetSessionInformation(LS_Status.GetIdentityInformation())
            } catch {
                return this.ErrorResult(request, "STATION_SESSION_QUERY_FAILED", "session inventory is unavailable")
            }
            if (!sessions["queryOk"])
                return this.ErrorResult(request, "STATION_SESSION_QUERY_FAILED", "session inventory is unavailable")
            if (sessions["labUserRemoteActive"])
                return this.ErrorResult(request, "STATION_REMOTE_SESSION_ACTIVE", "an active remote lab-user session prevents enabling local mode")

            temporary := LAB_STATION_LOCAL_MODE_FLAG . ".new"
            try {
                EnsureDir(LAB_STATION_DATA_DIR)
                if (FileExist(temporary))
                    FileDelete(temporary)
                setAt := A_NowUTC
                expiresAt := DateAdd(setAt, ttlSeconds, "Seconds")
                payload := Map(
                    "enabled", true,
                    "setAt", FormatTime(setAt, "yyyy-MM-ddTHH:mm:ssZ"),
                    "expiresAt", FormatTime(expiresAt, "yyyy-MM-ddTHH:mm:ssZ")
                )
                FileAppend(LS_ToJson(payload) . "`n", temporary, "UTF-8")
                FileMove(temporary, LAB_STATION_LOCAL_MODE_FLAG, 1)
            } catch as e {
                try FileDelete(temporary)
                LS_LogError("Unable to enable local mode: " . e.Message)
                return this.ErrorResult(request, "STATION_LOCAL_MODE_FAILED", "local mode could not be enabled")
            }
            LS_PublishTelemetryBestEffort("local-mode enabled")
            return this.Result(request, 0, "local mode enabled", Map("expiresAt", FormatTime(expiresAt, "yyyy-MM-ddTHH:mm:ssZ")), "local mode enabled", "")
        } finally {
            DllCall("ReleaseMutex", "Ptr", mutex)
            DllCall("CloseHandle", "Ptr", mutex)
        }
    }

    static ExecuteAdministrativePrepare(options) {
        request := Map("id", "operator-prepare", "command", "prepare-session")
        mutex := DllCall("CreateMutexW", "Ptr", 0, "Int", 0, "WStr", this.MutexName, "Ptr")
        if (!mutex)
            return this.ErrorResult(request, "STATION_JOURNAL_UNAVAILABLE", "lease journal lock is unavailable")
        waitResult := DllCall("WaitForSingleObject", "Ptr", mutex, "UInt", 180000, "UInt")
        if (waitResult != 0 && waitResult != 0x80) {
            DllCall("CloseHandle", "Ptr", mutex)
            return this.ErrorResult(request, "STATION_OPERATION_IN_PROGRESS", "another lease operation is still running")
        }

        try {
            try {
                state := this.LoadState()
            } catch {
                return this.ErrorResult(request, "STATION_JOURNAL_UNAVAILABLE", "lease journal is invalid or unavailable")
            }
            if (state.Has("active"))
                return this.ErrorResult(request, "STATION_LEASE_CONFLICT", "an active lease must be prepared by its reservation flow")

            started := A_TickCount
            successful := LS_SessionManager.PrepareSession(options, true)
            exitCode := LS_SessionManager.LastPrepareExitCode
            if (exitCode < 1 && !successful)
                exitCode := 2
            message := LS_SessionManager.LastPrepareMessage != "" ? LS_SessionManager.LastPrepareMessage
                : exitCode = 0 ? "station prepared"
                : exitCode = 1 ? "Prepare-session finished with warnings"
                : "Prepare-session failed or was refused"
            metadata := Map("administrative", true)
            this.MergeMetadata(metadata, LS_SessionManager.LastPrepareMetadata)
            result := this.Result(request, exitCode, message, metadata, message,
                exitCode >= 2 ? message : "")
            result["durationMs"] := A_TickCount - started
            return result
        } finally {
            DllCall("ReleaseMutex", "Ptr", mutex)
            DllCall("CloseHandle", "Ptr", mutex)
        }
    }

    ; The unscoped operator release shares the lease mutex with reservation
    ; operations so it cannot log off LABUSER while a lease is active or while
    ; a reservation is being prepared.
    static ExecuteAdministrativeRelease(options) {
        request := Map("id", "operator-release", "command", "release-session")
        mutex := DllCall("CreateMutexW", "Ptr", 0, "Int", 0, "WStr", this.MutexName, "Ptr")
        if (!mutex)
            return this.ErrorResult(request, "STATION_JOURNAL_UNAVAILABLE", "lease journal lock is unavailable")
        waitResult := DllCall("WaitForSingleObject", "Ptr", mutex, "UInt", 180000, "UInt")
        if (waitResult != 0 && waitResult != 0x80) {
            DllCall("CloseHandle", "Ptr", mutex)
            return this.ErrorResult(request, "STATION_OPERATION_IN_PROGRESS", "another lease operation is still running")
        }

        try {
            try {
                state := this.LoadState()
            } catch {
                return this.ErrorResult(request, "STATION_JOURNAL_UNAVAILABLE", "lease journal is invalid or unavailable")
            }
            if (state.Has("active"))
                return this.ErrorResult(request, "STATION_LEASE_CONFLICT", "an active lease must be released by its reservation flow")

            try {
                if (LS_SessionManager.GetPrepareRemoteLabUserSessions("").Length > 0)
                    return this.ErrorResult(request, "STATION_REMOTE_SESSION_ACTIVE",
                        "an active remote LABUSER session is protected; administrative Release did not run")
            } catch as e {
                return this.ErrorResult(request, "STATION_SESSION_QUERY_FAILED",
                    "remote LABUSER session state is unavailable; administrative Release did not run")
            }

            started := A_TickCount
            LS_SessionManager.LastReleaseExitCode := 0
            options["protectActiveRemoteSession"] := true
            successful := LS_SessionManager.ReleaseSession(options)
            exitCode := LS_SessionManager.LastReleaseExitCode
            if (!successful && exitCode < 2)
                exitCode := 2
            message := LS_SessionManager.LastReleaseMessage != "" ? LS_SessionManager.LastReleaseMessage
                : successful ? (exitCode = 0 ? "station released" : "station released with warnings")
                : "Release-session failed or was refused"
            metadata := Map("administrative", true)
            this.MergeMetadata(metadata, LS_SessionManager.LastReleaseMetadata)
            result := this.Result(request, exitCode, message, metadata, message, successful ? "" : message)
            result["durationMs"] := A_TickCount - started
            return result
        } finally {
            DllCall("ReleaseMutex", "Ptr", mutex)
            DllCall("CloseHandle", "Ptr", mutex)
        }
    }

    ; The installed background task runs this watchdog independently of a
    ; Gateway connection. Expiry cleanup uses the same durable lease journal
    ; and mutex as dispatched operations so it cannot race a prepare/release.
    static EnforceLeaseExpiry(sessionExecutor := unset) {
        mutex := DllCall("CreateMutexW", "Ptr", 0, "Int", 0, "WStr", this.MutexName, "Ptr")
        if (!mutex) {
            LS_LogWarning("Lease expiry watchdog could not open the lease journal lock")
            return
        }
        waitResult := DllCall("WaitForSingleObject", "Ptr", mutex, "UInt", 0, "UInt")
        if (waitResult != 0 && waitResult != 0x80) {
            DllCall("CloseHandle", "Ptr", mutex)
            return
        }

        try {
            try {
                state := this.LoadState()
            } catch as e {
                LS_LogWarning("Lease expiry watchdog cannot read the lease journal: " . e.Message)
                return
            }
            if (!state.Has("active"))
                return

            active := state["active"]
            originalState := active.Has("state") ? active["state"] : ""
            wasRecoveryRequired := active.Has("state") && active["state"] = "recovery-required"
            wasInterruptedRelease := active.Has("state") && (active["state"] = "expiring"
                || active["state"] = "releasing" || active["state"] = "preparing")
            for key in ["kind", "leaseId", "generation", "notBefore", "expiresAt"] {
                if (active.Has(key))
                    continue
                active["state"] := "recovery-required"
                active["updatedAt"] := this.TimestampUtc()
                state["active"] := active
                try {
                    this.SaveState(state)
                } catch {
                    LS_LogWarning("Active lease is incomplete and its recovery state could not be recorded")
                    return
                }
                LS_LogWarning("Active lease is incomplete; station admission remains closed")
                return
            }
            expiresAt := this.ParseUtc(active["expiresAt"])
            now := this.ParseUtc(this.TimestampUtc())
            if (expiresAt = "") {
                active["state"] := "recovery-required"
                active["updatedAt"] := this.TimestampUtc()
                state["active"] := active
                try {
                    this.SaveState(state)
                } catch {
                    LS_LogWarning("Active lease has an invalid expiry and its recovery state could not be recorded")
                    return
                }
                LS_LogWarning("Active lease has an invalid expiry; station admission remains closed")
                return
            }
            leaseId := active["leaseId"]
            generation := active["generation"] + 0
            if (generation < 1) {
                active["state"] := "recovery-required"
                active["updatedAt"] := this.TimestampUtc()
                state["active"] := active
                try {
                    this.SaveState(state)
                } catch {
                    LS_LogWarning("Active lease has an invalid generation and its recovery state could not be recorded")
                    return
                }
                LS_LogWarning("Active lease has an invalid generation; station admission remains closed")
                return
            }
            operations := state["operations"]
            releaseRequested := false
            if (now < expiresAt) {
                for _, operation in operations {
                    if (!operation.Has("leaseId") || operation["leaseId"] != leaseId
                        || !operation.Has("generation") || operation["generation"] != generation
                        || !operation.Has("command") || operation["command"] != "release-session")
                        continue
                    if (operation.Has("state") && (operation["state"] = "processing"
                        || operation["state"] = "completed" || operation["state"] = "recovery-required")) {
                        releaseRequested := true
                        break
                    }
                }
            }
            journalChanged := false
            uncertainOperation := false
            for operationId, operation in operations {
                if (operation["leaseId"] != leaseId || operation["generation"] != generation)
                    continue
                if (operation["state"] = "processing") {
                    recoveryRequest := Map("id", operationId, "command", operation["command"])
                    operation["state"] := "recovery-required"
                    operation["updatedAt"] := this.TimestampUtc()
                    operation["result"] := this.ErrorResult(recoveryRequest,
                        "STATION_OPERATION_RECOVERY_REQUIRED", "operation outcome is unknown after interruption; operator reconciliation is required")
                    operations[operationId] := operation
                    journalChanged := true
                    uncertainOperation := true
                } else if (operation["state"] = "recovery-required") {
                    result := operation.Has("result") && Type(operation["result"]) = "Map" ? operation["result"] : Map()
                    metadata := result.Has("metadata") && Type(result["metadata"]) = "Map" ? result["metadata"] : Map()
                    if (!metadata.Has("code") || metadata["code"] = "STATION_OPERATION_RECOVERY_REQUIRED")
                        uncertainOperation := true
                }
            }

            ; Keep admission closed while an expired lease waits for cleanup or reconciliation.
            if (!active.Has("state") || active["state"] != "recovery-required") {
                active["state"] := "recovery-required"
                active["updatedAt"] := this.TimestampUtc()
                state["active"] := active
                journalChanged := true
            }
            if (journalChanged) {
                try {
                    this.SaveState(state)
                } catch as e {
                    LS_LogWarning("Lease expiry watchdog could not record recovery state: " . e.Message)
                    return
                }
            }
            if (originalState != "active" && originalState != "recovery-required"
                && originalState != "expiring" && originalState != "releasing" && originalState != "preparing") {
                reason := "expired lease has an unsupported journal state"
                try {
                    this.RecordExpiryReconciliationRequired(state, active, reason)
                } catch as e {
                    LS_LogWarning("Lease expiry watchdog could not record recovery state: " . e.Message)
                    return
                }
                LS_LogWarning("Expired lease has an unsupported journal state; admission remains closed")
                return
            }
            if (uncertainOperation && journalChanged) {
                reason := "a lease operation has an uncertain outcome after interruption"
                try {
                    this.RecordExpiryReconciliationRequired(state, active, reason)
                    this.SetNextReconcileAt(state["active"])
                    this.SaveState(state)
                } catch as e {
                    LS_LogWarning("Lease expiry watchdog could not record recovery state: " . e.Message)
                    return
                }
                LS_LogWarning("A lease operation has an uncertain outcome; station admission remains closed while safe recovery is scheduled")
                return
            }
            expiryOperationId := "lease-expiry-" . generation
            if (wasInterruptedRelease) {
                reason := wasInterruptedRelease
                    ? "expired lease has an interrupted release without a durable result"
                    : "expired lease has no persisted retryable Release result"
                try {
                    this.RecordExpiryReconciliationRequired(state, active, reason)
                    this.SetNextReconcileAt(state["active"])
                    this.SaveState(state)
                } catch as e {
                    LS_LogWarning("Lease expiry watchdog could not record recovery state: " . e.Message)
                    return
                }
                LS_LogWarning("Interrupted expired lease operation recorded for recovery generation " . generation)
                return
            }

            ; A failed Prepare keeps the reservation lease closed until expiry;
            ; only a lease-bound Release request can reconcile before that time.
            if (now < expiresAt && !releaseRequested)
                return

            if (active["state"] = "recovery-required") {
                retryAt := ""
                if (active.Has("nextReconcileAt")) {
                    retryAt := this.ParseUtc(active["nextReconcileAt"])
                    if (retryAt = "") {
                        LS_LogWarning("Lease recovery retry time is invalid; station admission remains closed")
                        return
                    }
                }
                latestOperationAt := this.LatestLeaseOperationTime(operations, active)
                if (latestOperationAt != "") {
                    latestRetryAt := latestOperationAt + this.ReconciliationRetrySeconds
                    if (retryAt = "" || latestRetryAt > retryAt)
                        retryAt := latestRetryAt
                }
                if (retryAt != "" && now < retryAt)
                    return
                if (!operations.Has(expiryOperationId)
                    && !this.LeaseReleaseFailuresAreRetryable(operations, leaseId, generation)) {
                    reason := "expired lease has a partial or uncertain result that needs a new Release attempt"
                    try {
                        this.RecordExpiryReconciliationRequired(state, active, reason)
                        operations := state["operations"]
                        active := state["active"]
                        retryAt := active.Has("nextReconcileAt") ? this.ParseUtc(active["nextReconcileAt"]) : ""
                        if (retryAt != "" && now < retryAt) {
                            this.SaveState(state)
                            return
                        }
                    } catch as e {
                        LS_LogWarning("Lease expiry watchdog could not record recovery state: " . e.Message)
                        return
                    }
                }
            }

            expiryOperationId := this.NextLeaseExpiryOperationId(operations, leaseId, generation)
            reconciliationAttempt := wasRecoveryRequired
            if (expiryOperationId = "") {
                expiryOperationId := this.NextLeaseReconciliationOperationId(operations, leaseId, generation)
                reconciliationAttempt := true
                if (expiryOperationId = "") {
                    if (journalChanged)
                        LS_LogWarning("A prior recovery Release is still processing; station admission remains closed")
                    return
                }
            }

            if (!this.StoredLeaseIdentityIsValid(active)) {
                reason := "expired lease identity is incomplete or invalid"
                try {
                    this.RecordExpiryReconciliationRequired(state, active, reason)
                } catch as e {
                    LS_LogWarning("Lease expiry watchdog could not record recovery state: " . e.Message)
                    return
                }
                LS_LogWarning("Expired lease identity is invalid; automatic reconciliation is stopped for generation " . generation)
                return
            }

            blockReason := this.AutomaticExpiryReleaseBlockReason()
            if (blockReason != "") {
                try {
                    this.SetNextReconcileAt(active)
                    state["active"] := active
                    this.SaveState(state)
                } catch as e {
                    LS_LogWarning("Lease expiry watchdog could not defer recovery: " . e.Message)
                    return
                }
                LS_LogWarning("Expired lease recovery deferred for generation " . generation . ": " . blockReason)
                return
            }

            if (reconciliationAttempt) {
                this.SetNextReconcileAt(active)
                state["active"] := active
                try {
                    this.SaveState(state)
                } catch as e {
                    LS_LogWarning("Lease expiry watchdog could not schedule recovery: " . e.Message)
                    return
                }
            }

            context := Map(
                "kind", active["kind"],
                "leaseId", leaseId,
                "generation", generation,
                "notBefore", active["notBefore"],
                "expiresAt", active["expiresAt"]
            )
            if (active.Has("labId"))
                context["labId"] := active["labId"]
            if (active.Has("reservationKey"))
                context["reservationKey"] := active["reservationKey"]
            issuedAt := this.TimestampUtc()
            executeBefore := FormatTime(DateAdd(A_NowUTC, 300, "Seconds"), "yyyy-MM-ddTHH:mm:ssZ")
            request := Map(
                "schemaVersion", 2,
                "id", expiryOperationId,
                "operation", "execute",
                "command", "release-session",
                "args", ["--protect-local-sessions"],
                "issuedAt", issuedAt,
                "executeBefore", executeBefore,
                "context", context
            )
            result := IsSet(sessionExecutor) ? this.ExecuteLocked(request, sessionExecutor) : this.ExecuteLocked(request)
            if (result["exitCode"] >= 2) {
                this.SetLeaseReconcileRetryAt(leaseId, generation)
                if (result.Has("metadata") && Type(result["metadata"]) = "Map"
                    && result["metadata"].Has("retryable") && result["metadata"]["retryable"] = true)
                    LS_LogWarning("Lease expiry cleanup failed before effects; a later watchdog pass will retry generation " . generation)
                else
                    LS_LogWarning("Lease cleanup remains recovery-required; automatic reconciliation will retry generation " . generation)
            } else if (result["exitCode"] = 1) {
                LS_LogWarning("Expired reservation lease released with warnings for generation " . generation)
            } else {
                LS_LogInfo("Expired reservation lease released for generation " . generation)
            }
        } finally {
            DllCall("ReleaseMutex", "Ptr", mutex)
            DllCall("CloseHandle", "Ptr", mutex)
        }
    }

    static LeaseReleaseFailuresAreRetryable(operations, leaseId, generation) {
        found := false
        for _, operation in operations {
            if (Type(operation) != "Map")
                return false
            if (!operation.Has("leaseId") || operation["leaseId"] != leaseId
                || !operation.Has("generation") || operation["generation"] != generation
                || !operation.Has("command") || operation["command"] != "release-session")
                continue
            if (!operation.Has("state") || operation["state"] != "completed"
                || !operation.Has("result") || Type(operation["result"]) != "Map")
                return false
            result := operation["result"]
            if (!result.Has("exitCode") || result["exitCode"] < 2 || !result.Has("metadata")
                || Type(result["metadata"]) != "Map" || !result["metadata"].Has("retryable")
                || result["metadata"]["retryable"] != true)
                return false
            found := true
        }
        return found
    }

    static LatestLeaseOperationTime(operations, active) {
        latest := active.Has("updatedAt") ? this.ParseUtc(active["updatedAt"]) : ""
        for _, operation in operations {
            if (Type(operation) != "Map" || !operation.Has("leaseId") || operation["leaseId"] != active["leaseId"]
                || !operation.Has("generation") || operation["generation"] != active["generation"]
                || !operation.Has("updatedAt"))
                continue
            updatedAt := this.ParseUtc(operation["updatedAt"])
            if (updatedAt != "" && (latest = "" || updatedAt > latest))
                latest := updatedAt
        }
        return latest
    }

    static NextLeaseReconciliationOperationId(operations, leaseId, generation) {
        attempt := 1
        Loop {
            operationId := "lease-reconcile-" . generation . "-" . attempt
            if (StrLen(operationId) > 96)
                return ""
            if (!operations.Has(operationId))
                return operationId
            operation := operations[operationId]
            if (Type(operation) != "Map" || !operation.Has("leaseId") || operation["leaseId"] != leaseId
                || !operation.Has("generation") || operation["generation"] != generation
                || !operation.Has("command") || operation["command"] != "release-session"
                || !operation.Has("state") || operation["state"] = "processing")
                return ""
            attempt += 1
        }
    }

    static StoredLeaseIdentityIsValid(active) {
        if (!active.Has("kind") || (active["kind"] != "reservation" && active["kind"] != "demo")
            || !active.Has("leaseId") || !this.ValidIdentifier(active["leaseId"])
            || !active.Has("generation") || !IsInteger(active["generation"]) || active["generation"] < 1
            || !active.Has("notBefore") || !active.Has("expiresAt"))
            return false
        if (active["kind"] = "reservation"
            && (!active.Has("labId") || !this.ValidIdentifier(active["labId"])
                || !active.Has("reservationKey") || !this.ValidIdentifier(active["reservationKey"])))
            return false
        if (active["kind"] = "demo" && SubStr(active["leaseId"], 1, 5) != "demo:")
            return false
        notBefore := this.ParseUtc(active["notBefore"])
        expiresAt := this.ParseUtc(active["expiresAt"])
        return notBefore != "" && expiresAt != "" && expiresAt > notBefore
    }

    static AutomaticExpiryReleaseBlockReason() {
        return LS_SessionManager.AutomaticExpiryReleaseBlockReason()
    }

    static SetNextReconcileAt(active) {
        nextAt := DateAdd(A_NowUTC, this.ReconciliationRetrySeconds, "Seconds")
        active["nextReconcileAt"] := FormatTime(nextAt, "yyyy-MM-ddTHH:mm:ssZ")
        active["updatedAt"] := this.TimestampUtc()
        return active
    }

    static SetLeaseReconcileRetryAt(leaseId, generation) {
        try {
            state := this.LoadState()
            if (!state.Has("active") || state["active"]["leaseId"] != leaseId
                || state["active"]["generation"] != generation || state["active"]["state"] != "recovery-required")
                return
            active := this.SetNextReconcileAt(state["active"])
            state["active"] := active
            this.SaveState(state)
        } catch as e {
            LS_LogWarning("Lease recovery retry time could not be persisted: " . e.Message)
        }
    }

    static RecordExpiryReconciliationRequired(state, active, reason) {
        updatedAt := this.TimestampUtc()
        active["state"] := "recovery-required"
        active["updatedAt"] := updatedAt
        state["active"] := active
        operations := state["operations"]
        markerId := "lease-expiry-recovery-" . active["generation"]
        if (!operations.Has(markerId)) {
            request := Map("id", markerId, "command", "release-session")
            result := this.ErrorResult(request, "STATION_OPERATION_RECOVERY_REQUIRED", reason)
            operations[markerId] := Map(
                "state", "recovery-required",
                "command", "release-session",
                "leaseId", active["leaseId"],
                "generation", active["generation"],
                "updatedAt", updatedAt,
                "result", result
            )
            state["operations"] := operations
        }
        this.SaveState(state)
    }

    static NextLeaseExpiryOperationId(operations, leaseId, generation) {
        attempt := 1
        Loop {
            operationId := attempt = 1 ? "lease-expiry-" . generation
                : "lease-expiry-" . generation . "-retry-" . attempt
            if (StrLen(operationId) > 96)
                return ""
            if (!operations.Has(operationId))
                return operationId
            operation := operations[operationId]
            if (Type(operation) != "Map" || !operation.Has("leaseId") || operation["leaseId"] != leaseId
                || !operation.Has("generation") || operation["generation"] != generation
                || !operation.Has("command") || operation["command"] != "release-session"
                || !operation.Has("state") || operation["state"] != "completed"
                || !operation.Has("result") || Type(operation["result"]) != "Map")
                return ""
            result := operation["result"]
            if (!result.Has("exitCode") || result["exitCode"] < 2 || !result.Has("metadata")
                || Type(result["metadata"]) != "Map" || !result["metadata"].Has("retryable")
                || result["metadata"]["retryable"] != true)
                return ""
            attempt += 1
        }
    }

    static Execute(request, sessionExecutor := unset) {
        if (IsObject(request) && Type(request) = "Map" && request.Has("operation")
            && request["operation"] = "operation.status")
            return this.OperationStatus(request)

        validation := this.ValidateRequest(request)
        if (validation["code"] != "")
            return this.ErrorResult(request, validation["code"], validation["message"])

        mutex := DllCall("CreateMutexW", "Ptr", 0, "Int", 0, "WStr", this.MutexName, "Ptr")
        if (!mutex)
            return this.ErrorResult(request, "STATION_JOURNAL_UNAVAILABLE", "lease journal lock is unavailable")
        waitResult := DllCall("WaitForSingleObject", "Ptr", mutex, "UInt", 180000, "UInt")
        if (waitResult != 0 && waitResult != 0x80) {
            DllCall("CloseHandle", "Ptr", mutex)
            return this.ErrorResult(request, "STATION_OPERATION_IN_PROGRESS", "another lease operation is still running")
        }

        try {
            return this.ExecuteLocked(request, sessionExecutor)
        } finally {
            DllCall("ReleaseMutex", "Ptr", mutex)
            DllCall("CloseHandle", "Ptr", mutex)
        }
    }

    static OperationStatus(request) {
        validation := this.ValidateOperationStatusRequest(request)
        if (validation["code"] != "")
            return this.ErrorResult(request, validation["code"], validation["message"])

        operationId := request["operationId"]
        try {
            state := this.LoadState()
        } catch {
            return this.ErrorResult(request, "STATION_JOURNAL_UNAVAILABLE", "operation journal is invalid or unavailable")
        }

        operations := state["operations"]
        if (!operations.Has(operationId)) {
            record := Map("operationId", operationId, "state", "not-found")
            return this.Result(request, 1, "operation not found", Map("operationId", operationId, "state", "not-found"), LS_ToJson(record), "")
        }

        operation := operations[operationId]
        if (Type(operation) != "Map" || !operation.Has("state")
            || (operation["state"] != "processing" && operation["state"] != "completed"
                && operation["state"] != "recovery-required"))
            return this.ErrorResult(request, "STATION_JOURNAL_UNAVAILABLE", "operation journal entry is invalid")

        record := Map("operationId", operationId, "state", operation["state"])
        for key in ["command", "leaseId", "generation", "updatedAt"] {
            if (operation.Has(key))
                record[key] := operation[key]
        }
        if (operation.Has("result")) {
            if (Type(operation["result"]) != "Map")
                return this.ErrorResult(request, "STATION_JOURNAL_UNAVAILABLE", "operation journal result is invalid")
            record["result"] := operation["result"]
        }
        return this.Result(request, 0, "operation status retrieved", Map("operationId", operationId, "state", operation["state"]), LS_ToJson(record), "")
    }

    static ValidateOperationStatusRequest(request) {
        if (!IsObject(request) || Type(request) != "Map")
            return Map("code", "STATION_COMMAND_REJECTED", "message", "operation status request is invalid")
        allowed := Map("schemaVersion", true, "id", true, "operation", true, "operationId", true)
        for key in request {
            if (!allowed.Has(key))
                return Map("code", "STATION_COMMAND_REJECTED", "message", "operation status request has unsupported fields")
        }
        for key in ["schemaVersion", "id", "operation", "operationId"] {
            if (!request.Has(key))
                return Map("code", "STATION_COMMAND_REJECTED", "message", "operation status request is incomplete")
        }
        if (request["schemaVersion"] != 2 || request["operation"] != "operation.status")
            return Map("code", "STATION_COMMAND_REJECTED", "message", "operation status request is unsupported")
        for key in ["id", "operationId"] {
            value := request[key]
            if (Type(value) != "String" || StrLen(value) > 96
                || !RegExMatch(value, "^[A-Za-z0-9][A-Za-z0-9_.:-]*$"))
                return Map("code", "STATION_COMMAND_REJECTED", "message", "operation status identifier is invalid")
        }
        return Map("code", "", "message", "")
    }

    static ExecuteLocked(request, sessionExecutor := unset) {
        try {
            state := this.LoadState()
        } catch {
            return this.ErrorResult(request, "STATION_JOURNAL_UNAVAILABLE", "lease journal is invalid or unavailable")
        }
        operationId := request["id"]
        payload := LS_ToJson(request)
        operations := state["operations"]

        if (operations.Has(operationId)) {
            operation := operations[operationId]
            if (operation["payload"] != payload)
                return this.ErrorResult(request, "STATION_OPERATION_ID_CONFLICT", "operation id was already used with a different request")
            if (operation["state"] = "completed")
                return operation["result"]
            if (operation["state"] = "processing") {
                recovery := this.ErrorResult(request, "STATION_OPERATION_RECOVERY_REQUIRED", "operation outcome is unknown; operator reconciliation is required")
                operation["state"] := "recovery-required"
                operation["updatedAt"] := this.TimestampUtc()
                operation["result"] := recovery
                operations[operationId] := operation
                if (state.Has("active") && state["active"]["leaseId"] = operation["leaseId"]
                    && state["active"]["generation"] = operation["generation"]) {
                    state["active"]["state"] := "recovery-required"
                    state["active"]["updatedAt"] := operation["updatedAt"]
                }
                try {
                    this.SaveState(state)
                } catch {
                    return this.ErrorResult(request, "STATION_JOURNAL_UNAVAILABLE", "operation recovery state could not be recorded")
                }
                return recovery
            }
            return this.ErrorResult(request, "STATION_OPERATION_IN_PROGRESS", "operation is still being reconciled")
        }

        context := request["context"]
        leaseId := context["leaseId"]
        generation := context["generation"]
        command := request["command"]
        now := this.TimestampUtc()
        assignedGeneration := generation

        if (command = "prepare-session") {
            if (state.Has("active"))
                return this.ErrorResult(request, "STATION_LEASE_CONFLICT", "another lease is active or requires recovery")
            state["nextGeneration"] += 1
            assignedGeneration := state["nextGeneration"]
            state["active"] := this.LeaseRecord(context, assignedGeneration, "preparing", now)
        } else {
            if (!state.Has("active") && state.Has("lastReleased")
                && state["lastReleased"]["leaseId"] = leaseId
                && state["lastReleased"]["generation"] = generation) {
                result := this.SuccessResult(request, generation, "released", "lease already released")
                operations[operationId] := this.CompletedOperation(payload, command, leaseId, generation, result)
                try {
                    this.SaveState(state)
                } catch {
                    return this.ErrorResult(request, "STATION_JOURNAL_UNAVAILABLE", "operation result could not be recorded")
                }
                return result
            }
            if (!state.Has("active") || state["active"]["leaseId"] != leaseId
                || state["active"]["generation"] != generation
                || (state["active"]["state"] != "active" && state["active"]["state"] != "recovery-required"))
                return this.ErrorResult(request, "STATION_LEASE_STALE", "lease identity or generation is no longer active")
            state["active"]["state"] := "releasing"
            state["active"]["updatedAt"] := now
        }

        operation := Map(
            "payload", payload,
            "state", "processing",
            "command", command,
            "leaseId", leaseId,
            "generation", assignedGeneration,
            "updatedAt", now
        )
        operations[operationId] := operation
        try {
            this.SaveState(state)
        } catch {
            return this.ErrorResult(request, "STATION_JOURNAL_UNAVAILABLE", "operation could not be started")
        }

        started := A_TickCount
        LS_SessionManager.LastReleaseExitCode := 0
        LS_SessionManager.LastReleaseRetryable := false
        LS_SessionManager.LastPrepareExitCode := 0
        LS_SessionManager.LastPrepareRetryable := false
        LS_SessionManager.LastPrepareMessage := ""
        LS_SessionManager.LastPrepareMetadata := Map()
        LS_SessionManager.LastReleaseMessage := ""
        LS_SessionManager.LastReleaseMetadata := Map()
        try {
            if IsSet(sessionExecutor)
                successful := sessionExecutor.Call(command, request["args"])
            else
                successful := this.RunSessionOperation(command, request["args"])
        } catch as e {
            LS_LogError("Durable lease session operation failed: " . e.Message)
            successful := false
        }
        exitCode := successful ? 0 : 1
        if (command = "prepare-session") {
            if (successful)
                exitCode := LS_SessionManager.LastPrepareExitCode
            else if (LS_SessionManager.LastPrepareExitCode >= 2)
                exitCode := LS_SessionManager.LastPrepareExitCode
            if (!successful && exitCode < 2)
                exitCode := 2
        } else {
            exitCode := LS_SessionManager.LastReleaseExitCode
            if (!successful && exitCode < 2)
                exitCode := 2
        }
        if (command = "prepare-session" && !successful && LS_SessionManager.LastPrepareRetryable) {
            message := LS_SessionManager.LastPrepareMessage != "" ? LS_SessionManager.LastPrepareMessage
                : "prepare was refused before changing station sessions"
            result := this.ErrorResult(request, "STATION_PREPARE_REFUSED", message)
            this.MergeMetadata(result["metadata"], LS_SessionManager.LastPrepareMetadata)
            result["metadata"]["retryable"] := true
            state.Delete("active")
            operations.Delete(operationId)
            try {
                this.SaveState(state)
            } catch {
                return this.ErrorResult(request, "STATION_JOURNAL_UNAVAILABLE", "refused prepare could not be rolled back")
            }
            return result
        }
        completed := exitCode < 2
        leaseState := command = "prepare-session" ? (completed ? "active" : "recovery-required") : (completed ? "released" : "recovery-required")
        message := completed
            ? (command = "prepare-session"
                ? (LS_SessionManager.LastPrepareMessage != "" ? LS_SessionManager.LastPrepareMessage
                    : (exitCode = 0 ? "session prepared" : "session prepared with warnings"))
                : (LS_SessionManager.LastReleaseMessage != "" ? LS_SessionManager.LastReleaseMessage
                    : (exitCode = 0 ? "session released" : "session released with warnings")))
            : command = "prepare-session"
                ? (LS_SessionManager.LastPrepareMessage != "" ? LS_SessionManager.LastPrepareMessage : "session preparation requires recovery")
                : (LS_SessionManager.LastReleaseMessage != "" ? LS_SessionManager.LastReleaseMessage : "session release requires recovery")
        if (exitCode >= 2) {
            context := request["context"]
            lease := Map("leaseId", context["leaseId"], "generation", assignedGeneration,
                "state", leaseState, "expiresAt", context["expiresAt"])
            metadata := Map("lease", lease)
            if (command = "prepare-session")
                this.MergeMetadata(metadata, LS_SessionManager.LastPrepareMetadata)
            else
                this.MergeMetadata(metadata, LS_SessionManager.LastReleaseMetadata)
            result := this.Result(request, exitCode, message, metadata, "", message)
        } else {
            result := this.SuccessResult(request, assignedGeneration, leaseState, message)
            result["exitCode"] := exitCode
            result["outcome"] := exitCode = 0 ? "success" : "warning"
            if (command = "prepare-session")
                this.MergeMetadata(result["metadata"], LS_SessionManager.LastPrepareMetadata)
            else
                this.MergeMetadata(result["metadata"], LS_SessionManager.LastReleaseMetadata)
        }
        result["durationMs"] := Max(1, A_TickCount - started)
        if (result["metadata"].Has("lease"))
            result["metadata"]["lease"]["state"] := leaseState
        operation["state"] := "completed"
        operation["updatedAt"] := this.TimestampUtc()
        operation["result"] := result

        if (command = "prepare-session") {
            state["active"]["state"] := leaseState
            state["active"]["updatedAt"] := operation["updatedAt"]
        } else if (completed) {
            released := state["active"]
            released["state"] := "released"
            released["updatedAt"] := operation["updatedAt"]
            if (released.Has("nextReconcileAt"))
                released.Delete("nextReconcileAt")
            state["lastReleased"] := released
            state.Delete("active")
        } else {
            state["active"]["state"] := "recovery-required"
            state["active"]["updatedAt"] := operation["updatedAt"]
        }
        operations[operationId] := operation
        try {
            this.SaveState(state)
        } catch {
            return this.ErrorResult(request, "STATION_JOURNAL_UNAVAILABLE", "operation result could not be recorded")
        }
        return result
    }

    static ValidateRequest(request) {
        failure := Map("code", "", "message", "")
        if (!IsObject(request) || Type(request) != "Map")
            return Map("code", "STATION_COMMAND_REJECTED", "message", "lease request is invalid")
        required := ["schemaVersion", "id", "operation", "command", "args", "issuedAt", "executeBefore", "context"]
        for key in required {
            if (!request.Has(key))
                return Map("code", "STATION_COMMAND_REJECTED", "message", "lease request is incomplete")
        }
        if (request["schemaVersion"] != 2 || request["operation"] != "execute"
            || (request["command"] != "prepare-session" && request["command"] != "release-session"))
            return Map("code", "STATION_COMMAND_REJECTED", "message", "lease command is unsupported")
        if (Type(request["id"]) != "String" || StrLen(request["id"]) > 96
            || !RegExMatch(request["id"], "^[A-Za-z0-9_.:-]+$"))
            return Map("code", "STATION_COMMAND_REJECTED", "message", "operation id is invalid")
        if (!this.ValidateArgs(request["args"], request["command"]))
            return Map("code", "STATION_COMMAND_REJECTED", "message", "lease command arguments are invalid")

        issuedAt := this.ParseUtc(request["issuedAt"])
        executeBefore := this.ParseUtc(request["executeBefore"])
        now := this.ParseUtc(this.TimestampUtc())
        if (issuedAt = "" || executeBefore = "" || executeBefore <= issuedAt
            || executeBefore - issuedAt > 300 || now < issuedAt || now > executeBefore)
            return Map("code", "STATION_DISPATCHER_DEADLINE_EXPIRED", "message", "dispatcher request is outside its execution window")

        context := request["context"]
        if (!IsObject(context) || Type(context) != "Map")
            return Map("code", "STATION_COMMAND_REJECTED", "message", "lease context is required")
        for key in ["kind", "leaseId", "generation", "notBefore", "expiresAt"] {
            if (!context.Has(key))
                return Map("code", "STATION_COMMAND_REJECTED", "message", "lease context is incomplete")
        }
        kind := context["kind"]
        leaseId := context["leaseId"]
        if ((kind != "reservation" && kind != "demo") || Type(leaseId) != "String"
            || !RegExMatch(leaseId, "^[A-Za-z0-9][A-Za-z0-9_.:-]{0,127}$"))
            return Map("code", "STATION_COMMAND_REJECTED", "message", "lease identity is invalid")
        if (kind = "reservation") {
            if (!context.Has("labId") || !context.Has("reservationKey")
                || !this.ValidIdentifier(context["labId"]) || !this.ValidIdentifier(context["reservationKey"]))
                return Map("code", "STATION_COMMAND_REJECTED", "message", "reservation identity is invalid")
        } else if (SubStr(leaseId, 1, 5) != "demo:") {
            return Map("code", "STATION_COMMAND_REJECTED", "message", "demo lease identity is invalid")
        }
        notBefore := this.ParseUtc(context["notBefore"])
        expiresAt := this.ParseUtc(context["expiresAt"])
        if (notBefore = "" || expiresAt = "" || expiresAt <= notBefore)
            return Map("code", "STATION_COMMAND_REJECTED", "message", "lease expiry is invalid")
        generation := context["generation"]
        if (!IsInteger(generation) || generation < 0
            || (request["command"] = "prepare-session" && (generation != 0 || expiresAt <= now))
            || (request["command"] = "release-session" && generation = 0))
            return Map("code", "STATION_COMMAND_REJECTED", "message", "lease generation is invalid")
        return failure
    }

    static ValidateArgs(args, command) {
        if (Type(args) != "Array" || args.Length > 12)
            return false
        authorizationSeen := false
        allowed := Map(
            "--guard-grace", true, "--guard-message", true, "--guard-silent", true,
            "--guard-notify", true, "--no-guard", true, "--user", true,
            "--reboot", true, "--reboot-timeout", true,
            "--protect-local-sessions", true,
            "--unreserved-remote-labuser-sessions", true
        )
        for arg in args {
            if (Type(arg) != "String" || StrLen(arg) > 256 || RegExMatch(arg, "[\r\n\x00]")
                || SubStr(arg, 1, 2) != "--")
                return false
            pair := StrSplit(arg, "=", , 2)
            key := pair[1]
            if (!allowed.Has(key))
                return false
            value := pair.Length > 1 ? pair[2] : "true"
            if (pair.Length = 1 && key != "--no-guard" && key != "--guard-silent" && key != "--reboot"
                && key != "--protect-local-sessions")
                return false
            if (key = "--protect-local-sessions" && pair.Length > 1)
                return false
            if (key = "--unreserved-remote-labuser-sessions") {
                if (authorizationSeen || command != "prepare-session" || pair.Length < 2
                    || !RegExMatch(value, "^[A-Za-z0-9][A-Za-z0-9_.:-]*(,[A-Za-z0-9][A-Za-z0-9_.:-]*){0,31}$"))
                    return false
                authorizationSeen := true
            }
            if (key = "--user" && !RegExMatch(value, "^[A-Za-z0-9_.-]{1,64}$"))
                return false
            if (key = "--guard-grace" && (!RegExMatch(value, "^\d+$") || value > 600))
                return false
            if (key = "--reboot-timeout" && (!RegExMatch(value, "^\d+$") || value > 3600))
                return false
            if (key = "--guard-notify" && value != "true" && value != "false" && value != "yes" && value != "no")
                return false
            if (key = "--guard-message" && (value = "" || StrLen(value) > 128))
                return false
            if ((key = "--no-guard" || key = "--guard-silent") && value != "true")
                return false
            if (key = "--reboot" && value != "true" && value != "false")
                return false
        }
        return true
    }

    static RunSessionOperation(command, args) {
        options := Map()
        for arg in args {
            pair := StrSplit(arg, "=", , 2)
            key := pair[1]
            value := pair.Length > 1 ? pair[2] : "true"
            switch key {
                case "--user": options["user"] := value
                case "--no-guard": options["guard"] := false
                case "--guard-grace": options["guardGrace"] := value + 0
                case "--guard-message": options["guardMessage"] := value
                case "--guard-silent": options["guardNotify"] := false
                case "--guard-notify": options["guardNotify"] := value = "true" || value = "yes"
                case "--reboot": options["reboot"] := value = "true"
                case "--protect-local-sessions": options["protectLocalSessions"] := true
                case "--unreserved-remote-labuser-sessions":
                    options["unreservedRemoteLabUserSessionIds"] := StrSplit(value, ",")
                case "--reboot-timeout":
                    options["reboot"] := true
                    options["rebootTimeout"] := value + 0
            }
        }
        return command = "prepare-session" ? LS_SessionManager.PrepareSession(options) : LS_SessionManager.ReleaseSession(options)
    }

    static LoadState() {
        if (!FileExist(LAB_STATION_LEASE_STATE_FILE))
            return Map("nextGeneration", 0, "operations", Map())
        state := LS_ParseJson(FileRead(LAB_STATION_LEASE_STATE_FILE, "UTF-8"))
        if (Type(state) != "Map" || !state.Has("nextGeneration") || !IsInteger(state["nextGeneration"])
            || state["nextGeneration"] < 0 || !state.Has("operations") || Type(state["operations"]) != "Map")
            throw Error("Invalid lease journal")
        if (state.Has("active") && Type(state["active"]) != "Map")
            throw Error("Invalid active lease journal entry")
        if (state.Has("lastReleased") && Type(state["lastReleased"]) != "Map")
            throw Error("Invalid released lease journal entry")
        return state
    }

    static SaveState(state) {
        if (state["nextGeneration"] = 0)
            state["nextGeneration"] := LS_JsonNumberValue(0)
        LS_WriteJson(LAB_STATION_LEASE_STATE_FILE, state)
    }

    static LeaseRecord(context, generation, state, now) {
        record := Map(
            "leaseId", context["leaseId"],
            "kind", context["kind"],
            "generation", generation,
            "state", state,
            "notBefore", context["notBefore"],
            "expiresAt", context["expiresAt"],
            "updatedAt", now
        )
        if (context.Has("labId"))
            record["labId"] := context["labId"]
        if (context.Has("reservationKey"))
            record["reservationKey"] := context["reservationKey"]
        return record
    }

    static CompletedOperation(payload, command, leaseId, generation, result) {
        return Map("payload", payload, "state", "completed", "command", command,
            "leaseId", leaseId, "generation", generation, "updatedAt", this.TimestampUtc(), "result", result)
    }

    static SuccessResult(request, generation, state, message) {
        context := request["context"]
        lease := Map("leaseId", context["leaseId"], "generation", generation, "state", state, "expiresAt", context["expiresAt"])
        result := this.Result(request, 0, message, Map("lease", lease), message, "")
        return result
    }

    static ErrorResult(request, code, message) {
        return this.Result(request, 2, message, Map("code", code), "", message)
    }

    static Result(request, exitCode, message, metadata, stdout, stderr) {
        operationId := IsObject(request) && request.Has("id") ? request["id"] : ""
        command := IsObject(request) && request.Has("command") ? request["command"]
            : IsObject(request) && request.Has("operation") ? request["operation"] : "lease-dispatch"
        return Map(
            "id", operationId,
            "command", command,
            "completedAt", this.TimestampUtc(),
            "success", exitCode < 2,
            "exitCode", exitCode,
            "outcome", exitCode = 0 ? "success" : exitCode = 1 ? "warning" : "failure",
            "message", message,
            "stdout", stdout,
            "stderr", stderr,
            "durationMs", 0,
            "transport", "winrm",
            "metadata", metadata,
            "options", Map()
        )
    }

    static MergeMetadata(target, source) {
        if (!IsObject(source) || Type(source) != "Map")
            return target
        for key, value in source
            target[key] := value
        return target
    }

    static ParseUtc(value) {
        if (Type(value) != "String" || !RegExMatch(value, "^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})(?:\.(\d{1,9}))?Z$", &match))
            return ""
        digits := match[1] . match[2] . match[3] . match[4] . match[5] . match[6]
        if (FormatTime(digits, "yyyy-MM-ddTHH:mm:ss") != SubStr(value, 1, 19))
            return ""
        fraction := match[7] != "" ? ("0." . match[7]) + 0 : 0
        return DateDiff(digits, "19700101000000", "Seconds") + fraction
    }

    static ValidIdentifier(value) {
        return Type(value) = "String" && RegExMatch(value, "^[A-Za-z0-9][A-Za-z0-9_.:-]{0,127}$")
    }

    static TimestampUtc() {
        return FormatTime(A_NowUTC, "yyyy-MM-ddTHH:mm:ssZ")
    }
}
