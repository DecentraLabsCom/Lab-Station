# Operational rules for hybrid stations (instructors)

This document summarizes what to expect when a station can be used both locally (instructor in the classroom) and remotely (reservation via Lab Gateway).

## 1. Key principles

- Remote reservations always take precedence: before exposing the station through RemoteApp, Lab Station automatically runs `session guard` to evict local sessions.
- The instructor receives a `msg` warning on screen that explains the reason and includes a configurable countdown (default 90 seconds) before the session is signed out.
- If the instructor ignores the warning, the system forces the logoff to ensure the remote session starts with a clean state.
- All forced logoffs are recorded under `labstation/logs` and reflected in `status.json` (`sessions.otherUsers`).

## 2. Recommended flow

1. **Instructor in local mode**
   - They can sign in with their usual account.
   - If a remote reservation warning appears, they must save their work and sign out manually before the countdown expires.
2. **Backend prepares the remote reservation**
   - Lab Gateway runs `prepare-session` (via WinRM or queue). This command now invokes `session guard` automatically.
   - After eviction, LABUSER’s temp files, caches, and logs are cleaned.
3. **Remote reservation in progress**
   - Only LABUSER remains signed in (autologon). The instructor should not sign in while remote reservations are active.
4. **Reservation end**
   - `release-session --reboot` closes controller processes, signs out LABUSER, and optionally reboots.

## 3. Grace parameters and messages

- `--guard-grace=<seconds>`: time to wait before forcing logoff (90 default).
- `--guard-message="text"`: custom text shown to the instructor.
- `--guard-silent`: skips the warning and forces an immediate logoff (use only in emergencies).

These parameters can be passed to `prepare-session` via CLI or queue (e.g., `guard-grace=60`, `guard-message=Remote reservation confirmed`).

## 4. "Local mode" signaling

- The backend can create `labstation/data/local-mode.flag` when an instructor declares exclusive in-person use. While this file exists, remote reservations should be blocked or require manual confirmation.
- `status.json`/`telemetry/heartbeat.json` expose `localModeEnabled` so dashboards can reflect the state.

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

Pair these rules with `labstation/docs/gateway-ui-guidelines.md`, which details how to surface warnings, local-use toggles, and `session guard` quick actions directly in the Gateway frontend.
