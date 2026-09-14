# Operational rules for hybrid stations (instructors)

This document summarizes what to expect when a station can be used both locally (instructor in the classroom) and remotely (reservation via Lab Gateway).

## 1. Key principles

- Remote reservations require a clean remote session: `prepare-session` automatically runs `session guard` unless `--no-guard` is supplied.
- The instructor receives a `msg` warning on screen that explains the reason and includes a configurable countdown (90 seconds by default for `prepare-session`; 120 seconds for standalone `session guard`) before the session is signed out.
- If the instructor ignores the warning, the system forces the logoff to ensure the remote session starts with a clean state.
- All forced logoffs are recorded in `labstation/labstation.log` and `data/telemetry/session-guard-events.jsonl`, and the latest event is reflected in `status.json`.

## 2. Recommended flow

1. **Instructor in local mode**
   - They can sign in with their usual account; the hybrid profile does not configure LABUSER autologon.
   - If a remote reservation warning appears, they must save their work and sign out manually before the countdown expires.
2. **Backend prepares the remote reservation**
   - Lab Gateway runs `prepare-session` (via WinRM or queue). This command now invokes `session guard` automatically.
   - After eviction, LABUSER’s temp files, caches, and logs are cleaned.
3. **Remote reservation in progress**
   - Lab Gateway connects using LABUSER, which is a Remote Desktop Users account but is not automatically logged on by the hybrid profile. The instructor should not sign in while remote reservations are active.
4. **Reservation end**
   - `release-session --reboot` closes controller processes, signs out LABUSER, and optionally reboots.

## 3. Grace parameters and messages

- `--guard-grace=<seconds>`: time to wait before forcing logoff when passed to `prepare-session` (90 default; values below 30 are clamped to 30).
- `--guard-message="text"`: custom text shown to the instructor.
- `--guard-silent` / `--guard-notify=no`: suppresses the warning; it does not skip the grace period. Use `--guard-grace=30` for the shortest supported wait.

These parameters can be passed to `prepare-session` via CLI or queue (e.g., `guard-grace=60`, `guard-message=Remote reservation confirmed`).

## 4. "Local mode" signaling

- The backend can create `labstation/data/local-mode.flag` when an instructor declares exclusive in-person use. Lab Station exposes the flag; Lab Gateway must enforce the policy by blocking or requiring manual confirmation for remote reservations.
- `status.json`/`telemetry/heartbeat.json` expose `localModeEnabled` so dashboards can reflect the state.

The same state is visible in the Lab Station desktop panel. The **Local mode
(on-site)** action toggles the flag, and the status report shows whether the
station is currently reserved for local use. The screenshot is illustrative;
the displayed host and health values are taken from the workstation used to
capture it.

![Lab Station local-mode status](images/labstation-main-panel.png)

*The desktop panel exposes local-mode status alongside the station health summary.*

## 5. Best practices for instructors

- Follow the schedule/calendar published by Lab Gateway.
- Save work frequently when a reservation start is approaching.
- Never power the station off manually; `release-session --reboot` already ensures a clean reboot.
- Report recurring eviction messages so reservation windows can be tuned.

## 6. Suggested messaging

Poster or email copy:

> “This station is part of the remote lab. When you see a warning that a reservation is about to begin, save your work and log out. After ~90 seconds the session will close automatically to allow remote access.”

These rules help hybrid stations keep sessions clean without ruling out occasional in-class use.

## 7. Audit and telemetry

- Each eviction adds a JSON line to `labstation/data/telemetry/session-guard-events.jsonl` with the user, session, and timestamp.
- `service-state.ini` retains the latest `lastForcedLogoff`, which also surfaces inside `status.json`.

## 8. Translating to the Gateway UI

The Gateway UI should use the public `localModeEnabled`, `localSessionActive`,
`summary.ready`, and `lastForcedLogoff` fields from the status/heartbeat
contracts. The local-mode flag is a policy signal; Lab Station does not itself
reject a reservation based on that flag.
