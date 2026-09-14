#Requires AutoHotkey v2.0
#Include TestSupport.ahk
#Include ..\service\SessionGuard.ahk

global TEST_FAILURES := 0
global TEST_ROOT := A_Temp "\LabStation-SessionGuardTests-" A_TickCount
global ORIGINAL_AUDIT_FILE := LAB_STATION_SESSION_AUDIT_FILE
global ORIGINAL_STATE_FILE := LAB_STATION_SERVICE_STATE_FILE

DirCreate(TEST_ROOT)
LAB_STATION_SESSION_AUDIT_FILE := TEST_ROOT "\session-guard-events.jsonl"
LAB_STATION_SERVICE_STATE_FILE := TEST_ROOT "\service-state.ini"

RunSessionGuardTests()

class RecordingSessionGuard extends LS_SessionGuard {
    static recordedSessions := []
    static shouldQueryFail := false
    static waits := []
    static notifications := []
    static logoffs := []
    static logoffResult := true

    static Reset(sessions := []) {
        this.recordedSessions := sessions
        this.shouldQueryFail := false
        this.waits := []
        this.notifications := []
        this.logoffs := []
        this.logoffResult := true
    }

    static QuerySessions() {
        if (this.shouldQueryFail)
            throw Error("synthetic session query failure")
        return this.recordedSessions
    }

    static WaitForGrace(seconds) {
        this.waits.Push(seconds)
    }

    static NotifySession(session, message, timeout) {
        this.notifications.Push(Map(
            "id", session["id"],
            "message", message,
            "timeout", timeout
        ))
    }

    static LogoffSession(session, force := true) {
        this.logoffs.Push(Map("id", session["id"], "force", force))
        return this.logoffResult
    }
}

RunSessionGuardTests() {
    global ORIGINAL_AUDIT_FILE, ORIGINAL_STATE_FILE
    global LAB_STATION_SESSION_AUDIT_FILE, LAB_STATION_SERVICE_STATE_FILE, TEST_ROOT

    try {
        TestFiltersSessionsAndUsesGraceOptions()
        TestNoConflictingSessionsDoesNotWaitOrLogoff()
        TestNotificationCanBeDisabled()
        TestLogoffFailureIsReportedAfterAllTargetsAreAttempted()
        TestSessionQueryFailureIsReported()
        TestSessionOutputParsing()
        TestUserNormalization()
        TestMissingSessionIdCannotBeLoggedOff()
        TestLogoffAuditIsPersisted()
    } catch as err {
        Fail("Unhandled session-guard test exception: " . err.Message)
    }

    LAB_STATION_SESSION_AUDIT_FILE := ORIGINAL_AUDIT_FILE
    LAB_STATION_SERVICE_STATE_FILE := ORIGINAL_STATE_FILE
    try DirDelete(TEST_ROOT, true)

    if (TEST_FAILURES > 0) {
        LS_TestOutput("SessionGuardTests failed: " . TEST_FAILURES . " failure(s)`n")
        ExitApp(1)
    }

    LS_TestOutput("SessionGuardTests passed`n")
    ExitApp(0)
}

TestFiltersSessionsAndUsesGraceOptions() {
    RecordingSessionGuard.Reset([
        Session("LABUSER", "console", "1", "Active"),
        Session("DOMAIN\\Teacher", "rdp-tcp#1", "2", "Active"),
        Session("other", "rdp-tcp#2", "3", "Disc"),
        Session("", "", "", "")
    ])

    result := RecordingSessionGuard.Run(Map(
        "user", "labuser",
        "grace", 10,
        "message", "Remote reservation confirmed",
        "force", false
    ))

    Assert(result, "session guard succeeds when the target logoff succeeds")
    Assert(RecordingSessionGuard.waits.Length = 1 && RecordingSessionGuard.waits[1] = 30, "session guard enforces the 30-second minimum grace")
    Assert(RecordingSessionGuard.notifications.Length = 1, "session guard notifies only active conflicting sessions")
    Assert(RecordingSessionGuard.notifications[1]["id"] = "2", "session guard notifies the conflicting session")
    Assert(RecordingSessionGuard.notifications[1]["message"] = "Remote reservation confirmed", "session guard forwards the custom message")
    Assert(RecordingSessionGuard.notifications[1]["timeout"] = 30, "notification timeout matches the effective grace")
    Assert(RecordingSessionGuard.logoffs.Length = 1, "session guard logs off only the conflicting session")
    Assert(RecordingSessionGuard.logoffs[1]["id"] = "2", "session guard logs off the conflicting session")
    Assert(!RecordingSessionGuard.logoffs[1]["force"], "session guard forwards soft-logoff mode")
}

TestNoConflictingSessionsDoesNotWaitOrLogoff() {
    RecordingSessionGuard.Reset([
        Session("LABUSER", "console", "1", "Active"),
        Session("other", "rdp-tcp#2", "2", "Disc")
    ])

    result := RecordingSessionGuard.Run(Map("user", "LABUSER", "grace", 60))

    Assert(result, "session guard succeeds when there are no conflicting sessions")
    Assert(RecordingSessionGuard.waits.Length = 0, "session guard does not wait without conflicting sessions")
    Assert(RecordingSessionGuard.notifications.Length = 0, "session guard does not notify without conflicting sessions")
    Assert(RecordingSessionGuard.logoffs.Length = 0, "session guard does not log off without conflicting sessions")
}

TestNotificationCanBeDisabled() {
    RecordingSessionGuard.Reset([Session("teacher", "console", "7", "Active")])

    result := RecordingSessionGuard.Run(Map("user", "LABUSER", "grace", 45, "notify", false))

    Assert(result, "session guard succeeds without notification")
    Assert(RecordingSessionGuard.waits[1] = 45, "session guard preserves grace values above the minimum")
    Assert(RecordingSessionGuard.notifications.Length = 0, "session guard skips notifications when disabled")
    Assert(RecordingSessionGuard.logoffs.Length = 1, "session guard still logs off when notification is disabled")
}

TestLogoffFailureIsReportedAfterAllTargetsAreAttempted() {
    RecordingSessionGuard.Reset([
        Session("teacher", "console", "7", "Active"),
        Session("student", "rdp-tcp#8", "8", "Active")
    ])
    RecordingSessionGuard.logoffResult := false

    result := RecordingSessionGuard.Run(Map("user", "LABUSER", "grace", 45, "notify", false))

    Assert(!result, "session guard reports failure when a logoff fails")
    Assert(RecordingSessionGuard.logoffs.Length = 2, "session guard attempts every target after a logoff failure")
}

TestSessionQueryFailureIsReported() {
    RecordingSessionGuard.Reset()
    RecordingSessionGuard.shouldQueryFail := true

    threw := false
    try result := RecordingSessionGuard.Run(Map("user", "LABUSER"))
    catch {
        threw := true
        result := true
    }

    Assert(!threw, "session guard converts query failures into a warning result")
    Assert(!result, "session guard fails closed when sessions cannot be queried")
    Assert(RecordingSessionGuard.waits.Length = 0, "session guard does not wait after a query failure")
}

TestSessionOutputParsing() {
    output := " USERNAME              SESSIONNAME        ID  STATE   IDLE TIME  LOGON TIME`n"
        . ">DOMAIN\\Teacher         console             2  Active      .  8/25/2026 10:00 AM`n"
        . "LABUSER                rdp-tcp#1           3  Disc         5  8/25/2026 09:00 AM`n"
        . "malformed line`n"

    sessions := LS_SessionGuard.ParseSessionOutput(output)

    Assert(sessions.Length = 2, "session output parser skips headers and malformed rows")
    Assert(sessions[1]["user"] = ">DOMAIN\\Teacher" || sessions[1]["user"] = "DOMAIN\\Teacher", "session output parser reads the username")
    Assert(sessions[1]["id"] = "2", "session output parser reads the session id")
    Assert(sessions[1]["state"] = "Active", "session output parser reads the session state")
    Assert(sessions[2]["user"] = "LABUSER", "session output parser reads subsequent sessions")
}

TestUserNormalization() {
    Assert(LS_SessionGuard.EqualsUser("*DOMAIN\\Teacher", "teacher"), "session guard compares domain-prefixed users case-insensitively")
    Assert(LS_SessionGuard.EqualsUser("LABUSER", "labuser"), "session guard compares local users case-insensitively")
    Assert(!LS_SessionGuard.EqualsUser("teacher", "student"), "session guard distinguishes different users")
}

TestMissingSessionIdCannotBeLoggedOff() {
    result := LS_SessionGuard.LogoffSession(Map("user", "teacher", "id", "", "state", "Active"))
    Assert(!result, "session guard rejects logoff without a session id")
}

TestLogoffAuditIsPersisted() {
    eventSession := Map(
        "user", "teacher",
        "id", "7",
        "state", "Active",
        "guardGrace", 45,
        "guardMessage", "Remote reservation confirmed"
    )

    LS_SessionGuard.RecordLogoffAudit(eventSession, true)

    lines := StrSplit(Trim(FileRead(LAB_STATION_SESSION_AUDIT_FILE, "UTF-8")), "`n")
    event := LS_ParseJson(lines[1])
    state := LS_ServiceState.ReadSection("forced-logoff")
    Assert(event["user"] = "teacher", "session guard audit stores the expelled user")
    Assert(event["sessionId"] = "7", "session guard audit stores the session id")
    Assert(event["force"], "session guard audit stores forced-logoff mode")
    Assert(event["grace"] = 45, "session guard audit stores the grace period")
    Assert(event["message"] = "Remote reservation confirmed", "session guard audit stores the warning message")
    Assert(state["user"] = "teacher" && state["sessionId"] = 7, "service state stores the latest forced logoff")
}

Session(user, sessionName, id, state) {
    return Map("user", user, "session", sessionName, "id", id, "state", state, "idle", "")
}

Assert(condition, message) {
    if (!condition)
        Fail(message)
}

Fail(message) {
    global TEST_FAILURES
    TEST_FAILURES += 1
    LS_TestOutput(message . "`n")
}
