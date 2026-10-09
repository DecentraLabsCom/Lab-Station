[CmdletBinding()]
param(
    [string]$DistPath = (Join-Path $PSScriptRoot '..\dist'),
    [string]$OutputPath = ''
)

$ErrorActionPreference = 'Stop'

$executableNames = @(
    'LabStation.exe',
    'LabStationPanel.exe',
    'WindowSpy.exe'
)

$distDirectory = (Resolve-Path -LiteralPath $DistPath).Path
$repositoryRoot = Split-Path -Parent $PSScriptRoot
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

    $appControlSource = Join-Path $distDirectory 'AppControl.exe'
    if (-not (Test-Path -LiteralPath $appControlSource -PathType Leaf)) {
        throw "Release executable not found: $appControlSource"
    }
    $remoteAppDirectory = Join-Path $packageDirectory 'remote-app'
    New-Item -ItemType Directory -Path $remoteAppDirectory -Force | Out-Null
    Copy-Item -LiteralPath $appControlSource -Destination (Join-Path $remoteAppDirectory 'AppControl.exe') -Force

    $logoSource = Join-Path $distDirectory 'img\DecentraLabs.png'
    if (Test-Path -LiteralPath $logoSource -PathType Leaf) {
        $logoDirectory = Join-Path $packageDirectory 'img'
        New-Item -ItemType Directory -Path $logoDirectory -Force | Out-Null
        Copy-Item -LiteralPath $logoSource -Destination (Join-Path $logoDirectory 'DecentraLabs.png') -Force
    }

    # Ship the runtime sidecar source, but never station FMU data or test files.
    $fmuExecutorSourceDirectory = Join-Path $repositoryRoot 'fmu-executor'
    if (-not (Test-Path -LiteralPath $fmuExecutorSourceDirectory -PathType Container)) {
        throw "FMU Executor source directory not found: $fmuExecutorSourceDirectory"
    }

    $fmuExecutorPackageDirectory = Join-Path $packageDirectory 'fmu-executor'
    New-Item -ItemType Directory -Path $fmuExecutorPackageDirectory -Force | Out-Null

    foreach ($name in @('README.md', 'requirements.txt')) {
        $source = Join-Path $fmuExecutorSourceDirectory $name
        if (-not (Test-Path -LiteralPath $source -PathType Leaf)) {
            throw "FMU Executor release file not found: $source"
        }
        Copy-Item -LiteralPath $source -Destination (Join-Path $fmuExecutorPackageDirectory $name) -Force
    }

    # Preserve release/source metadata when the checkout provides it.
    foreach ($name in @('VERSION', 'SOURCE.lock.json', 'pyproject.toml')) {
        $source = Join-Path $fmuExecutorSourceDirectory $name
        if (Test-Path -LiteralPath $source -PathType Leaf) {
            Copy-Item -LiteralPath $source -Destination (Join-Path $fmuExecutorPackageDirectory $name) -Force
        }
    }

    $appSourceDirectory = Join-Path $fmuExecutorSourceDirectory 'app'
    if (-not (Test-Path -LiteralPath $appSourceDirectory -PathType Container)) {
        throw "FMU Executor app directory not found: $appSourceDirectory"
    }

    foreach ($name in @('__init__.py', '__main__.py', 'main.py')) {
        $source = Join-Path $appSourceDirectory $name
        if (-not (Test-Path -LiteralPath $source -PathType Leaf)) {
            throw "FMU Executor runtime entry point not found: $source"
        }
    }

    $appFiles = @(
        Get-ChildItem -LiteralPath $appSourceDirectory -File -Filter '*.py' -Recurse |
            Where-Object { $_.FullName -notmatch '[\\/](?:__pycache__|\.pytest_cache)(?:[\\/]|$)' }
    )
    if ($appFiles.Count -eq 0) {
        throw "No FMU Executor Python modules found under: $appSourceDirectory"
    }

    $appPackageDirectory = Join-Path $fmuExecutorPackageDirectory 'app'
    foreach ($file in $appFiles) {
        $relativePath = $file.FullName.Substring($appSourceDirectory.Length + 1)
        $destination = Join-Path $appPackageDirectory $relativePath
        $destinationDirectory = Split-Path -Parent $destination
        New-Item -ItemType Directory -Path $destinationDirectory -Force | Out-Null
        Copy-Item -LiteralPath $file.FullName -Destination $destination -Force
    }

    # The executor guide references this screenshot relative to its own directory.
    $fmuGuideImageSource = Join-Path $repositoryRoot 'docs\images\labstation-connectors-fmi.png'
    if (-not (Test-Path -LiteralPath $fmuGuideImageSource -PathType Leaf)) {
        throw "FMU Executor guide image not found: $fmuGuideImageSource"
    }
    $fmuGuideImageDirectory = Join-Path $packageDirectory 'docs\images'
    New-Item -ItemType Directory -Path $fmuGuideImageDirectory -Force | Out-Null
    Copy-Item -LiteralPath $fmuGuideImageSource -Destination (Join-Path $fmuGuideImageDirectory 'labstation-connectors-fmi.png') -Force

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

        $expectedFmuEntries = @(
            'Lab Station/fmu-executor/README.md',
            'Lab Station/fmu-executor/requirements.txt',
            'Lab Station/fmu-executor/app/__init__.py',
            'Lab Station/fmu-executor/app/__main__.py',
            'Lab Station/fmu-executor/app/main.py',
            'Lab Station/docs/images/labstation-connectors-fmi.png'
        )
        foreach ($expectedEntry in $expectedFmuEntries) {
            if ($entryNames -notcontains $expectedEntry) {
                throw "Release package is missing $expectedEntry"
            }
        }

        if ($entryNames -match '^Lab Station/fmu-executor/(tests|fmu-data)(/|$)') {
            throw 'Release package must not contain FMU tests or local FMU model data.'
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
