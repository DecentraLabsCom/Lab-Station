#Requires AutoHotkey v2.0
#SingleInstance Force
#Include TestSupport.ahk
#Include ..\core\Config.ahk
#Include ..\core\Logger.ahk
#Include ..\core\Json.ahk

#Include ..\service\CommandQueue.ahk

global TEST_FAILURES := 0
global TEST_ROOT := A_Temp "\LabStation-CommandQueueTests-" A_TickCount
global ORIGINAL_COMMAND_DIR := LAB_STATION_COMMAND_DIR
global ORIGINAL_COMMAND_INBOX := LAB_STATION_COMMAND_INBOX
global ORIGINAL_COMMAND_PROCESSED := LAB_STATION_COMMAND_PROCESSED_DIR
global ORIGINAL_COMMAND_RESULTS := LAB_STATION_COMMAND_RESULTS_DIR

LAB_STATION_COMMAND_DIR := TEST_ROOT "\commands"
LAB_STATION_COMMAND_INBOX := LAB_STATION_COMMAND_DIR "\inbox"
LAB_STATION_COMMAND_PROCESSED_DIR := LAB_STATION_COMMAND_DIR "\processed"
LAB_STATION_COMMAND_RESULTS_DIR := LAB_STATION_COMMAND_DIR "\results"
DirCreate(LAB_STATION_COMMAND_INBOX)
DirCreate(LAB_STATION_COMMAND_PROCESSED_DIR)
DirCreate(LAB_STATION_COMMAND_RESULTS_DIR)

RunCommandQueueTests()

class RecordingCommandQueue extends LS_CommandQueue {
    static dispatched := []

    static Reset() {
        this.dispatched := []
        this.Initialized := false
        ResetCommandDirectories()
    }

    static Dispatch(cmd) {
        this.dispatched.Push(cmd)
        return this.ResultState(true, 0, "stub executed")
    }
}

RunCommandQueueTests() {
    global ORIGINAL_COMMAND_DIR, ORIGINAL_COMMAND_INBOX, ORIGINAL_COMMAND_PROCESSED, ORIGINAL_COMMAND_RESULTS
    global LAB_STATION_COMMAND_DIR, LAB_STATION_COMMAND_INBOX, LAB_STATION_COMMAND_PROCESSED_DIR, LAB_STATION_COMMAND_RESULTS_DIR, TEST_ROOT

    try {
        TestValidCommandProducesResultAndArchive()
        TestMissingNameProducesHardFailureAndArchive()
        TestInvalidNumericOptionProducesHardFailureAndArchive()
        TestInvalidBooleanOptionProducesHardFailureAndArchive()
        TestExtractOptionsParsesSupportedValues()
        TestUnsupportedCommandProducesHardFailure()
    } catch as err {
        CQ_Fail("Unhandled command-queue test exception: " . err.Message)
    }

    LAB_STATION_COMMAND_DIR := ORIGINAL_COMMAND_DIR
    LAB_STATION_COMMAND_INBOX := ORIGINAL_COMMAND_INBOX
    LAB_STATION_COMMAND_PROCESSED_DIR := ORIGINAL_COMMAND_PROCESSED
    LAB_STATION_COMMAND_RESULTS_DIR := ORIGINAL_COMMAND_RESULTS
    try DirDelete(TEST_ROOT, true)

    if (TEST_FAILURES > 0) {
        LS_TestOutput("CommandQueueTests failed: " . TEST_FAILURES . " failure(s)`n")
        ExitApp(1)
    }

    LS_TestOutput("CommandQueueTests passed`n")
    ExitApp(0)
}

TestValidCommandProducesResultAndArchive() {
    RecordingCommandQueue.Reset()

    path := WriteCommand("valid.ini", "[Command]`nid=job/42`nname=Probe`nuser=LABUSER`nreboot=yes`nreboot-timeout=15`nreason=Reservation completed`n")
    processed := RecordingCommandQueue.ProcessPending()

    CQ_Assert(processed = 1, "valid command is counted as processed")
    CQ_Assert(RecordingCommandQueue.dispatched.Length = 1, "valid command is dispatched once")
    CQ_Assert(RecordingCommandQueue.dispatched[1]["name"] = "probe", "command name is normalized")
    CQ_Assert(RecordingCommandQueue.dispatched[1]["options"]["reboot"], "reboot option reaches dispatcher")
    CQ_Assert(RecordingCommandQueue.dispatched[1]["options"]["rebootTimeout"] = 15, "reboot timeout reaches dispatcher")

    resultPath := LAB_STATION_COMMAND_RESULTS_DIR "\job_42.json"
    CQ_Assert(FileExist(resultPath), "valid command writes a sanitized result filename")
    result := LS_ParseJson(FileRead(resultPath, "UTF-8"))
    CQ_Assert(result["id"] = "job/42", "result preserves the original command id")
    CQ_Assert(result["command"] = "probe", "result contains normalized command name")
    CQ_Assert(result["success"], "result contains dispatcher success")
    CQ_Assert(result["options"]["reason"] = "Reservation completed", "result contains command options")
    CQ_Assert(!FileExist(path), "processed command is removed from inbox")
    CQ_Assert(FindArchivedFile("job_42-valid.ini"), "processed command is archived with sanitized id")
}

TestMissingNameProducesHardFailureAndArchive() {
    RecordingCommandQueue.Reset()

    path := WriteCommand("missing-name.ini", "[Command]`nid=missing-name`nuser=LABUSER`n")
    processed := RecordingCommandQueue.ProcessPending()

    CQ_Assert(processed = 1, "missing-name command is counted as processed")
    CQ_Assert(RecordingCommandQueue.dispatched.Length = 0, "missing-name command is not dispatched")

    resultPath := LAB_STATION_COMMAND_RESULTS_DIR "\missing-name.json"
    CQ_Assert(FileExist(resultPath), "missing-name command writes a result")
    result := LS_ParseJson(FileRead(resultPath, "UTF-8"))
    CQ_Assert(!result["success"], "missing-name result is unsuccessful")
    CQ_Assert(result["exitCode"] = 2, "missing-name result is a hard failure")
    CQ_Assert(InStr(result["message"], "Command name missing") > 0, "missing-name result explains the failure")
    CQ_Assert(!FileExist(path), "missing-name command is removed from inbox")
    CQ_Assert(FindArchivedFile("missing-name-missing-name.ini"), "missing-name command is archived")
}

TestInvalidNumericOptionProducesHardFailureAndArchive() {
    RecordingCommandQueue.Reset()

    path := WriteCommand("invalid-number.ini", "[Command]`nid=bad/id`nname=probe`nreboot-timeout=not-a-number`n")
    processed := RecordingCommandQueue.ProcessPending()

    CQ_Assert(processed = 1, "invalid-option command is counted as processed")
    CQ_Assert(RecordingCommandQueue.dispatched.Length = 0, "invalid-option command is not dispatched")

    resultPath := LAB_STATION_COMMAND_RESULTS_DIR "\bad_id.json"
    CQ_Assert(FileExist(resultPath), "invalid-option command writes a sanitized result filename")
    result := LS_ParseJson(FileRead(resultPath, "UTF-8"))
    CQ_Assert(!result["success"], "invalid-option result is unsuccessful")
    CQ_Assert(result["exitCode"] = 2, "invalid-option result is a hard failure")
    CQ_Assert(InStr(result["message"], "reboot-timeout") > 0, "invalid-option result identifies the invalid option")
    CQ_Assert(!FileExist(path), "invalid-option command is removed from inbox")
    CQ_Assert(FindArchivedFile("bad_id-invalid-number.ini"), "invalid-option command is archived")
}

TestInvalidBooleanOptionProducesHardFailureAndArchive() {
    RecordingCommandQueue.Reset()

    path := WriteCommand("invalid-boolean.ini", "[Command]`nid=bad-bool`nname=probe`nforce=maybe`n")
    processed := RecordingCommandQueue.ProcessPending()

    CQ_Assert(processed = 1, "invalid-boolean command is counted as processed")
    CQ_Assert(RecordingCommandQueue.dispatched.Length = 0, "invalid-boolean command is not dispatched")

    resultPath := LAB_STATION_COMMAND_RESULTS_DIR "\bad-bool.json"
    CQ_Assert(FileExist(resultPath), "invalid-boolean command writes a result")
    result := LS_ParseJson(FileRead(resultPath, "UTF-8"))
    CQ_Assert(!result["success"], "invalid-boolean result is unsuccessful")
    CQ_Assert(result["exitCode"] = 2, "invalid-boolean result is a hard failure")
    CQ_Assert(InStr(result["message"], "force") > 0, "invalid-boolean result identifies the invalid option")
    CQ_Assert(!FileExist(path), "invalid-boolean command is removed from inbox")
    CQ_Assert(FindArchivedFile("bad-bool-invalid-boolean.ini"), "invalid-boolean command is archived")
}

TestExtractOptionsParsesSupportedValues() {
    parsed := Map(
        "user", "LABUSER",
        "reboot", "yes",
        "reboot-timeout", "15",
        "path", "C:\\LabStation\\status.json",
        "timeout", "20",
        "reason", "Reservation completed",
        "delay", "60",
        "force", "no",
        "skip-wake-check", "on",
        "repair-wake", "off",
        "require-wake", "true",
        "guard", "false",
        "guard-grace", "90",
        "guard-message", "Please save your work",
        "guard-notify", "1",
        "grace", "45",
        "message", "Remote reservation",
        "notify", "0"
    )

    options := LS_CommandQueue.ExtractOptions(parsed)

    CQ_Assert(options["user"] = "LABUSER", "user option is parsed")
    CQ_Assert(options["reboot"], "reboot=true is parsed")
    CQ_Assert(options["rebootTimeout"] = 15, "reboot timeout is parsed")
    CQ_Assert(options["path"] = "C:\\LabStation\\status.json", "path option is parsed")
    CQ_Assert(options["timeout"] = 20, "timeout is parsed")
    CQ_Assert(options["delay"] = 60, "delay is parsed")
    CQ_Assert(!options["force"], "force=false is parsed")
    CQ_Assert(options["skipWakeCheck"], "skip-wake-check=true is parsed")
    CQ_Assert(!options["repairWake"], "repair-wake=false is parsed")
    CQ_Assert(options["failOnWakeIssues"], "require-wake=true is parsed")
    CQ_Assert(!options["guard"], "guard=false is parsed")
    CQ_Assert(options["guardGrace"] = 90, "guard grace is parsed")
    CQ_Assert(options["guardMessage"] = "Please save your work", "guard message is parsed")
    CQ_Assert(options["guardNotify"], "guard-notify=true is parsed")
    CQ_Assert(options["grace"] = 45, "grace is parsed")
    CQ_Assert(options["message"] = "Remote reservation", "message is parsed")
    CQ_Assert(!options["notify"], "notify=false is parsed")
}

TestUnsupportedCommandProducesHardFailure() {
    command := Map("name", "unsupported", "options", Map())
    result := LS_CommandQueue.Dispatch(command)

    CQ_Assert(!result["success"], "unsupported command is unsuccessful")
    CQ_Assert(result["exitCode"] = 2, "unsupported command is a hard failure")
    CQ_Assert(InStr(result["message"], "unsupported") > 0, "unsupported command names the command")
}

WriteCommand(fileName, contents) {
    path := LAB_STATION_COMMAND_INBOX "\" fileName
    FileAppend(contents, path, "UTF-8")
    return path
}

ResetCommandDirectories() {
    for path in [LAB_STATION_COMMAND_INBOX, LAB_STATION_COMMAND_PROCESSED_DIR, LAB_STATION_COMMAND_RESULTS_DIR] {
        try DirDelete(path, true)
        DirCreate(path)
    }
}

FindArchivedFile(expectedName) {
    Loop Files, LAB_STATION_COMMAND_PROCESSED_DIR "\*" expectedName {
        return true
    }
    return false
}

CQ_Assert(condition, message) {
    if (!condition)
    CQ_Fail(message)
}

CQ_Fail(message) {
    global TEST_FAILURES
    TEST_FAILURES += 1
    LS_TestOutput(message . "`n")
}
