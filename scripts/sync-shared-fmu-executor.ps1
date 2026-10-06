param(
    [Parameter(Mandatory = $true)]
    [string]$SharedSource,
    [switch]$UpdatePin
)

$ErrorActionPreference = 'Stop'
$repositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$sourceRoot = (Resolve-Path $SharedSource).Path
$destinationRoot = Join-Path $repositoryRoot 'fmu-executor'
$destinationRoot = (Resolve-Path $destinationRoot).Path

if ($sourceRoot -eq $destinationRoot -or $sourceRoot.StartsWith($destinationRoot + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'SharedSource must point to the standalone FMU Executor checkout.'
}
foreach ($path in @($sourceRoot, $destinationRoot)) {
    $item = Get-Item -LiteralPath $path -Force
    if (-not $item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
        throw "Expected a real directory at $path."
    }
}

$sourceVersion = (Get-Content -LiteralPath (Join-Path $sourceRoot 'VERSION') -Raw).Trim()
$lockPath = Join-Path $destinationRoot 'SOURCE.lock.json'
$lock = Get-Content -LiteralPath $lockPath -Raw | ConvertFrom-Json
if ($lock.repository -ne 'DecentraLabsCom/FMU-Executor') {
    throw 'The station source lock names a different shared repository.'
}
if (-not $UpdatePin -and $sourceVersion -ne $lock.version) {
    throw "Shared version $sourceVersion does not match the pinned station version $($lock.version). Pass -UpdatePin after reviewing the release."
}
foreach ($required in @('app/main.py', 'requirements.txt', 'pyproject.toml', 'tests')) {
    if (-not (Test-Path -LiteralPath (Join-Path $sourceRoot $required))) {
        throw "Shared FMU Executor source is missing $required."
    }
}

$stage = Join-Path $repositoryRoot ('.fmu-executor-sync-' + [Guid]::NewGuid().ToString('N'))
$backup = Join-Path $stage 'previous'
if (-not $stage.StartsWith($repositoryRoot + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Refusing to create a sync directory outside Lab Station.'
}
New-Item -ItemType Directory -Path $stage | Out-Null
New-Item -ItemType Directory -Path (Join-Path $stage 'source') | Out-Null
New-Item -ItemType Directory -Path $backup | Out-Null
$appMoved = $false
$testsMoved = $false
try {
    Copy-Item -LiteralPath (Join-Path $sourceRoot 'app') -Destination (Join-Path $stage 'source/app') -Recurse
    Copy-Item -LiteralPath (Join-Path $sourceRoot 'tests') -Destination (Join-Path $stage 'source/tests') -Recurse
    foreach ($name in @('README.md', 'VERSION', 'requirements.txt', 'pyproject.toml')) {
        Copy-Item -LiteralPath (Join-Path $sourceRoot $name) -Destination (Join-Path $stage "source/$name")
    }

    Move-Item -LiteralPath (Join-Path $destinationRoot 'app') -Destination (Join-Path $backup 'app')
    $appMoved = $true
    Move-Item -LiteralPath (Join-Path $destinationRoot 'tests') -Destination (Join-Path $backup 'tests')
    $testsMoved = $true
    Move-Item -LiteralPath (Join-Path $stage 'source/app') -Destination (Join-Path $destinationRoot 'app')
    Move-Item -LiteralPath (Join-Path $stage 'source/tests') -Destination (Join-Path $destinationRoot 'tests')
    foreach ($name in @('README.md', 'VERSION', 'requirements.txt', 'pyproject.toml')) {
        Copy-Item -LiteralPath (Join-Path $stage "source/$name") -Destination (Join-Path $destinationRoot $name) -Force
    }
    if ($UpdatePin) {
        $lock.version = $sourceVersion
        $lock | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $lockPath -Encoding utf8
    }
} catch {
    if ($appMoved -and (Test-Path -LiteralPath (Join-Path $backup 'app'))) {
        if (Test-Path -LiteralPath (Join-Path $destinationRoot 'app')) { Remove-Item -LiteralPath (Join-Path $destinationRoot 'app') -Recurse -Force }
        Move-Item -LiteralPath (Join-Path $backup 'app') -Destination (Join-Path $destinationRoot 'app')
    }
    if ($testsMoved -and (Test-Path -LiteralPath (Join-Path $backup 'tests'))) {
        if (Test-Path -LiteralPath (Join-Path $destinationRoot 'tests')) { Remove-Item -LiteralPath (Join-Path $destinationRoot 'tests') -Recurse -Force }
        Move-Item -LiteralPath (Join-Path $backup 'tests') -Destination (Join-Path $destinationRoot 'tests')
    }
    throw
} finally {
    if ($stage.StartsWith($repositoryRoot + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
        Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Write-Host "Synchronized FMU Executor source version $sourceVersion."
