[CmdletBinding()]
param(
    [string]$DistPath = (Join-Path $PSScriptRoot '..\dist'),
    [string]$OutputPath = ''
)

$ErrorActionPreference = 'Stop'

$executableNames = @(
    'AppControl.exe',
    'LabStation.exe',
    'LabStationPanel.exe',
    'WindowSpy.exe'
)

$distDirectory = (Resolve-Path -LiteralPath $DistPath).Path
if ([string]::IsNullOrWhiteSpace($OutputPath)) {
    $OutputPath = Join-Path $distDirectory 'Lab-Station.zip'
}

$outputDirectory = Split-Path -Parent $OutputPath
if (-not [string]::IsNullOrWhiteSpace($outputDirectory)) {
    New-Item -ItemType Directory -Path $outputDirectory -Force | Out-Null
}

$stagingRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("lab-station-package-" + [Guid]::NewGuid().ToString('N'))
$packageDirectory = Join-Path $stagingRoot 'Lab Station'

try {
    New-Item -ItemType Directory -Path $packageDirectory -Force | Out-Null

    foreach ($name in $executableNames) {
        $source = Join-Path $distDirectory $name
        if (-not (Test-Path -LiteralPath $source -PathType Leaf)) {
            throw "Release executable not found: $source"
        }

        Copy-Item -LiteralPath $source -Destination (Join-Path $packageDirectory $name) -Force
    }

    $logoSource = Join-Path $distDirectory 'img\DecentraLabs.png'
    if (Test-Path -LiteralPath $logoSource -PathType Leaf) {
        $logoDirectory = Join-Path $packageDirectory 'img'
        New-Item -ItemType Directory -Path $logoDirectory -Force | Out-Null
        Copy-Item -LiteralPath $logoSource -Destination (Join-Path $logoDirectory 'DecentraLabs.png') -Force
    }

    if (Test-Path -LiteralPath $OutputPath) {
        Remove-Item -LiteralPath $OutputPath -Force
    }

    Compress-Archive -LiteralPath $packageDirectory -DestinationPath $OutputPath -CompressionLevel Optimal

    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archive = [System.IO.Compression.ZipFile]::OpenRead($OutputPath)
    try {
        $entryNames = @($archive.Entries | ForEach-Object { $_.FullName -replace '\\', '/' })
        foreach ($name in $executableNames) {
            $expectedEntry = "Lab Station/$name"
            if ($entryNames -notcontains $expectedEntry) {
                throw "Release package is missing $expectedEntry"
            }
        }
    } finally {
        $archive.Dispose()
    }

    Write-Host "Created release package: $OutputPath"
} finally {
    if (Test-Path -LiteralPath $stagingRoot) {
        Remove-Item -LiteralPath $stagingRoot -Recurse -Force
    }
}
