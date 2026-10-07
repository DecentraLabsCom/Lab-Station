#Requires AutoHotkey v2.0
#Include TestSupport.ahk
#Include ..\core\Json.ahk

errors := []
validNumbers := [
    ["0", 0],
    ["-0", 0],
    ["1", 1],
    ["-42", -42],
    ["1.25", 1.25],
    ["-0.125", -0.125],
    ["1e3", 1000],
    ["1E+3", 1000],
    ["1e-3", 0.001],
    ["-2.5E+2", -250]
]

for _, testCase in validNumbers {
    try {
        actual := LS_ParseJson(testCase[1])
        if (Abs(actual - testCase[2]) > 0.000001)
            errors.Push("valid JSON number parsed incorrectly: " . testCase[1])
    } catch as err {
        errors.Push("valid JSON number was rejected: " . testCase[1] . " - " . err.Message)
    }
}

invalidNumbers := ["", "-", "+1", ".5", "01", "-01", "1.", "1e", "1e+", "--1", "NaN", "Infinity"]
for _, token in invalidNumbers {
    rejected := false
    try {
        LS_ParseJson(token)
    } catch {
        rejected := true
    }
    if !rejected
        errors.Push("invalid JSON number was accepted: " . token)
}

try {
    parsed := LS_ParseJson('{"measurement":-1.2e+3,"samples":[0,2]}')
    if (Abs(parsed["measurement"] + 1200) > 0.000001)
        errors.Push("numbers in nested objects must be parsed")
    if (parsed["samples"][2] != 2)
        errors.Push("numbers in nested arrays must be parsed")
} catch as err {
    errors.Push("nested numeric JSON values could not be parsed: " . err.Message)
}

temporaryRoot := A_Temp "\LabStationJsonTests-" A_TickCount "-" Random(1000, 9999)
temporaryPath := temporaryRoot "\nested\status.json"
try {
    LS_WriteJson(temporaryPath, Map("value", 42))
    if !FileExist(temporaryPath) {
        errors.Push("JSON writer did not create the target file")
    } else {
        written := LS_ParseJson(FileRead(temporaryPath, "UTF-8"))
        if (written["value"] != 42)
            errors.Push("JSON writer produced an unreadable payload")
    }
} catch as err {
    errors.Push("JSON writer failed for a new nested directory: " . err.Message)
}
if DirExist(temporaryRoot)
    DirDelete(temporaryRoot, true)

if (errors.Length > 0) {
    for _, message in errors
        LS_TestOutput(message . "`n")
    ExitApp(1)
}

LS_TestOutput("JsonParserTests passed`n")
ExitApp(0)
