[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ExecutablePath,
    [Parameter(Mandatory = $true)]
    [string]$SmokeFmuPath,
    [int]$TimeoutSeconds = 30
)

$ErrorActionPreference = 'Stop'
$executable = (Resolve-Path -LiteralPath $ExecutablePath).Path
$smokeFmuSource = (Resolve-Path -LiteralPath $SmokeFmuPath).Path
$runtimeRoot = Split-Path -Parent (Split-Path -Parent $executable)
$expectedFmuRoot = Join-Path $runtimeRoot 'fmu-data'
$probe = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
$probe.Start()
$port = $probe.LocalEndpoint.Port
$probe.Stop()

$environmentNames = @(
    'FMU_EXECUTOR_HOST',
    'FMU_EXECUTOR_PORT',
    'FMU_INTERNAL_TOKEN',
    'FMU_ROOT',
    'FMU_EXECUTOR_TEMP',
    'FMU_EXECUTION_TIMEOUT_SECONDS',
    'FMU_WORKER_STARTUP_TRACE'
)
$previousEnvironment = @{}
foreach ($name in $environmentNames) {
    $previousEnvironment[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
}

$logId = [Guid]::NewGuid().ToString('N')
$stdout = Join-Path ([IO.Path]::GetTempPath()) "fmu-executor-$logId.stdout.txt"
$stderr = Join-Path ([IO.Path]::GetTempPath()) "fmu-executor-$logId.stderr.txt"
$process = $null

try {
    $env:FMU_EXECUTOR_HOST = '127.0.0.1'
    $env:FMU_EXECUTOR_PORT = [string]$port
    $env:FMU_INTERNAL_TOKEN = 'runtime-smoke-test-token'
    $env:FMU_EXECUTION_TIMEOUT_SECONDS = '15'
    $env:FMU_WORKER_STARTUP_TRACE = '1'
    Remove-Item Env:FMU_ROOT -ErrorAction SilentlyContinue
    Remove-Item Env:FMU_EXECUTOR_TEMP -ErrorAction SilentlyContinue

    $process = Start-Process -FilePath $executable -WorkingDirectory ([IO.Path]::GetTempPath()) `
        -PassThru -WindowStyle Hidden -RedirectStandardOutput $stdout -RedirectStandardError $stderr
    $health = $null
    for ($attempt = 0; $attempt -lt $TimeoutSeconds; $attempt++) {
        if ($process.HasExited) {
            $details = if (Test-Path -LiteralPath $stderr) { Get-Content -LiteralPath $stderr -Raw } else { '' }
            throw "Frozen FMU Executor exited before becoming healthy. $details"
        }
        try {
            $health = Invoke-RestMethod -Uri "http://127.0.0.1:$port/internal/health" -TimeoutSec 2
            break
        } catch {
            Start-Sleep -Seconds 1
        }
    }
    if (-not $health -or $health.status -ne 'UP') {
        $details = if (Test-Path -LiteralPath $stderr) { Get-Content -LiteralPath $stderr -Raw } else { '' }
        throw "Frozen FMU Executor health check failed. $details"
    }

    $capacity = Invoke-RestMethod -Uri "http://127.0.0.1:$port/internal/fmu/capacity" `
        -Headers @{ 'X-Internal-Session-Token' = 'runtime-smoke-test-token' } -TimeoutSec 5
    if (-not (Test-Path -LiteralPath $expectedFmuRoot -PathType Container)) {
        throw "Frozen FMU Executor did not create its default FMU data directory: $expectedFmuRoot"
    }

    $smokeFmuName = 'BouncingBall.fmu'
    $smokeFmu = Join-Path $expectedFmuRoot $smokeFmuName
    Copy-Item -LiteralPath $smokeFmuSource -Destination $smokeFmu -Force
    $simulationBody = @{
        accessKey = $smokeFmuName
        parameters = @{}
        options = @{ stopTime = 0.1 }
    } | ConvertTo-Json -Depth 5 -Compress
    try {
        $simulation = Invoke-RestMethod -Method Post `
            -Uri "http://127.0.0.1:$port/internal/fmu/simulations/run" `
            -Headers @{ 'X-Internal-Session-Token' = 'runtime-smoke-test-token' } `
            -ContentType 'application/json' -Body $simulationBody -TimeoutSec 30
    } catch {
        $apiError = "$($_.Exception.GetType().FullName): $($_.Exception.Message)"
        if ($_.ErrorDetails.Message) {
            $apiError += "`n$($_.ErrorDetails.Message)"
        }
        $stdoutDetails = if (Test-Path -LiteralPath $stdout) {
            (Get-Content -LiteralPath $stdout -Tail 120 | Out-String).TrimEnd()
        } else { '(no stdout log)' }
        $stderrDetails = if (Test-Path -LiteralPath $stderr) {
            (Get-Content -LiteralPath $stderr -Tail 120 | Out-String).TrimEnd()
        } else { '(no stderr log)' }
        throw "Frozen worker simulation failed: $apiError`n--- FMU Executor stdout ---`n$stdoutDetails`n--- FMU Executor stderr ---`n$stderrDetails"
    }
    if ($null -eq $simulation -or $null -eq $simulation.time) {
        throw 'Frozen worker path returned no simulation result.'
    }

    Write-Host "Frozen FMU Executor passed health, authenticated API, and spawned-worker checks (capacity=$($capacity.capacity), time=$($simulation.time))." -ForegroundColor Green
} finally {
    if ($process -and -not $process.HasExited) {
        Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
    }
    foreach ($name in $environmentNames) {
        [Environment]::SetEnvironmentVariable($name, $previousEnvironment[$name], 'Process')
    }
    Remove-Item -LiteralPath $stdout, $stderr -Force -ErrorAction SilentlyContinue
}
