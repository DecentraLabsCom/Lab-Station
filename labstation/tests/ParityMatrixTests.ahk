#Requires AutoHotkey v2.0
#Include TestSupport.ahk
#Include ..\core\Json.ahk
#Include ParityTestSupport.ahk

global TEST_FAILURES := 0

RunParityMatrixTests()

RunParityMatrixTests() {
    global TEST_FAILURES
    errors := []
    try {
        matrix := LS_TestLoadParityMatrix()
        if (matrix["version"] != 1)
            errors.Push("portable test matrix version must be 1")
        if (matrix["portableStatus"]["schemaVersion"] != "3.0.0")
            errors.Push("portable test matrix must target Station Contract v3")

        seen := Map()
        repositoryRoot := A_ScriptDir . "\..\.."
        for _, scenario in matrix["sharedScenarios"] {
            id := scenario["id"]
            if (id = "" || seen.Has(id)) {
                errors.Push("portable scenario ids must be present and unique: " . id)
                continue
            }
            seen[id] := true
            if (!scenario.Has("windows") || !scenario.Has("linux")) {
                errors.Push(id . ": both platform mappings are required")
                continue
            }
            windows := scenario["windows"]
            linux := scenario["linux"]
            if (windows["file"] = "" || windows["test"] = "" || linux["file"] = "" || linux["test"] = "") {
                errors.Push(id . ": both platform test references must be complete")
                continue
            }
            windowsPath := repositoryRoot . "\" . StrReplace(windows["file"], "/", "\")
            if !FileExist(windowsPath) {
                errors.Push(id . ": Windows test file does not exist: " . windows["file"])
                continue
            }
            if !InStr(FileRead(windowsPath, "UTF-8"), windows["test"] . "(")
                errors.Push(id . ": Windows test function does not exist: " . windows["test"])
        }
        if (matrix["sharedScenarios"].Length = 0)
            errors.Push("portable test matrix must contain shared scenarios")
    } catch as err {
        errors.Push("portable test matrix could not be checked: " . err.Message)
    }

    if (errors.Length > 0) {
        for _, message in errors
            LS_TestOutput(message . "`n")
        TEST_FAILURES := errors.Length
    }
    if (TEST_FAILURES > 0) {
        LS_TestOutput("ParityMatrixTests failed: " . TEST_FAILURES . " failure(s)`n")
        ExitApp(1)
    }
    LS_TestOutput("ParityMatrixTests passed`n")
    ExitApp(0)
}
