[CmdletBinding()]
param(
    [string]$DistPath = (Join-Path $PSScriptRoot '..\dist'),
    [string]$OutputPath = '',
    [string]$SmartFactoryExamplePath = ''
)

$ErrorActionPreference = 'Stop'

$executableNames = @(
    'LabStation.exe',
    'LabStationPanel.exe',
    'WindowSpy.exe'
)

$distDirectory = (Resolve-Path -LiteralPath $DistPath).Path
$repositoryRoot = Split-Path -Parent $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($SmartFactoryExamplePath)) {
    $SmartFactoryExamplePath = $env:FMU_EXECUTOR_SMART_FACTORY_EXAMPLE_PATH
}
if ([string]::IsNullOrWhiteSpace($SmartFactoryExamplePath)) {
    $SmartFactoryExamplePath = Join-Path $repositoryRoot '..\FMU-Executor\examples\smart-factory-cell'
}
if (-not (Test-Path -LiteralPath $SmartFactoryExamplePath -PathType Container)) {
    throw "Canonical Smart Factory example not found at '$SmartFactoryExamplePath'. Pass -SmartFactoryExamplePath from the FMU-Executor checkout."
}
$SmartFactoryExamplePath = (Resolve-Path -LiteralPath $SmartFactoryExamplePath).Path
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

    # Ship the frozen, self-contained sidecar runtime produced by the release workflow.
    $fmuExecutorSourceDirectory = Join-Path $repositoryRoot 'fmu-executor'
    if (-not (Test-Path -LiteralPath $fmuExecutorSourceDirectory -PathType Container)) {
        throw "FMU Executor source directory not found: $fmuExecutorSourceDirectory"
    }

    $fmuExecutorPackageDirectory = Join-Path $packageDirectory 'fmu-executor'
    New-Item -ItemType Directory -Path $fmuExecutorPackageDirectory -Force | Out-Null

    $fmuExecutorGuide = Join-Path $repositoryRoot 'docs\fmu-executor-runtime.md'
    if (-not (Test-Path -LiteralPath $fmuExecutorGuide -PathType Leaf)) {
        throw "FMU Executor runtime guide not found: $fmuExecutorGuide"
    }
    Copy-Item -LiteralPath $fmuExecutorGuide -Destination (Join-Path $fmuExecutorPackageDirectory 'README.md') -Force

    # Preserve source provenance when the checkout provides it.
    foreach ($name in @('VERSION', 'SOURCE.lock.json')) {
        $source = Join-Path $fmuExecutorSourceDirectory $name
        if (Test-Path -LiteralPath $source -PathType Leaf) {
            Copy-Item -LiteralPath $source -Destination (Join-Path $fmuExecutorPackageDirectory $name) -Force
        }
    }

    $fmuExecutorBuildDirectory = Join-Path $distDirectory 'fmu-executor-runtime\FMUExecutor'
    $fmuExecutorExecutable = Join-Path $fmuExecutorBuildDirectory 'FMUExecutor.exe'
    if (-not (Test-Path -LiteralPath $fmuExecutorExecutable -PathType Leaf)) {
        throw "Standalone FMU Executor executable not found: $fmuExecutorExecutable"
    }

    $runtimePackageDirectory = Join-Path $fmuExecutorPackageDirectory 'runtime'
    New-Item -ItemType Directory -Path $runtimePackageDirectory -Force | Out-Null
    foreach ($item in Get-ChildItem -LiteralPath $fmuExecutorBuildDirectory -Force) {
        Copy-Item -LiteralPath $item.FullName -Destination $runtimePackageDirectory -Recurse -Force
    }
    $runtimePayloadFiles = @(
        Get-ChildItem -LiteralPath $runtimePackageDirectory -File -Recurse
    )
    if ($runtimePayloadFiles.Count -lt 2) {
        throw 'FMU Executor runtime bundle is incomplete; expected the executable and its private Python payload.'
    }

    # Ship the public Smart Factory demo FMU as a provisioned model, separate
    # from the pinned Executor runtime and from provider-owned models.
    $demoFmuSource = Join-Path $SmartFactoryExamplePath 'SmartFactoryCell.fmu'
    if (-not (Test-Path -LiteralPath $demoFmuSource -PathType Leaf)) {
        throw "Smart Factory demo FMU not found: $demoFmuSource"
    }
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $demoArchive = [System.IO.Compression.ZipFile]::OpenRead($demoFmuSource)
    try {
        $demoEntries = @($demoArchive.Entries | ForEach-Object { $_.FullName -replace '\\', '/' })
        foreach ($expectedEntry in @('modelDescription.xml', 'binaries/win64/SmartFactoryCell.dll', 'resources/smart-factory-cell.glb')) {
            if ($demoEntries -notcontains $expectedEntry) {
                throw "Canonical Station demo FMU is missing Windows x64 entry '$expectedEntry'."
            }
        }
        if ($demoEntries -match '^binaries/(linux64|darwin64|win32)/') {
            throw 'Lab Station release requires the Windows x64 Smart Factory FMU, not a development build for another platform.'
        }
    } finally {
        $demoArchive.Dispose()
    }
    $demoFmuDirectory = Join-Path $fmuExecutorPackageDirectory 'fmu-data'
    New-Item -ItemType Directory -Path $demoFmuDirectory -Force | Out-Null
    Copy-Item -LiteralPath $demoFmuSource -Destination (Join-Path $demoFmuDirectory 'SmartFactoryCell.fmu') -Force
    $demoSceneSource = Join-Path $SmartFactoryExamplePath 'smart-factory-cell.glb'
    if (-not (Test-Path -LiteralPath $demoSceneSource -PathType Leaf)) {
        throw "Smart Factory demo GLB not found: $demoSceneSource"
    }
    Copy-Item -LiteralPath $demoSceneSource -Destination (Join-Path $demoFmuDirectory 'SmartFactoryCell.glb') -Force
    $demoLicenseSource = Join-Path $SmartFactoryExamplePath 'LICENSE.txt'
    if (-not (Test-Path -LiteralPath $demoLicenseSource -PathType Leaf)) {
        throw "Smart Factory demo license not found: $demoLicenseSource"
    }
    Copy-Item -LiteralPath $demoLicenseSource -Destination (Join-Path $demoFmuDirectory 'SmartFactoryCell.LICENSE.txt') -Force

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
            'Lab Station/fmu-executor/runtime/FMUExecutor.exe',
            'Lab Station/fmu-executor/fmu-data/SmartFactoryCell.fmu',
            'Lab Station/fmu-executor/fmu-data/SmartFactoryCell.glb',
            'Lab Station/fmu-executor/fmu-data/SmartFactoryCell.LICENSE.txt',
            'Lab Station/docs/images/labstation-connectors-fmi.png'
        )
        foreach ($expectedEntry in $expectedFmuEntries) {
            if ($entryNames -notcontains $expectedEntry) {
                throw "Release package is missing $expectedEntry"
            }
        }

        if ($entryNames -match '^Lab Station/fmu-executor/tests(/|$)') {
            throw 'Release package must not contain FMU Executor tests.'
        }
        $packagedFmuModels = @($entryNames | Where-Object {
            $_ -match '^Lab Station/fmu-executor/fmu-data/.+\.fmu$'
        })
        if ($packagedFmuModels.Count -ne 1 -or $packagedFmuModels[0] -ne 'Lab Station/fmu-executor/fmu-data/SmartFactoryCell.fmu') {
            throw 'Release package must contain only the reviewed Smart Factory demo FMU.'
        }
        $runtimePythonEntries = @($entryNames | Where-Object {
            $_ -match '^Lab Station/fmu-executor/runtime/_internal/python\d{2,3}\.dll$'
        })
        if ($runtimePythonEntries.Count -eq 0) {
            throw 'Release package is missing the bundled Python runtime payload.'
        }
        if ($entryNames -match '^Lab Station/fmu-executor/(app/|requirements\.txt$)') {
            throw 'Release package must contain the frozen FMU runtime, not source requiring a separate Python installation.'
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
