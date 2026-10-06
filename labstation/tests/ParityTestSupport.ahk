#Requires AutoHotkey v2.0

LS_TestLoadParityMatrix() {
    path := A_ScriptDir . "\..\..\contracts\station\v3\test-parity.json"
    return LS_ParseJson(FileRead(path, "UTF-8"))
}

LS_TestArrayContains(values, expected) {
    for value in values {
        if (value = expected)
            return true
    }
    return false
}
