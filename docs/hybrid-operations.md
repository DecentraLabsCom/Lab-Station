# Operational rules for hybrid stations (local users)

This document summarizes what to expect when a station can be used both locally (by students, instructors, or other on-site users) and remotely (reservation via Lab Gateway).

## 1. Key principles

- Remote reservations require a clean remote session. Prepare considers every active local console session, including one signed in as LABUSER. Dedicated stations refuse them; hybrid stations evict them only when `AllowLocalSessionEviction` is enabled in `labstation/data/station-profile.ini` (defaults to `true`).
- Prepare shows a Windows session dialog to each eligible local user. Each user
  must confirm that their work is saved before Prepare may close the session.
  The 90-second default grace deadline starts with the dialog (30-second
  minimum); after confirmation, the remaining time is left for voluntary
  sign-out. A decline, timeout, unavailable dialog, or suppressed notification
  aborts Prepare before logoff and cleanup while the session remains active; a
  user who signs out during the dialog is already released.
- If a local user signs out during the remaining grace period, Prepare accepts
  that voluntary sign-out and only considers sessions still present for
  eviction. A new or changed local session during the grace period causes
  Prepare to refuse before it logs off any session.
- `--no-guard` is an explicit administrative bypass that skips confirmation and
  grace, then immediately evicts an eligible local session when policy allows.
  `--guard-notify=no` does not bypass the confirmation requirement and fails
  safely if a local session is active.
- All forced logoffs are recorded in `labstation/labstation.log` and `data/telemetry/session-guard-events.jsonl`, and the latest event is reflected in `status.json`.
- Dedicated stations refuse preparation if an unexpected interactive user is active; they do not log that user out automatically.

## 2. Recommended flow

1. **Local user on site**
   - They can sign in with their usual account; the hybrid profile does not configure LABUSER autologon.
   - If a remote reservation prompt appears, they can decline or keep the
     session open to cancel Prepare. To proceed, they save their work and
     affirmatively confirm; they may sign out during the remaining grace time.
2. **Backend prepares the remote reservation**
   - Lab Gateway runs `prepare-session` (via WinRM or queue). This command now invokes `session guard` automatically.
   - After eviction, Prepare clears LABUSER's temporary files, cache, Recent items, Downloads and `Documents\LabStationScratch`, restarts an installed FMU Executor to terminate its sessions, and removes its temporary work state.
3. **Remote reservation in progress**
   - Lab Gateway connects using LABUSER, which is a Remote Desktop Users account but is not automatically logged on by the hybrid profile. Local users should not sign in while remote reservations are active.
4. **Reservation end**
   - `release-session` signs out only LABUSER's remote RDP sessions, preserving a physical console session even when it also uses LABUSER. It does not reboot unless `--reboot` is explicitly supplied; a requested reboot is deferred while a local console session remains active.

## 3. Grace parameters and messages

- `prepare-session --guard-grace=<seconds>`: total deadline from showing the
  first confirmation dialog through forced logoff (90 seconds by default;
  values below 30 are clamped to 30). Confirmation time counts against it.
- `prepare-session --guard-message="text"`: custom text shown to the
  local user.
- `prepare-session --guard-silent` or `--guard-notify=no`: suppresses the
  confirmation dialog. If a local session is active, Prepare fails safely
  before logoff or cleanup.
- `prepare-session --no-guard`: explicit administrative bypass that skips
  confirmation and grace, then immediately evicts eligible local console
  sessions if hybrid eviction is enabled. It does not let Prepare continue
  with a conflicting session still active.
- `session guard --grace=<seconds>` and `session guard --message="text"` are
  the corresponding options when invoking the guard directly. Use
  `session guard --silent` or `--no-notify` for a silent direct invocation.
  The standalone guard defaults to 120 seconds.

The `prepare-session` parameters can be passed through the queue as
`guard-grace=60`, `guard-message=Remote reservation confirmed`, and
`guard-notify=no`. Direct `session-guard` queue entries use `grace`, `message`,
and `notify` instead.

Set `[Station] AllowLocalSessionEviction=false` in
`labstation/data/station-profile.ini` to make hybrid Prepare fail safely while
a local console session is active. The default is `true`, matching Linux's
`station.allow_local_session_eviction` setting. The setting has no effect on a
dedicated profile, where Prepare always refuses an unexpected local session.

## 4. "Local mode" signaling

- The backend or the desktop panel can create `labstation/data/local-mode.flag`
  when a local user declares exclusive in-person use. Local mode is only
  available for the hybrid profile and expires after eight hours unless it is
  disabled earlier. Lab Station and Lab Gateway both block preparation while
  the flag is active. Enabling local mode also requires a successful session
  inventory and no active reservation or remote LABUSER session.
- A marker with an invalid or unrecognized timestamp remains active until an
  operator clears it. Its file modification time is not used to infer expiry.
- `status.json`/`telemetry/heartbeat.json` expose `localModeEnabled` so
  dashboards can reflect the state. The flag is checked by both the Station
  command and Gateway operator paths.

The same state is visible in the Lab Station desktop panel. The **Local mode
(on-site)** action toggles the flag, and the status report shows whether the
station is currently reserved for local use. The screenshot is illustrative;
the displayed host and health values are taken from the workstation used to
capture it.

![Lab Station local-mode status](images/labstation-main-panel.png)

*The desktop panel exposes local-mode status alongside the station health summary.*

## 5. Best practices for local users

- Follow the schedule/calendar published by Lab Gateway.
- Save work frequently when a reservation start is approaching.
- Use the Gateway power action when the station should be powered off; `release-session` ends remote LABUSER RDP sessions but does not reboot by default.
- Report recurring eviction messages so reservation windows can be tuned.

## 6. Suggested messaging

Poster or email copy:

> “This station is part of the remote lab. When you see a warning that a reservation is about to begin, save your work and log out. After ~90 seconds the session will close automatically to allow remote access.”

These rules help hybrid stations keep sessions clean without ruling out occasional in-class use.

## 7. Audit and telemetry

- Each eviction adds a JSON line to `labstation/data/telemetry/session-guard-events.jsonl` with the user, session, and timestamp.
- `service-state.ini` retains the latest `lastForcedLogoff`, which also surfaces inside `status.json`.

## 8. Translating to the Gateway UI

The Gateway UI should use the typed `sessions` active-session summary together
with `localModeEnabled`, `summary.ready`, and `lastForcedLogoff` from the
status/heartbeat contracts. `sessions.localSessionActive` means that any
interactive physical-console session exists, including LABUSER; remote RDP
sessions are excluded regardless of account. Windows and Linux use that same
meaning for the dedicated Prepare precheck and station execution. Lab Station
refuses `prepare-session` while the local-mode flag is active and refuses to
enable the flag during an active reservation or remote LABUSER session.
