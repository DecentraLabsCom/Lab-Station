# ============================================================================
# Lab Station - Build Script
# ============================================================================
# Compiles all executables: AppControl.exe, LabStation.exe, LabStationPanel.exe

param(
    [switch]$Clean,
    [switch]$Verbose,
    [string]$CompilerPath = $env:AHK2EXE_PATH,
    [string]$AutoHotkeyBasePath = $env:AHK_BASE_PATH
)

$ErrorActionPreference = "Stop"

# Local tool discovery order:
# - AHK2EXE_PATH for the compiler
# - AHK_BASE_PATH or AHK_EXE for the AutoHotkey base runtime
# - standard AutoHotkey install paths
# - local .tmp-release-tools created from the release workflow toolchain
# - current workstation portable paths under C:\Temp\LabStationBuild and OneDrive
$compilerCandidates = @()
if ($CompilerPath) {
    $compilerCandidates += $CompilerPath
}
$compilerCandidates += @(
    "C:\Program Files\AutoHotkey\Compiler\Ahk2Exe.exe",
    "C:\Program Files\AutoHotkey\v2\Compiler\Ahk2Exe.exe",
    (Join-Path $PSScriptRoot ".tmp-release-tools\Ahk2Exe\Ahk2Exe.exe"),
    "C:\Temp\LabStationBuild\tools\Ahk2Exe.exe"
)

$compiler = $compilerCandidates | Where-Object { $_ -and (Test-Path $_) } | Select-Object -First 1

# Check compiler exists
if (-not $compiler) {
    Write-Error "Ahk2Exe compiler not found. Set AHK2EXE_PATH or install AutoHotkey v2. Checked: $($compilerCandidates -join '; ')"
    exit 1
}

$baseCandidates = @()
if ($AutoHotkeyBasePath) {
    $baseCandidates += $AutoHotkeyBasePath
}
if ($env:AHK_EXE) {
    $baseCandidates += $env:AHK_EXE
}
$baseCandidates += @(
    "C:\Program Files\AutoHotkey\v2\AutoHotkey64.exe",
    "C:\Program Files\AutoHotkey\v2\AutoHotkey.exe",
    (Join-Path $PSScriptRoot ".tmp-release-tools\AutoHotkey\AutoHotkey64.exe"),
    "C:\Users\ldela\OneDrive - UNED\Documents\Profesional\Administracion Laboratorios\AutoHotkey.exe"
)

$base = $baseCandidates | Where-Object { $_ -and (Test-Path $_) } | Select-Object -First 1
if (-not $base) {
    Write-Error "AutoHotkey v2 base executable not found. Set AHK_BASE_PATH or AHK_EXE. Checked: $($baseCandidates -join '; ')"
    exit 1
}

Write-Host "============================================" -ForegroundColor Cyan
Write-Host "  Lab Station - Build" -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan
Write-Host "Compiler: $compiler" -ForegroundColor Gray
Write-Host "Base: $base" -ForegroundColor Gray
Write-Host ""

# Clean previous builds if requested
if ($Clean) {
    Write-Host "Cleaning previous builds..." -ForegroundColor Yellow
    $files = @("AppControl.exe", "LabStation.exe", "LabStationPanel.exe")
    foreach ($file in $files) {
        if (Test-Path $file) {
            Remove-Item $file -Force
            Write-Host "  Deleted: $file" -ForegroundColor Gray
        }
    }
    Write-Host ""
}

# Compilation jobs
$jobs = @(
    @{
        Name = "AppControl"
        Source = "controller\AppControl.ahk"
        Output = "AppControl.exe"
    },
    @{
        Name = "LabStation"
        Source = "labstation\LabStation.ahk"
        Output = "LabStation.exe"
    },
    @{
        Name = "LabStationPanel"
        Source = "LabStationPanel.ahk"
        Output = "LabStationPanel.exe"
    }
)

$success = 0
$failed = 0

# Check if icon exists
$iconPath = Join-Path $PSScriptRoot "img\favicon.ico"
$iconArgs = @()
if (Test-Path $iconPath) {
    Write-Host "Using custom icon: $iconPath" -ForegroundColor Cyan
    $iconArgs = @('/icon', $iconPath)
    Write-Host ""
} else {
    Write-Host "Warning: Icon not found at $iconPath - using default AHK icon" -ForegroundColor Yellow
    Write-Host ""
}

foreach ($job in $jobs) {
    Write-Host "Compiling $($job.Name)..." -ForegroundColor White

    # Change to source directory for relative includes
    $sourceDir = Split-Path $job.Source -Parent
    if ($sourceDir) {
        Push-Location $sourceDir
    }

    $sourceName = Split-Path $job.Source -Leaf
    $scriptPath = (Resolve-Path $sourceName).Path
    $outputPath = Join-Path $PSScriptRoot $job.Output

    # Compile
    $startTime = Get-Date
    $compilerArgs = @('/in', $scriptPath, '/out', $outputPath, '/base', $base, '/ahk', $base) + $iconArgs + @('/silent')
    if ($Verbose) {
        & $compiler @($compilerArgs + @('verbose'))
    } else {
        & $compiler @compilerArgs 2>&1 | Out-Null
    }
    $duration = (Get-Date) - $startTime

    if ($sourceDir) {
        Pop-Location
    }

    for ($wait = 0; $wait -lt 20 -and -not (Test-Path $outputPath); $wait++) {
        Start-Sleep -Milliseconds 250
    }

    # Check result
    if (Test-Path $outputPath) {
        $size = (Get-Item $outputPath).Length / 1MB
        $summaryLine = "  [OK] {0}: {1} MB ({2}s)" -f $job.Output, $size.ToString('0.00'), $duration.TotalSeconds.ToString('0.0')
        Write-Host $summaryLine -ForegroundColor Green
        $success++
    } else {
        Write-Host ("  [FAIL] {0}: Compilation failed" -f $job.Output) -ForegroundColor Red
        $failed++
    }
    Write-Host ""
}

# Summary
Write-Host "============================================" -ForegroundColor Cyan
if ($failed -eq 0) {
    Write-Host "  Build completed successfully!" -ForegroundColor Green
    Write-Host "  $success/$($jobs.Count) executables compiled" -ForegroundColor Green
} else {
    Write-Host "  Build completed with errors" -ForegroundColor Yellow
    Write-Host "  Success: $success | Failed: $failed" -ForegroundColor Yellow
}
Write-Host "============================================" -ForegroundColor Cyan
Write-Host ""

exit $failed
