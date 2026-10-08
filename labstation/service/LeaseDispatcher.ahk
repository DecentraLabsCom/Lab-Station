; Durable dispatcher v2 reservation lease lifecycle for the Windows station.
#Requires AutoHotkey v2.0
#Include ..\core\Config.ahk
#Include ..\core\Json.ahk
#Include ..\core\Logger.ahk

class LS_LeaseDispatcher {
    static MutexName := "Global\DecentraLabs.LabStation.ReservationLease"

    static Execute(request, sessionExecutor := unset) {
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
        leaseState := command = "prepare-session" ? (successful ? "active" : "recovery-required") : (successful ? "released" : "recovery-required")
        result := this.SuccessResult(request, assignedGeneration, leaseState,
            successful ? (command = "prepare-session" ? "session prepared" : "session released") : "session operation completed with warnings")
        result["exitCode"] := exitCode
        result["success"] := true
        result["outcome"] := exitCode = 0 ? "success" : "warning"
        result["durationMs"] := Max(1, A_TickCount - started)
        result["metadata"]["lease"]["state"] := leaseState
        operation["state"] := "completed"
        operation["updatedAt"] := this.TimestampUtc()
        operation["result"] := result

        if (command = "prepare-session") {
            state["active"]["state"] := leaseState
            state["active"]["updatedAt"] := operation["updatedAt"]
        } else if (successful) {
            released := state["active"]
            released["state"] := "released"
            released["updatedAt"] := operation["updatedAt"]
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
        if (!this.ValidateArgs(request["args"]))
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

    static ValidateArgs(args) {
        if (Type(args) != "Array" || args.Length > 12)
            return false
        allowed := Map(
            "--guard-grace", true, "--guard-message", true, "--guard-silent", true,
            "--guard-notify", true, "--no-guard", true, "--user", true,
            "--reboot", true, "--reboot-timeout", true
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
            if (pair.Length = 1 && key != "--no-guard" && key != "--guard-silent" && key != "--reboot")
                return false
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
        command := IsObject(request) && request.Has("command") ? request["command"] : "lease-dispatch"
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
