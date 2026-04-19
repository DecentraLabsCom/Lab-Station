; ============================================================================
; Lab Station - JSON helpers
; ============================================================================
#Requires AutoHotkey v2.0

LS_ToJson(value) {
    if IsObject(value) {
        if LS_IsArray(value) {
            parts := []
            for item in value {
                parts.Push(LS_ToJson(item))
            }
            return "[" . LS_StrJoin(parts, ",") . "]"
        } else {
            parts := []
            for key, val in value {
                parts.Push(LS_JsonEscape(key) . ":" . LS_ToJson(val))
            }
            return "{" . LS_StrJoin(parts, ",") . "}"
        }
    }
    if (value = true)
        return "true"
    if (value = false)
        return "false"
    if (value = "null")
        return "null"
    if (IsNumber(value))
        return value
    return LS_JsonEscape(value)
}

LS_IsArray(obj) {
    if !IsObject(obj)
        return false
    expected := 1
    for key in obj {
        if (key != expected)
            return false
        expected += 1
    }
    return true
}

LS_JsonEscape(value) {
    value := StrReplace(value, "\\", "\\\\")
    value := StrReplace(value, '"', '\\"')
    value := StrReplace(value, "\n", "\\n")
    value := StrReplace(value, "\r", "\\r")
    value := StrReplace(value, "\t", "\\t")
    return '"' . value . '"'
}

LS_WriteJson(path, value) {
    json := LS_ToJson(value)
    try FileDelete(path)
    FileAppend(json, path, "UTF-8")
}

LS_StrJoin(parts, delimiter := ",") {
    if (parts.Length = 0)
        return ""
    output := parts[1]
    loop parts.Length - 1 {
        output .= delimiter . parts[A_Index + 1]
    }
    return output
}
