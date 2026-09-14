# Development, build and verification

## Prerequisites

- Windows with PowerShell 5.1 or newer.
- AutoHotkey v2.0.27 for running the source tests and compiling the AHK
  executables. The CI workflow uses this exact version.
- Python 3.12 for the FMU Executor and its tests.
- Administrator privileges for setup, WinRM, registry, firewall, scheduled
  task, and power-management operations.

## Build the Windows executables

From the repository root, `build.ps1` discovers Ahk2Exe and the AutoHotkey v2
base runtime, then writes these files to the repository root:

```powershell
.\build.ps1
.\build.ps1 -Clean
```

If AutoHotkey is installed elsewhere, set `AHK2EXE_PATH` for the compiler and
`AHK_BASE_PATH` (or `AHK_EXE`) for the base runtime. The build produces
`AppControl.exe`, `LabStation.exe`, and `LabStationPanel.exe`.

## Run tests

FMU Executor tests run on any supported Python environment:

```powershell
python -m pip install -r fmu-executor\requirements.txt
python -m pip install pytest httpx
python -m pytest fmu-executor\tests -q
```

Run the AHK tests with an AutoHotkey v2 executable. The list matches the CI
smoke-test matrix:

```powershell
$ahk = 'C:\Program Files\AutoHotkey\v2\AutoHotkey64.exe'
$env:AHK_EXE = $ahk
$tests = @(
  'labstation\tests\WizardActionCallbacksTests.ahk',
  'labstation\tests\IntegrationContractTests.ahk',
  'labstation\tests\ReservationFlowTests.ahk',
  'labstation\tests\CommandQueueTests.ahk',
  'labstation\tests\SessionGuardTests.ahk',
  'labstation\tests\RecoveryTests.ahk',
  'labstation\tests\PowerManagerTests.ahk',
  'labstation\tests\ServiceManagerTests.ahk',
  'labstation\tests\FmuExecutorTests.ahk',
  'labstation\tests\TelemetryTests.ahk',
  'controller\tests\SmokeTest_DualAppMode.ahk',
  'controller\tests\ArgumentParsingTests.ahk'
)
foreach ($test in $tests) {
  .\scripts\run-ahk-test.ps1 $test
  if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
}
```

## Release contents and sidecars

The release workflow publishes `LabStation.exe`, `LabStationPanel.exe`,
`AppControl.exe`, `WindowSpy.exe`, and the branding image. The Python FMU
Executor is intentionally a separately deployed internal sidecar: copy the
`fmu-executor/` directory, install its requirements, configure the machine
environment variables, and start it through the Lab Station supervisor. See
[`FMU Executor`](../fmu-executor/README.md) for its port, token, API, and
provisioning rules.

Never commit or pass passwords and internal tokens through source files,
public URLs, shell history, or unprotected command arguments. Prefer the setup
wizard and machine-level secret configuration, and store Gateway credentials
in its protected credential store.
