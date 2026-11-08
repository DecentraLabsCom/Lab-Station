param(
    [Parameter(Mandatory = $true)][string]$AutoHotkeyExecutable,
    [Parameter(Mandatory = $true)][string]$FakeAppScript,
    [Parameter(Mandatory = $true)][string]$SplashTitle,
    [Parameter(Mandatory = $true)][string]$MainTitle,
    [Parameter(Mandatory = $true)][int]$MainDelayMilliseconds
)

$ErrorActionPreference = 'Stop'

function Start-FakeAppWindow {
    param(
        [string]$Title,
        [int]$LifetimeSeconds,
        [bool]$IsToolWindow
    )

    $childArguments = '"{0}" --class AutoHotkeyGUI --title "{1}" --lifetime {2}' -f `
        $FakeAppScript, $Title, $LifetimeSeconds
    if ($IsToolWindow) {
        $childArguments += ' --toolwindow=true'
    }
    Start-Process -FilePath $AutoHotkeyExecutable -ArgumentList $childArguments -WindowStyle Hidden | Out-Null
}

Start-FakeAppWindow -Title $SplashTitle -LifetimeSeconds 2 -IsToolWindow $true
Start-Sleep -Milliseconds $MainDelayMilliseconds
Start-FakeAppWindow -Title $MainTitle -LifetimeSeconds 120 -IsToolWindow $false
