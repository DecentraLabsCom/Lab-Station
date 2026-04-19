# Changelog

# Changelog

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
