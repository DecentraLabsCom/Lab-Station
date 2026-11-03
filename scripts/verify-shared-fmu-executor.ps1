[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$SharedSource,
    [switch]$UpdatePin
)

$ErrorActionPreference = 'Stop'
$repositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$sourceRoot = (Resolve-Path -LiteralPath $SharedSource).Path
$lockPath = Join-Path $repositoryRoot 'fmu-executor\SOURCE.lock.json'
$lock = Get-Content -LiteralPath $lockPath -Raw | ConvertFrom-Json

if ($lock.repository -ne 'DecentraLabsCom/FMU-Executor' -or
    $lock.sourceTree.format -ne 'git-ls-tree-manifest-v1' -or
    $lock.runtimePayload.format -ne 'sha256-path-manifest-v1') {
    throw 'The station source lock does not identify the canonical FMU Executor manifests.'
}

$sourceCommit = (& git -C $sourceRoot rev-parse HEAD).Trim()
if ($LASTEXITCODE -ne 0) {
    throw 'Shared FMU Executor source must be a Git checkout.'
}
$dirty = @(& git -C $sourceRoot status --porcelain --untracked-files=all)
if ($LASTEXITCODE -ne 0 -or $dirty.Count -gt 0) {
    throw 'Shared FMU Executor checkout must be clean before verification or pin updates.'
}
$sourceVersion = (Get-Content -LiteralPath (Join-Path $sourceRoot 'VERSION') -Raw).Trim()
if (-not $UpdatePin -and ($sourceCommit -ne $lock.commit -or $sourceVersion -ne $lock.version)) {
    throw "Shared FMU Executor $sourceVersion at $sourceCommit does not match the station pin ($($lock.version) at $($lock.commit))."
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
    foreach ($requiredPath in @('VERSION', 'pyproject.toml', 'requirements.txt', 'README.md', 'app/main.py', 'tests')) {
        if (-not (Test-Path -LiteralPath (Join-Path $archiveRoot $requiredPath))) {
            throw "Pinned FMU Executor source is missing $requiredPath."
        }
    }

    $manifestLines = @(& git -C $sourceRoot ls-tree -r --full-tree $sourceCommit -- VERSION pyproject.toml requirements.txt README.md app tests)
    if ($LASTEXITCODE -ne 0 -or $manifestLines.Count -eq 0) {
        throw 'Unable to create the normalized pinned FMU Executor source manifest.'
    }
    $manifestBytes = [Text.Encoding]::UTF8.GetBytes(($manifestLines -join "`n") + "`n")
    $sha256 = [Security.Cryptography.SHA256]::Create()
    try {
        $sourceDigest = ([BitConverter]::ToString($sha256.ComputeHash($manifestBytes))).Replace('-', '').ToLowerInvariant()
    } finally {
        $sha256.Dispose()
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
        $runtimeDigest = ([BitConverter]::ToString($sha256.ComputeHash($runtimeManifestBytes))).Replace('-', '').ToLowerInvariant()
    } finally {
        $sha256.Dispose()
    }

    if ($UpdatePin) {
        $lock.version = $sourceVersion
        $lock.commit = $sourceCommit
        $lock.sourceTree.sha256 = $sourceDigest
        $lock.runtimePayload.sha256 = $runtimeDigest
        if ($lock.PSObject.Properties['syncMode']) {
            $lock.PSObject.Properties.Remove('syncMode')
        }
        $lockJson = $lock | ConvertTo-Json -Depth 6
        [IO.File]::WriteAllText($lockPath, $lockJson, [Text.UTF8Encoding]::new($false))
        Write-Host "Updated FMU Executor pin to $sourceVersion at $sourceCommit."
    } else {
        if ($sourceDigest -ne ([string]$lock.sourceTree.sha256).ToLowerInvariant()) {
            throw 'FMU Executor source manifest digest does not match the station pin.'
        }
        if ($runtimeDigest -ne ([string]$lock.runtimePayload.sha256).ToLowerInvariant()) {
            throw 'FMU Executor runtime payload digest does not match the station pin.'
        }
        Write-Host "FMU Executor source pin verified: $sourceVersion at $sourceCommit; source $sourceDigest; runtime $runtimeDigest."
    }
} finally {
    $resolvedVerificationRoot = (Resolve-Path -LiteralPath $verificationRoot).Path
    if (-not $resolvedVerificationRoot.StartsWith($repositoryRoot + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing to remove a verification directory outside Lab Station: $resolvedVerificationRoot"
    }
    Remove-Item -LiteralPath $resolvedVerificationRoot -Recurse -Force -ErrorAction SilentlyContinue
}
