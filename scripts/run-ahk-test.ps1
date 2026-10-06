[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [string]$TestPath
)

$ErrorActionPreference = 'Stop'
$ahkPath = $env:AHK_EXE
if (-not $ahkPath -or -not (Test-Path -LiteralPath $ahkPath)) {
    throw 'AHK_EXE must point to an AutoHotkey v2 executable.'
}

$resolvedTest = (Resolve-Path -LiteralPath $TestPath).Path
$argumentList = @('/ErrorStdOut', ('"{0}"' -f $resolvedTest))
$timeoutSeconds = 120
$process = Start-Process -FilePath $ahkPath -ArgumentList $argumentList -PassThru -NoNewWindow
if (-not $process.WaitForExit($timeoutSeconds * 1000)) {
    & taskkill.exe /PID $process.Id /T /F | Out-Null
    throw "AutoHotkey test timed out after $timeoutSeconds seconds: $resolvedTest"
}

$testExitCode = [int]$process.ExitCode
if ($testExitCode -ne 0) {
    Write-Error "AutoHotkey test failed with exit code $testExitCode`: $resolvedTest"
    exit $testExitCode
}

exit 0
