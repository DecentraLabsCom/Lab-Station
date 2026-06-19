# Changelog

# Changelog

## [3.0.7] - 2026-06-19

### Changed
- Setup wizard now runs account setup before autostart, followed by RemoteApp, WinRM, Wake-on-LAN, and diagnostics.

### Fixed
- Setup wizard now logs each step, skipped action, failure, and thrown exception, and failure dialogs point to `labstation.log`.

## [3.0.6] - 2026-06-19

### Fixed
- PowerShell command capture now uses a temporary command wrapper with correct Windows quoting, so setup verification can see real stdout/stderr.
- Hybrid setup validates `LABUSER` with `net user` fallback and logs concrete account/WinRM setup errors.

## [3.0.5] - 2026-06-19

### Fixed
- Restoring the Lab Station GUI from tray no longer reads a non-existent `Gui.Visible` property.

## [3.0.4] - 2026-06-19

### Fixed
- WinRM setup now uses 64-bit PowerShell, fallback local-user/group commands, and post-configuration readiness validation before reporting success.
- Hybrid autostart now fails clearly when `LABUSER` does not exist instead of writing a misleading conditional autostart entry.
- Account setup now verifies `LABUSER` exists before showing generated credentials.
- Diagnostics now resolve localized Remote Desktop Users membership by SID and track the selected station profile.

## [3.0.3] - 2026-06-19

### Added
- Setup wizard now configures WinRM for dedicated and hybrid stations, including the station-side Lab Gateway service account and readiness diagnostics.
- `LabStation.exe winrm configure|status` command for repeatable WinRM setup and inspection.

### Changed
- Lab Station and LabStationPanel build versions updated to 3.0.3.

## [3.0.0] - 2025-11-21

### Added
- Lab Station service loop with command queue, telemetry publishing, and status/heartbeat export (`status-json`, `service-loop`, tray UI).
- Session lifecycle helpers (`session guard`, `prepare-session`, `release-session`) with audit logging to JSONL and service-state.ini.
- Power management surface (`power shutdown|hibernate`) with wake validation/repair plus recovery safegaurd reboot command.
- Setup wizard split for pure server vs hybrid mode, account management helpers, energy audit reporting, and tray menu shortcuts.
- CI release flow now builds and publishes `LabStation.exe` and includes `WindowSpy.exe` alongside the controller artifact.
- Documentation refreshed in English for gateway UI, hybrid operations, telemetry consumption, WoL BIOS playbook, power controls, and WinRM contract.

## [2.4.0] - 2025-11-19

### Added
- `tests/ArgumentParsingTests.ahk` regression suite that runs through common and Guacamole-specific CLI permutations.
- GitHub Actions matrix (`tests.yml`) executes the parser suite on every push/pr to `main` for Windows coverage.

### Fixed
- Preserves quoting when reconstructing commands split by Guacamole or cmd.exe before adding kiosk flags or custom close options.
- Rejects malformed `@close-coords` mixes and ensures tab-title quotes survive trimming in dual mode.

## [2.3.0] - 2025-xx-xx
- Refer to the `v2.3` tag for historical details.
