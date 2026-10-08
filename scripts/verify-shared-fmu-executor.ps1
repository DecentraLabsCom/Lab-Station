[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$SharedSource
)

$ErrorActionPreference = 'Stop'
$repositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$sourceRoot = (Resolve-Path -LiteralPath $SharedSource).Path
$snapshotRoot = Join-Path $repositoryRoot 'fmu-executor'
$lockPath = Join-Path $snapshotRoot 'SOURCE.lock.json'
$lock = Get-Content -LiteralPath $lockPath -Raw | ConvertFrom-Json

if ($lock.repository -ne 'DecentraLabsCom/FMU-Executor' -or $lock.sourceTree.format -ne 'git-ls-tree-manifest-v1' -or $lock.runtimePayload.format -ne 'sha256-path-manifest-v1') {
    throw 'The station source lock does not identify the canonical FMU Executor source manifest.'
}

$sourceCommit = (& git -C $sourceRoot rev-parse HEAD).Trim()
if ($LASTEXITCODE -ne 0 -or $sourceCommit -ne $lock.commit) {
    throw "Shared FMU Executor commit does not match the station pin ($($lock.commit))."
}
$dirty = @(& git -C $sourceRoot status --porcelain --untracked-files=all)
if ($LASTEXITCODE -ne 0 -or $dirty.Count -gt 0) {
    throw 'Shared FMU Executor checkout must be clean before verifying a station snapshot.'
}
$sourceVersion = (Get-Content -LiteralPath (Join-Path $sourceRoot 'VERSION') -Raw).Trim()
if ($sourceVersion -ne $lock.version) {
    throw "Shared FMU Executor version $sourceVersion does not match the station pin $($lock.version)."
}

$verificationRoot = Join-Path $repositoryRoot ('.fmu-executor-verify-' + [Guid]::NewGuid().ToString('N'))
if (-not $verificationRoot.StartsWith($repositoryRoot + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Refusing to create a verification directory outside Lab Station.'
}
New-Item -ItemType Directory -Path $verificationRoot | Out-Null
try {
$archivePath = Join-Path $verificationRoot 'fmu-executor.tar'
$extractRoot = Join-Path $verificationRoot 'extracted'
New-Item -ItemType Directory -Path $extractRoot | Out-Null
$archivePrefix = "decentralabs-fmu-executor-$sourceVersion/"
& git -C $sourceRoot -c core.autocrlf=false archive --format=tar "--prefix=$archivePrefix" "--output=$archivePath" $sourceCommit VERSION pyproject.toml requirements.txt README.md app tests
if ($LASTEXITCODE -ne 0) {
    throw 'Unable to create the pinned FMU Executor verification archive.'
}
& tar -xf $archivePath -C $extractRoot
if ($LASTEXITCODE -ne 0) {
    throw 'Unable to extract the pinned FMU Executor verification archive.'
}
$archiveRoot = Join-Path $extractRoot "decentralabs-fmu-executor-$sourceVersion"
$manifestLines = @(& git -C $sourceRoot ls-tree -r --full-tree $sourceCommit -- VERSION pyproject.toml requirements.txt README.md app tests)
if ($LASTEXITCODE -ne 0 -or $manifestLines.Count -eq 0) {
    throw 'Unable to create the normalized pinned FMU Executor source manifest.'
}
$manifestBytes = [Text.Encoding]::UTF8.GetBytes(($manifestLines -join "`n") + "`n")
$sha256 = [Security.Cryptography.SHA256]::Create()
try {
    $digest = ([BitConverter]::ToString($sha256.ComputeHash($manifestBytes))).Replace('-', '').ToLowerInvariant()
} finally {
    $sha256.Dispose()
}
if ($digest -ne ([string]$lock.sourceTree.sha256).ToLowerInvariant()) {
    throw 'Shared FMU Executor source manifest digest does not match the station pin.'
}

$trackedFiles = @(& git -C $sourceRoot ls-tree -r --name-only $sourceCommit -- VERSION pyproject.toml requirements.txt README.md app tests)
if ($LASTEXITCODE -ne 0 -or $trackedFiles.Count -eq 0) {
    throw 'Unable to enumerate the pinned FMU Executor source files.'
}
$expectedPaths = @($trackedFiles | Sort-Object -CaseSensitive)
$snapshotPaths = @(Get-ChildItem -LiteralPath $snapshotRoot -Recurse -File | ForEach-Object {
    $relativePath = $_.FullName.Substring($snapshotRoot.Length + 1).Replace([IO.Path]::DirectorySeparatorChar, '/')
    if ($relativePath -match '(^|/)__pycache__/.*\.pyc$') {
        return
    }
    if (@('VERSION', 'pyproject.toml', 'requirements.txt', 'README.md') -contains $relativePath -or
        $relativePath.StartsWith('app/', [StringComparison]::Ordinal) -or
        $relativePath.StartsWith('tests/', [StringComparison]::Ordinal)) {
        $relativePath
    }
} | Sort-Object -CaseSensitive)
$pathDifferences = @(Compare-Object -ReferenceObject $expectedPaths -DifferenceObject $snapshotPaths -CaseSensitive)
if ($pathDifferences.Count -gt 0) {
    throw "Station FMU Executor snapshot file set differs from the pinned source: $($pathDifferences | Out-String)"
}
$runtimeFiles = @(& git -C $sourceRoot ls-tree -r --name-only $sourceCommit -- VERSION requirements.txt app)
if ($LASTEXITCODE -ne 0 -or $runtimeFiles.Count -eq 0) {
    throw 'Unable to enumerate the pinned FMU Executor runtime payload.'
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
    $runtimePayloadDigest = ([BitConverter]::ToString($sha256.ComputeHash($runtimeManifestBytes))).Replace('-', '').ToLowerInvariant()
} finally {
    $sha256.Dispose()
}
if ($runtimePayloadDigest -ne ([string]$lock.runtimePayload.sha256).ToLowerInvariant()) {
    throw 'FMU Executor runtime payload digest does not match the station pin.'
}
foreach ($relativePath in $trackedFiles) {
    $sourceFile = Join-Path $archiveRoot $relativePath
    $snapshotFile = Join-Path $snapshotRoot $relativePath
    if (-not (Test-Path -LiteralPath $snapshotFile -PathType Leaf)) {
        throw "Station FMU Executor snapshot is missing $relativePath."
    }
    $sourceHash = (Get-FileHash -LiteralPath $sourceFile -Algorithm SHA256).Hash
    $snapshotHash = (Get-FileHash -LiteralPath $snapshotFile -Algorithm SHA256).Hash
    if ($sourceHash -ne $snapshotHash) {
        throw "Station FMU Executor snapshot differs from the pinned source at $relativePath."
    }
}

Write-Host "FMU Executor snapshot matches commit $sourceCommit, source manifest $digest, and runtime payload $runtimePayloadDigest."
} finally {
    $resolvedVerificationRoot = (Resolve-Path -LiteralPath $verificationRoot).Path
    if (-not $resolvedVerificationRoot.StartsWith($repositoryRoot + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing to remove a verification directory outside Lab Station: $resolvedVerificationRoot"
    }
    Remove-Item -LiteralPath $resolvedVerificationRoot -Recurse -Force -ErrorAction SilentlyContinue
}
