#Requires AutoHotkey v2.0

LS_TestOutput(text) {
    ; AutoHotkey's '*' pseudo-file requires a console handle. Keep test
    ; failures visible in CI, but do not show an error dialog when a test is
    ; launched by double-click from Explorer or an IDE.
    try {
        FileAppend(text, "*", "UTF-8")
        return
    } catch {
        OutputDebug(text)
    }
}
