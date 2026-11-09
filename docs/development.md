# Development, build and verification

## Prerequisites

- Windows with PowerShell 5.1 or newer.
- AutoHotkey v2.0.31 for running the source tests and compiling the AHK
  executables. The CI workflow uses this exact version.
- Python 3.12 or newer for the FMU Executor. CI tests Python 3.12 and 3.13.
- Administrator privileges for setup, WinRM, registry, firewall, scheduled
  task, and power-management operations.

## Build the Windows executables

From the repository root, `build.ps1` discovers Ahk2Exe and the AutoHotkey v2
base runtime. It writes AppControl to its canonical `remote-app` directory and
the Lab Station executables to the repository root:

```powershell
.\build.ps1
.\build.ps1 -Clean
```

If AutoHotkey is installed elsewhere, set `AHK2EXE_PATH` for the compiler and
`AHK_BASE_PATH` (or `AHK_EXE`) for the base runtime. The build produces
`remote-app\AppControl.exe`, `LabStation.exe`, and `LabStationPanel.exe`.
Release packaging takes the launcher from `remote-app\AppControl.exe` and
places it at the same canonical path in the package.

## Run tests

FMU Executor is maintained in its canonical sibling checkout, not duplicated
under Lab Station. For local development, point `FMU_EXECUTOR_SOURCE` to that
checkout (or use the adjacent `..\FMU-Executor` directory):

```powershell
if (-not $env:FMU_EXECUTOR_SOURCE) { $env:FMU_EXECUTOR_SOURCE = (Resolve-Path '..\FMU-Executor').Path }
python -m pip install -r "$env:FMU_EXECUTOR_SOURCE\requirements.txt"
python -m pip install pytest httpx
python -m pytest "$env:FMU_EXECUTOR_SOURCE\tests" -q
```

CI and release builds check out the exact commit recorded in
`fmu-executor/SOURCE.lock.json`; use `scripts/verify-shared-fmu-executor.ps1`
to verify that pin locally. To approve a new reviewed pin, run the same script
with `-UpdatePin` against a clean canonical checkout. Local Station runs can
launch source mode by setting `FMU_EXECUTOR_SOURCE_DIR` to the checkout path.

Run the AHK tests with an AutoHotkey v2 executable. The list matches the CI
smoke-test matrix:

```powershell
$ahk = 'C:\Program Files\AutoHotkey\v2\AutoHotkey64.exe'
$env:AHK_EXE = $ahk
$tests = @(
  'labstation\tests\WizardActionCallbacksTests.ahk',
  'labstation\tests\IntegrationContractTests.ahk',
  'labstation\tests\JsonParserTests.ahk',
  'labstation\tests\ParityMatrixTests.ahk',
  'labstation\tests\ReservationFlowTests.ahk',
  'labstation\tests\ControllerCloseRequestTests.ahk',
  'labstation\tests\CommandQueueTests.ahk',
  'labstation\tests\SessionGuardTests.ahk',
  'labstation\tests\RecoveryTests.ahk',
  'labstation\tests\PowerManagerTests.ahk',
  'labstation\tests\ServiceManagerTests.ahk',
  'labstation\tests\FmuExecutorTests.ahk',
  'labstation\tests\TelemetryTests.ahk',
  'remote-app\tests\WorkspaceModeTests.ahk',
  'labstation\tests\RemoteAppWorkspaceStoreAclTests.ahk',
  'remote-app\tests\ArgumentParsingTests.ahk'
)
foreach ($test in $tests) {
  .\scripts\run-ahk-test.ps1 $test
  if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
}
```

## Release contents and sidecars

The release workflow publishes the individual `LabStation.exe`,
`LabStationPanel.exe`, `AppControl.exe`, and `WindowSpy.exe` assets, plus a
`Lab-Station.zip` package. AppControl is built and staged at
`remote-app\AppControl.exe`. Extracting the package creates a `Lab Station/`
directory containing `LabStation.exe`,
`LabStationPanel.exe`, `WindowSpy.exe`, the `remote-app\AppControl.exe`
launcher, the branding image, and the optional FMU Executor under
`fmu-executor/`. Copy the package to a station as one unit. For the sidecar's
contents and lifecycle, see [FMU Executor on Windows Lab Station](fmu-executor.md);
the [shared FMU Executor documentation](https://github.com/DecentraLabsCom/FMU-Executor)
covers runtime configuration and behavior.

Never commit or pass passwords and internal tokens through source files,
public URLs, shell history, or unprotected command arguments. Prefer the setup
wizard and machine-level secret configuration, and store Gateway credentials
in its protected credential store.
