#Requires AutoHotkey v2.0
#Include ..\core\Json.ahk
#Include ..\core\Config.ahk
#Include ..\system\WinRM.ahk

errors := []

AssertContains(path, source, expected, &errors) {
    if !InStr(source, expected)
        errors.Push(path . ": missing contract fragment: " . expected)
}

AssertNotContains(path, source, unexpected, &errors) {
    if InStr(source, unexpected)
        errors.Push(path . ": unexpected contract fragment: " . unexpected)
}

try {
    json := LS_ToJson(Map(
        "path", "C:\Lab Station\status.json",
        "quote", "a" . Chr(34) . "b",
        "newline", "line`nnext"
    ))
    parsed := LS_ParseJson(json)
    if (parsed["path"] != "C:\Lab Station\status.json")
        errors.Push("json: Windows paths must round-trip through the station serializer")
    if (parsed["quote"] != "a" . Chr(34) . "b")
        errors.Push("json: quotes must round-trip through the station serializer")
    if (parsed["newline"] != "line`nnext")
        errors.Push("json: control characters must round-trip through the station serializer")
    listJson := LS_ToJson(Map("items", [Map("id", "1")], "textOne", "1"))
    if !InStr(listJson, '"items":[{')
        errors.Push("json: AHK arrays must serialize as JSON arrays")
    listParsed := LS_ParseJson(listJson)
    if (Type(listParsed["items"]) != "Array" || Type(listParsed["items"][1]["id"]) != "String")
        errors.Push("json: string values and arrays must retain their JSON types")
} catch as e {
    errors.Push("json: serialization contract threw - " . e.Message)
}

try {
    winrmSource := FileRead(A_ScriptDir . "\..\system\WinRM.ahk", "UTF-8")
    configureScript := LS_WinRM.BuildConfigureScript("LabGatewaySvc", "test-password")
    AssertContains("winrm", winrmSource, "HttpsPort := 5986", &errors)
    AssertContains("winrm", configureScript, "Transport=HTTPS", &errors)
    AssertContains("winrm", configureScript, "5986", &errors)
    AssertContains("winrm", configureScript, "AllowUnencrypted", &errors)
    AssertContains("winrm", configureScript, "Certificate", &errors)
    AssertContains("winrm", configureScript, "LabStation-WinRM-HTTPS", &errors)
    AssertNotContains("winrm", configureScript, "localport=5985", &errors)
} catch as e {
    errors.Push("winrm: contract threw - " . e.Message)
}

try {
    statusSource := FileRead(A_ScriptDir . "\..\diagnostics\Status.ahk", "UTF-8")
    AssertContains("status", statusSource, 'summary["ready"]', &errors)
} catch as e {
    errors.Push("status: contract threw - " . e.Message)
}

try {
    entrypoint := FileRead(A_ScriptDir . "\..\LabStation.ahk", "UTF-8")
    AssertContains("cli", entrypoint, "LS_ShowMessage", &errors)
    AssertContains("cli", entrypoint, "ExitApp(commandExitCode)", &errors)
} catch as e {
    errors.Push("cli: contract threw - " . e.Message)
}

try {
    headless := LS_IsHeadlessSession()
    if (headless != true && headless != false)
        errors.Push("cli: headless-session detector must return a boolean")
} catch as e {
    errors.Push("cli: headless-session detector threw - " . e.Message)
}

if (errors.Length > 0) {
    for _, message in errors
        FileAppend(message . "`n", "*")
    ExitApp(1)
}

FileAppend("IntegrationContractTests passed`n", "*")
ExitApp(0)
