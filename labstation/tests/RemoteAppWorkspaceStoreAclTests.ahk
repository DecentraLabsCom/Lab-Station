#Requires AutoHotkey v2.0
#Include ..\system\RemoteAppWorkspaceStore.ahk

global TEST_FAILURES := 0

try {
    script := LS_RemoteAppWorkspaceStore.BuildEnsureScript(
        "C:\ProgramData\DecentraLabs\Lab Station\RemoteApp\workspaces"
    )
    TestContains(script,
        "Get-ChildItem -LiteralPath $workspaceRoot -Filter '*.json' -File -Recurse",
        "ACL preparation enumerates existing workspace manifests")
    TestContains(script,
        "icacls.exe $manifest.FullName /grant:r '*S-1-5-32-545:(R)' /C /Q",
        "ACL preparation explicitly grants BUILTIN\Users read access to each manifest")
} catch as e {
    TestFail("Unexpected exception while checking workspace ACL preparation", e.Message)
}

OutputDebug(Format("[RemoteAppWorkspaceStoreAclTests] {1} failures", TEST_FAILURES))
ExitApp(TEST_FAILURES ? 1 : 0)

TestContains(value, expected, description) {
    if (!InStr(value, expected))
        TestFail(description, "Expected source to contain: " . expected)
}

TestFail(description, detail := "") {
    global TEST_FAILURES
    TEST_FAILURES += 1
    OutputDebug("[RemoteAppWorkspaceStoreAclTests] FAIL: " . description . (detail != "" ? " - " . detail : ""))
}
