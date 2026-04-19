# Lab Gateway UI Guidelines (Pure Server vs Hybrid Station)

The Gateway frontend must make it clear which mode each host operates in and what actions the instructor/operator needs to take. This guide summarizes the essential components based on the signals Lab Station publishes.

**Implementation status**: Lab Manager UI (`web/lab-manager/`) implements these guidelines with real-time host management.

## 1. Visible states on each host card

| UI Field | Source | Behavior |
| --- | --- | --- |
| **Mode** (`Pure Server` / `Hybrid Station`) | Inventory configuration | Static value defined when the host is onboarded, but tooltips can call out the operational differences. |
| **Local usage declared** | `status.localModeEnabled` (`heartbeat.json`) | Show a "Local use" switch or badge that only the instructor or support can toggle. While active, block incoming reservations or require manual confirmation. |
| **Active local session** | `status.localSessionActive` | Label "Instructor connected" and offer a "Force `session guard`" button (triggers the remote command). |
| **Last `session guard`** | `operations.lastForcedLogoff` + `session-guard-events.jsonl` | Display timestamp, evicted user, and used message. If the timestamp is far before the next reservation, prompt running another guard. |
| **Overall health** | `summary.ready` + `status.summary.message` | Green/amber/red badge. Highlight RemoteApp/WoL readiness on hybrids before opening reservations. |

## 2. Flow to toggle local mode

1. Instructor taps "I'm using this station locally" in the UI.
2. Gateway creates/deletes `labstation/data/local-mode.flag` (via WinRM or queue) and refreshes `heartbeat.json`.
3. While the flag exists, the calendar should warn that the host is blocked from remote reservations.
4. When finished, the instructor turns off the toggle or the operator runs `session guard` before clearing the host.

## 3. Contextual nudges and alerts

- **Remote reservation start:** If `localSessionActive=true` at T-5 minutes, show an alert plus an "Evict with warning (90s)" button that sends `prepare-session --guard-grace=90`.
- **Recent evictions:** When `operations.lastForcedLogoff.timestamp` changes, fire a toast featuring the evicted user name and allow copying the justification (`message` text).
- **Maintenance required:** If `summary.ready=false`, replace action buttons with a CTA like "Run recovery" or "Open ticket".

## 4. Mode differentiators

| Aspect | Pure Server | Hybrid Station |
| --- | --- | --- |
| Autologon | Always enabled under LABUSER | Same, but occasional physical presence is expected. |
| Controller autostart | Global (HKLM) | Can be scoped to LABUSER; the UI should note this. |
| Expected conflicts | Low; no local users should be present | High: show reminders and keep `session guard` controls visible. |
| Signage/notifications | Technician-only | Surface a copy of the notice to the instructor directly in the UI (copyable). |

## 5. Recommended quick actions

Lab Manager implements these as direct buttons in the host card:

- `Prepare session` → `POST /ops/api/winrm` with command `prepare-session` (includes `session guard`).
- `Release session` → `POST /ops/api/winrm` with command `release-session --reboot`.
- `Force immediate eviction` → command `session guard --guard-grace=30 --guard-silent` (support only).
- `Mark local usage` → Creates `local-mode.flag` (stored in browser localStorage, toggles reservation blocking).
- `Shutdown after reservation` → command `power shutdown --delay=60 --reason="Reservation completed"`.
- `Wake` → `POST /ops/api/wol` with retry validation.
- `Heartbeat` → `POST /ops/api/heartbeat/poll` to refresh status instantly.

## 6. Text snippets for the UI

- Hybrid tooltip: “This station can be used locally. Before every remote reservation run `session guard` to evict local sessions.”
- Local use activation message: “While this is active we will block remote reservations and mark the station as Occupied.”
- Eviction toast: “Evicted {user} at {timestamp}. Message shown: '{message}'."

With these elements, the UI guides instructors and support without forcing them to parse telemetry files manually.
