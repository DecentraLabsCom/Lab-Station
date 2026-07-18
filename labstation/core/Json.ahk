; ============================================================================
; Lab Station - JSON helpers
; ============================================================================
#Requires AutoHotkey v2.0

LS_ParseJson(jsonText) {
    parser := LS_JsonParser(jsonText)
    return parser.Parse()
}

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
    if (Type(value) = "String") {
        if (value == "null")
            return "null"
        return LS_JsonEscape(value)
    }
    if (value == true)
        return "true"
    if (value == false)
        return "false"
    if (IsNumber(value))
        return value
    return LS_JsonEscape(value)
}

LS_IsArray(obj) {
    if !IsObject(obj)
        return false
    expected := 1
    for key, value in obj {
        if (key != expected)
            return false
        expected += 1
    }
    return true
}

LS_JsonEscape(value) {
    ; AHK does not use C-style backslash escapes in string literals. Build
    ; valid JSON escapes explicitly so Windows paths and command output can be
    ; consumed by Python/JavaScript clients.
    value := StrReplace(value, "\", "\\")
    value := StrReplace(value, '"', '\"')
    value := StrReplace(value, Chr(8), "\b")
    value := StrReplace(value, Chr(12), "\f")
    value := StrReplace(value, Chr(10), "\n")
    value := StrReplace(value, Chr(13), "\r")
    value := StrReplace(value, Chr(9), "\t")
    return '"' . value . '"'
}

LS_WriteJson(path, value) {
    json := LS_ToJson(value)
    SplitPath(path, &fileName, &directory)
    if (directory != "")
        EnsureDir(directory)
    temporaryPath := path . ".tmp-" . A_TickCount . "-" . Random(1000, 9999)
    try {
        FileAppend(json, temporaryPath, "UTF-8")
        FileMove(temporaryPath, path, true)
    } catch as e {
        try FileDelete(temporaryPath)
        throw e
    }
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

class LS_JsonParser {
    __New(text) {
        this._text := text
        this._len := StrLen(text)
        this._pos := 1
    }

    Parse() {
        value := this._ParseValue()
        this._SkipWhitespace()
        if (this._pos <= this._len)
            throw Error("Invalid JSON: trailing content at position " . this._pos)
        return value
    }

    _ParseValue() {
        this._SkipWhitespace()
        ch := this._Peek()
        if (ch = "")
            throw Error("Invalid JSON: unexpected end of input")

        switch ch {
            case "{":
                return this._ParseObject()
            case "[":
                return this._ParseArray()
            case '"':
                return this._ParseString()
            case "t":
                this._ExpectLiteral("true")
                return true
            case "f":
                this._ExpectLiteral("false")
                return false
            case "n":
                this._ExpectLiteral("null")
                return "null"
            default:
                if RegExMatch(ch, "[0-9\-]")
                    return this._ParseNumber()
                throw Error("Invalid JSON: unexpected token at position " . this._pos)
        }
    }

    _ParseObject() {
        obj := Map()
        this._Expect("{")
        this._SkipWhitespace()
        if (this._Peek() = "}") {
            this._Consume()
            return obj
        }

        loop {
            this._SkipWhitespace()
            key := this._ParseString()
            this._SkipWhitespace()
            this._Expect(":")
            value := this._ParseValue()
            obj[key] := value
            this._SkipWhitespace()
            ch := this._Peek()
            if (ch = "}") {
                this._Consume()
                break
            }
            this._Expect(",")
        }

        return obj
    }

    _ParseArray() {
        arr := []
        this._Expect("[")
        this._SkipWhitespace()
        if (this._Peek() = "]") {
            this._Consume()
            return arr
        }

        loop {
            arr.Push(this._ParseValue())
            this._SkipWhitespace()
            ch := this._Peek()
            if (ch = "]") {
                this._Consume()
                break
            }
            this._Expect(",")
        }

        return arr
    }

    _ParseString() {
        out := ""
        this._Expect('"')

        while (this._pos <= this._len) {
            ch := this._Consume()
            if (ch = '"')
                return out

            if (ch != "\") {
                out .= ch
                continue
            }

            esc := this._Consume()
            switch esc {
                case '"', "\", "/":
                    out .= esc
                case "b":
                    out .= Chr(8)
                case "f":
                    out .= Chr(12)
                case "n":
                    out .= "`n"
                case "r":
                    out .= "`r"
                case "t":
                    out .= "`t"
                case "u":
                    hex := SubStr(this._text, this._pos, 4)
                    if (StrLen(hex) != 4 || !RegExMatch(hex, "^[0-9A-Fa-f]{4}$"))
                        throw Error("Invalid JSON: invalid unicode escape at position " . this._pos)
                    out .= Chr("0x" . hex)
                    this._pos += 4
                default:
                    throw Error("Invalid JSON: invalid escape at position " . this._pos)
            }
        }

        throw Error("Invalid JSON: unterminated string")
    }

    _ParseNumber() {
        remaining := SubStr(this._text, this._pos)
        if !RegExMatch(remaining, "^-?(?:0|[1-9]\d*)(?:\.\d+)?(?:[eE][+\-]?\d+)?", &match)
            throw Error("Invalid JSON: invalid number at position " . this._pos)
        token := match[0]
        this._pos += StrLen(token)
        return token + 0
    }

    _ExpectLiteral(literal) {
        actual := SubStr(this._text, this._pos, StrLen(literal))
        if (actual != literal)
            throw Error("Invalid JSON: expected '" . literal . "' at position " . this._pos)
        this._pos += StrLen(literal)
    }

    _Expect(expectedChar) {
        actual := this._Consume()
        if (actual != expectedChar)
            throw Error("Invalid JSON: expected '" . expectedChar . "' at position " . this._pos)
    }

    _Peek() {
        if (this._pos > this._len)
            return ""
        return SubStr(this._text, this._pos, 1)
    }

    _Consume() {
        if (this._pos > this._len)
            throw Error("Invalid JSON: unexpected end of input")
        ch := SubStr(this._text, this._pos, 1)
        this._pos += 1
        return ch
    }

    _SkipWhitespace() {
        while (this._pos <= this._len) {
            ch := SubStr(this._text, this._pos, 1)
            if (ch != " " && ch != "`t" && ch != "`r" && ch != "`n")
                break
            this._pos += 1
        }
    }
}
