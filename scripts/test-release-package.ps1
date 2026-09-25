$ErrorActionPreference = 'Stop'

$testRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("lab-station-release-test-" + [Guid]::NewGuid().ToString('N'))
$distPath = Join-Path $testRoot 'dist'
$outputPath = Join-Path $distPath 'Lab-Station.zip'
$packageScript = Join-Path $PSScriptRoot 'package-release.ps1'
$expectedExecutables = @(
    'LabStation.exe',
    'LabStationPanel.exe',
    'WindowSpy.exe'
)

function Assert-Condition {
    param(
        [bool]$Condition,
        [string]$Message
    )

    if (-not $Condition) {
        throw $Message
    }
}

try {
    New-Item -ItemType Directory -Path $distPath -Force | Out-Null
    foreach ($name in $expectedExecutables) {
        Set-Content -LiteralPath (Join-Path $distPath $name) -Value "test-$name" -NoNewline
    }
    Set-Content -LiteralPath (Join-Path $distPath 'AppControl.exe') -Value 'test-AppControl.exe' -NoNewline

    $logoDir = Join-Path $distPath 'img'
    New-Item -ItemType Directory -Path $logoDir -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $logoDir 'DecentraLabs.png') -Value 'test-logo' -NoNewline

    & $packageScript -DistPath $distPath -OutputPath $outputPath
    Assert-Condition $? 'Release package script failed.'
    Assert-Condition (Test-Path -LiteralPath $outputPath) 'Release package ZIP was not created.'

    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archive = [System.IO.Compression.ZipFile]::OpenRead($outputPath)
    try {
        $entryNames = @($archive.Entries | ForEach-Object { $_.FullName -replace '\\', '/' })
        foreach ($name in $expectedExecutables) {
            Assert-Condition ($entryNames -contains "Lab Station/$name") "Missing packaged executable: $name"
            Assert-Condition (-not ($entryNames -contains $name)) "Executable leaked outside Lab Station/: $name"
        }
        Assert-Condition ($entryNames -contains 'Lab Station/remote-app/AppControl.exe') 'Missing packaged Remote App launcher.'
        Assert-Condition (-not ($entryNames -contains 'Lab Station/AppControl.exe')) 'AppControl leaked outside remote-app/.'
        Assert-Condition ($entryNames -contains 'Lab Station/img/DecentraLabs.png') 'Missing packaged logo.'
    } finally {
        $archive.Dispose()
    }

    Write-Host 'Release package layout test passed.' -ForegroundColor Green
} finally {
    if (Test-Path -LiteralPath $testRoot) {
        Remove-Item -LiteralPath $testRoot -Recurse -Force
    }
}
