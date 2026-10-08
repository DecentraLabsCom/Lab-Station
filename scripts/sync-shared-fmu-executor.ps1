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

$stage = Join-Path $repositoryRoot ('.fmu-executor-sync-' + [Guid]::NewGuid().ToString('N'))
$backup = Join-Path $stage 'previous'
if (-not $stage.StartsWith($repositoryRoot + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Refusing to create a sync directory outside Lab Station.'
}
New-Item -ItemType Directory -Path (Join-Path $stage 'source') -Force | Out-Null
New-Item -ItemType Directory -Path $backup | Out-Null
$archiveDirectory = Join-Path $stage 'archive'
New-Item -ItemType Directory -Path $archiveDirectory | Out-Null
$appMoved = $false
$testsMoved = $false
try {
$sourceCommit = (& git -C $sourceRoot rev-parse HEAD).Trim()
if ($LASTEXITCODE -ne 0) {
    throw 'SharedSource must be a Git checkout at a reviewed commit.'
}
$sourceChanges = @(& git -C $sourceRoot status --porcelain --untracked-files=all)
if ($LASTEXITCODE -ne 0 -or $sourceChanges.Count -gt 0) {
    throw 'SharedSource must be clean before synchronizing a pinned release.'
}
$sourceVersion = (Get-Content -LiteralPath (Join-Path $sourceRoot 'VERSION') -Raw).Trim()
$archivePrefix = "decentralabs-fmu-executor-$sourceVersion/"
$archivePath = Join-Path $archiveDirectory 'fmu-executor.tar'
$extractRoot = Join-Path $archiveDirectory 'extracted'
New-Item -ItemType Directory -Path $extractRoot | Out-Null
& git -C $sourceRoot -c core.autocrlf=false archive --format=tar "--prefix=$archivePrefix" "--output=$archivePath" $sourceCommit VERSION pyproject.toml requirements.txt README.md app tests
if ($LASTEXITCODE -ne 0) {
    throw 'Unable to create the pinned FMU Executor source archive.'
}
& tar -xf $archivePath -C $extractRoot
if ($LASTEXITCODE -ne 0) {
    throw 'Unable to extract the pinned FMU Executor source archive.'
}
$archiveRoot = Join-Path $extractRoot "decentralabs-fmu-executor-$sourceVersion"
$manifestLines = @(& git -C $sourceRoot ls-tree -r --full-tree $sourceCommit -- VERSION pyproject.toml requirements.txt README.md app tests)
if ($LASTEXITCODE -ne 0 -or $manifestLines.Count -eq 0) {
    throw 'Unable to create the normalized FMU Executor source manifest.'
}
$manifestBytes = [Text.Encoding]::UTF8.GetBytes(($manifestLines -join "`n") + "`n")
$sha256 = [Security.Cryptography.SHA256]::Create()
try {
    $sourceSha256 = ([BitConverter]::ToString($sha256.ComputeHash($manifestBytes))).Replace('-', '').ToLowerInvariant()
} finally {
    $sha256.Dispose()
}
$runtimeFiles = @(& git -C $sourceRoot ls-tree -r --name-only $sourceCommit -- VERSION requirements.txt app)
if ($LASTEXITCODE -ne 0 -or $runtimeFiles.Count -eq 0) {
    throw 'Unable to enumerate the FMU Executor runtime payload.'
}
$runtimeFiles = [string[]]$runtimeFiles
[Array]::Sort($runtimeFiles, [StringComparer]::Ordinal)
$runtimeManifestLines = foreach ($relativePath in $runtimeFiles) {
    $fileHash = (Get-FileHash -LiteralPath (Join-Path $archiveRoot $relativePath) -Algorithm SHA256).Hash.ToLowerInvariant()
    "$relativePath`t$fileHash"
}
$runtimeManifestBytes = [Text.Encoding]::UTF8.GetBytes(($runtimeManifestLines -join "`n") + "`n")
$sha256 = [Security.Cryptography.SHA256]::Create()
try {
    $runtimePayloadSha256 = ([BitConverter]::ToString($sha256.ComputeHash($runtimeManifestBytes))).Replace('-', '').ToLowerInvariant()
} finally {
    $sha256.Dispose()
}
$lockPath = Join-Path $destinationRoot 'SOURCE.lock.json'
$lock = Get-Content -LiteralPath $lockPath -Raw | ConvertFrom-Json
if ($lock.repository -ne 'DecentraLabsCom/FMU-Executor') {
    throw 'The station source lock names a different shared repository.'
}
if (-not $UpdatePin -and ($sourceVersion -ne $lock.version -or $sourceCommit -ne $lock.commit -or $sourceSha256 -ne $lock.sourceTree.sha256 -or $runtimePayloadSha256 -ne $lock.runtimePayload.sha256)) {
    throw "Shared FMU Executor source does not match the pinned version/commit/digest. Pass -UpdatePin after reviewing the release."
}
foreach ($required in @('app/main.py', 'requirements.txt', 'pyproject.toml', 'tests')) {
    if (-not (Test-Path -LiteralPath (Join-Path $archiveRoot $required))) {
        throw "Shared FMU Executor source is missing $required."
    }
}

Copy-Item -LiteralPath (Join-Path $archiveRoot 'app') -Destination (Join-Path $stage 'source/app') -Recurse
Copy-Item -LiteralPath (Join-Path $archiveRoot 'tests') -Destination (Join-Path $stage 'source/tests') -Recurse
    foreach ($name in @('README.md', 'VERSION', 'requirements.txt', 'pyproject.toml')) {
        Copy-Item -LiteralPath (Join-Path $archiveRoot $name) -Destination (Join-Path $stage "source/$name")
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
        $lock | Add-Member -NotePropertyName commit -NotePropertyValue $sourceCommit -Force
        $lock.PSObject.Properties.Remove('artifact')
        $lock | Add-Member -NotePropertyName sourceTree -NotePropertyValue ([pscustomobject][ordered]@{ format = 'git-ls-tree-manifest-v1'; sha256 = $sourceSha256 }) -Force
        $lock | Add-Member -NotePropertyName runtimePayload -NotePropertyValue ([pscustomobject][ordered]@{ format = 'sha256-path-manifest-v1'; sha256 = $runtimePayloadSha256 }) -Force
        $lockJson = $lock | ConvertTo-Json -Depth 4
        [IO.File]::WriteAllText($lockPath, $lockJson, [Text.UTF8Encoding]::new($false))
    }
    & (Join-Path $PSScriptRoot 'verify-shared-fmu-executor.ps1') -SharedSource $sourceRoot
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
