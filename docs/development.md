# Development, build and verification

## Prerequisites

- Windows with PowerShell 5.1 or newer.
- AutoHotkey v2.0.29 for running the source tests and compiling the AHK
  executables. The CI workflow uses this exact version.
- Python 3.11 or newer for the FMU Executor. CI tests Python 3.11, 3.12, and
  3.13.
- Administrator privileges for setup, WinRM, registry, firewall, scheduled
  task, and power-management operations.

## Build the Windows executables

From the repository root, `build.ps1` discovers Ahk2Exe and the AutoHotkey v2
base runtime, then writes these development outputs to the repository root:

```powershell
.\build.ps1
.\build.ps1 -Clean
```

If AutoHotkey is installed elsewhere, set `AHK2EXE_PATH` for the compiler and
`AHK_BASE_PATH` (or `AHK_EXE`) for the base runtime. The build produces
`AppControl.exe`, `LabStation.exe`, and `LabStationPanel.exe` at the repository
root. The setup wizard moves the launcher into the canonical
`remote-app\AppControl.exe` location, and release packaging places it there
directly.

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
  'labstation\tests\JsonParserTests.ahk',
  'labstation\tests\ReservationFlowTests.ahk',
  'labstation\tests\ControllerCloseRequestTests.ahk',
  'labstation\tests\CommandQueueTests.ahk',
  'labstation\tests\SessionGuardTests.ahk',
  'labstation\tests\RecoveryTests.ahk',
  'labstation\tests\PowerManagerTests.ahk',
  'labstation\tests\ServiceManagerTests.ahk',
  'labstation\tests\FmuExecutorTests.ahk',
  'labstation\tests\TelemetryTests.ahk',
  'remote-app\tests\SmokeTest_DualAppMode.ahk',
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
`Lab-Station.zip` package. The local `build.ps1` output puts `AppControl.exe`
at the repository root so the wizard can use it as a migration source; the
release packaging step moves it to `remote-app\AppControl.exe`. Extracting the
package creates a `Lab Station/` directory containing `LabStation.exe`,
`LabStationPanel.exe`, `WindowSpy.exe`, the `remote-app\AppControl.exe`
launcher, the branding image, and the FMU Executor runtime under
`fmu-executor/`. The sidecar bundle includes a private Python interpreter and
its application dependencies, but not FMU model data or the test suite. Copy
this directory to a station as one unit. Configure the machine environment
variables and start the sidecar through the Lab Station supervisor. No separate
Python installation is needed. See the [FMU Executor runtime guide](fmu-executor-runtime.md)
for its port, token, firewall, and provisioning rules.

Never commit or pass passwords and internal tokens through source files,
public URLs, shell history, or unprotected command arguments. Prefer the setup
wizard and machine-level secret configuration, and store Gateway credentials
in its protected credential store.
