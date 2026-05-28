# Schedules — Spec

> Multi-session feature. Recurring messages from Hermes on a user-defined cadence ("every 5 min update me on X and Y"), with push notifications and a foreground audible cue.

## Goal

User can say or create a schedule like "every 5 minutes give me the weather." Backend fires that schedule on cadence, runs the request through Hermes as if the user had asked it, and delivers the reply via push notification (background) or auto-play with an audible chime (foreground). Schedules are manageable from voice ("stop the weather updates") AND an in-app Schedules screen.

## Non-goals (v1)

- Calendar-based one-shot ("at 3pm tomorrow remind me…") — that's reminders, different shape.
- Conditional schedules ("only when I'm at home") — Geo / focus integration is a separate feature.
- Cross-user schedules / sharing.
- Schedule history / fire-by-fire audit trail beyond what already lands in `/api/sessions`.

## Product decisions (locked)

| Decision | Choice |
|---|---|
| Delivery | Push notification when backgrounded; auto-play with chime when foregrounded |
| Creation | Voice (Hermes tool) + in-app Schedules screen for edit/list/delete |
| Failure mode | Skip silently; record a "skipped: offline" history row |
| Cadence floor | 1 minute minimum; no upper bound |
| Chime | Custom 8-bit branded sound, ~300-500ms, used in both contexts |

## Architecture — three subsystems

```
┌─────────────────────┐    ┌──────────────────────┐    ┌─────────────────────┐
│  Schedule store +   │───▶│  Hermes turn         │───▶│  APNs delivery      │
│  cron executor      │    │  (existing path)     │    │  + iOS handler      │
│  (new)              │    │                      │    │  (new)              │
└─────────────────────┘    └──────────────────────┘    └─────────────────────┘
        ▲                                                       │
        │                                                       ▼
   ┌─────────┐                                            ┌──────────┐
   │ Hermes  │  (voice-created schedules via tool calls)  │   iOS    │
   │  tool   │                                            │  Schedules │
   │ surface │  ────────────────────────────────────────▶ │  screen  │
   └─────────┘                                            └──────────┘
```

Each subsystem can be developed in isolation. Phasing below.

## Data model

New SQLite store at `~/.hermes-voice/schedules.db` (do NOT reuse `~/.hermes/state.db` — that's Hermes's, we're a separate process). One table:

```sql
CREATE TABLE schedules (
  id                TEXT    PRIMARY KEY,           -- uuid4
  cadence_seconds   INTEGER NOT NULL,              -- enforced >= 60
  prompt            TEXT    NOT NULL,              -- what to ask Hermes when fired
  display_name      TEXT,                          -- short label, e.g. "Weather updates"
  created_at        REAL    NOT NULL,              -- unix timestamp
  last_fired_at     REAL,                          -- null until first fire
  next_fire_at      REAL    NOT NULL,              -- computed; cron loop reads this
  enabled           INTEGER NOT NULL DEFAULT 1,    -- 0 = paused, 1 = active
  consecutive_fails INTEGER NOT NULL DEFAULT 0,    -- for offline-skip logic
  source            TEXT    NOT NULL DEFAULT 'ios' -- 'ios' | 'voice' | future
);

CREATE INDEX schedules_next_fire ON schedules(next_fire_at) WHERE enabled = 1;
```

A separate table for device tokens (multiple phones / reinstalls land here):

```sql
CREATE TABLE devices (
  token             TEXT    PRIMARY KEY,           -- APNs hex device token
  platform          TEXT    NOT NULL,              -- 'ios' | 'watchos' (Watch unlikely)
  bundle_id         TEXT    NOT NULL,              -- dev.finklea.hermesvoice etc.
  environment       TEXT    NOT NULL,              -- 'sandbox' | 'production'
  registered_at     REAL    NOT NULL,
  last_seen_at      REAL    NOT NULL
);
```

## Backend endpoints (mirror existing patterns in `app/main.py`)

All require auth token via `Depends(_require_token)` like other `/api/*` routes.

| Method | Path | Purpose |
|---|---|---|
| `GET`    | `/api/schedules` | List all schedules. |
| `POST`   | `/api/schedules` | Create. Body: `{cadence_seconds, prompt, display_name?}`. |
| `PATCH`  | `/api/schedules/{id}` | Update any field (pause via `enabled=false`). |
| `DELETE` | `/api/schedules/{id}` | Remove. |
| `POST`   | `/api/devices` | Register / update APNs device token. Body: `{token, platform, bundle_id, environment}`. |
| `DELETE` | `/api/devices/{token}` | Unregister (called when iOS gets notification permission revoked). |

Response models: follow `SessionListItem` / `SessionDetailResponse` Pydantic pattern in `app/models.py`.

### Executor loop

New file `app/schedules.py`. One asyncio loop spawned from `create_app`'s lifespan handler:

```python
# Pseudocode — implementer should read existing app/main.py lifespan, audio_store.py for asyncio patterns

async def scheduler_loop(app: FastAPI):
    while True:
        due = await fetch_due_schedules(now=time.time())
        for s in due:
            asyncio.create_task(fire_schedule(app, s))
        await asyncio.sleep(5)  # 5s tick; cadence floor is 60s so this is fine
```

Per-fire flow:
1. Compute `next_fire_at = last_fired_at + cadence_seconds`. Update row.
2. Call existing `_run_turn(app, user_text=schedule.prompt, session_id=None, source='schedule')`. That writes to Hermes session DB normally.
3. On success: reset `consecutive_fails=0`. On failure: increment; if > 5, disable the schedule and log.
4. After turn completes: build push payload (title="Hermes", body=truncated assistant_text, sound="hermes-chime.caf", custom data `{session_id, schedule_id}`). Send to every registered device token. Drop tokens APNs reports as Unregistered.

`_run_turn` needs a small change: accept an optional `source` kwarg and thread it through to the Hermes session metadata.

## Hermes tool surface (voice creation/cancel)

Hermes needs three new MCP-style tools to manipulate schedules:

| Tool | Args | Purpose |
|---|---|---|
| `create_schedule` | `cadence_seconds: int, prompt: str, display_name?: str` | Creates a schedule. Returns the created object. |
| `list_schedules`  | (none) | Returns array of `{id, display_name, cadence_seconds, prompt, enabled}`. |
| `delete_schedule` | `id: str` or `display_name_match: str` | Deletes by id or fuzzy name match. |

These tools POST/GET/DELETE against the backend endpoints above. The backend already has auth; Hermes calls localhost so use a shared loopback secret. Tool registration is **Hermes-side work** — out of scope for this app's repo, but the tools are what makes voice creation work. Add a note in the spec deliverable that the user wires these into Hermes Agent.

### Voice grammar examples (Hermes interprets, we don't parse)

- "Every 5 minutes give me the weather" → `create_schedule(cadence_seconds=300, prompt="give me the weather", display_name="weather updates")`
- "Every 2 hours check my unread emails" → `create_schedule(cadence_seconds=7200, prompt="check unread emails", display_name="unread email check")`
- "Stop the weather updates" → `delete_schedule(display_name_match="weather")` (Hermes infers from `list_schedules` first)
- "What's scheduled?" → `list_schedules()` then prose summary

## iOS surface

### New screen — `Views/SchedulesView.swift`

Reachable from Settings → "Schedules" row (or new icon in MainView toolbar — decide during build). Layout:

- List of schedules using the same brand chrome as HistoryView (terminal-log rows).
- Each row: display_name (cream), cadence ("every 5 min", bronze caption), prompt (small dim), enabled toggle (amber Switch).
- Tap row → edit sheet (cadence picker — 1/5/15/30 min/hourly/2h/6h/daily; prompt TextEditor; display_name TextField; delete button).
- Floating "+" amber button to create from app.
- Empty state: "No schedules yet. Hold the mic and ask Hermes to set one up — or tap +."

### Notification handling — new `Services/NotificationManager.swift`

- `registerForRemoteNotifications()` called from `HermesVoiceApp.init` after permission granted.
- Implement `UNUserNotificationCenterDelegate.userNotificationCenter(_:willPresent:withCompletionHandler:)` — when notification arrives while app is foreground, suppress the system banner and instead route into the foreground chime+TTS path (open the relevant session, play chime, play audio).
- `userNotificationCenter(_:didReceive:)` for taps when backgrounded: open the app to that session, optionally play audio if user enabled "Auto-play tapped" in Settings.

### Foreground auto-play flow

Triggered when a push arrives while the app is foregrounded (or when the existing live mic flow is idle and the user opted into "auto-play scheduled fires"):

1. `AudioPlayer.playChime(named: "hermes-chime")` — plays bundled .caf.
2. `await Task.sleep(0.3s)` — small gap so chime + TTS don't smear.
3. Existing audio streaming path: fetch `/api/audio/<id>` and play through AVPlayer like any other reply.
4. Transcript: appended to `conversation.messages` as a system-initiated turn, marked with a small "⏰ scheduled" badge in the hero pane just-arrived state.

### Settings additions

New "Notifications" section:
- "Allow notifications" — opens iOS Settings if denied.
- "Auto-play scheduled fires when app open" — toggle, default ON.
- "Foreground chime" — toggle, default ON. (Off only for the brave.)

## APNs setup (user task — required before Phase 4 lands)

Spec needs the user to do these before push works:

1. Apple Developer → Certificates, Identifiers & Profiles → Keys → "+"
2. Enable "Apple Push Notifications service (APNs)" → Continue → Register.
3. Download the `.p8` key file. **One-time download — Apple never re-issues it.**
4. Note the Key ID (10 chars) and Team ID (10 chars).
5. Put the `.p8` in `~/.hermes-voice/apns-key.p8`. Add absolute path + Key ID + Team ID + bundle ID (`dev.finklea.hermesvoice`) to backend env (`APNS_KEY_PATH`, `APNS_KEY_ID`, `APNS_TEAM_ID`, `APNS_BUNDLE_ID`, `APNS_ENV=sandbox|production`).
6. Add `aioapns` to backend dependencies.

For TestFlight + production: same key works for both; only the `APNS_ENV` setting changes.

## Chime asset

`backend/assets/chime/hermes-chime.caf` — generated, NOT hand-recorded:
- 300ms duration
- 8-bit lo-fi character: square-wave ascending arpeggio (E5 → A5 → C#6, 100ms each)
- Subtle ADSR envelope so it doesn't click
- Generated via Python (`numpy` + write WAV → ffmpeg/afconvert to CAF) committed once, deliverable.

Bundled twice:
- iOS: `HermesVoice/Resources/hermes-chime.caf` for foreground playback.
- Backend → APNs notification payload references `"sound": "hermes-chime.caf"` so the notification arrival sound matches.

Same source file in both places — keep in sync.

## Phase sequencing — what to build in what order

**Phase A — Schedule store + cron + in-app UI (no push yet)** (1-2 sessions)
- `backend/app/schedules.py` (store + asyncio loop) + endpoints.
- iOS `SchedulesView.swift` + create/edit/delete via HermesVoiceAPI.
- Test: create a 1-min schedule via UI, verify it fires (turn appears in `/api/sessions`), verify cron tick math, verify pause + delete. No notifications yet — just look in History.

**Phase B — APNs delivery + foreground chime** (1 session)
- User completes the APNs setup (one-time, ~10 min on their side).
- Backend: aioapns integration, device-token endpoints, push on fire.
- iOS: notification permission flow, device-token POST on launch, custom sound bundled, foreground delegate routes to chime + auto-play.
- Generate the chime .caf file (Python synthesis).
- Test: schedule fires → notification on lock screen with chime → tap opens app to that session and plays audio. Foreground: chime → reply audio.

**Phase C — Hermes tool integration (voice creation)** (cross-system, spans this repo + Hermes repo)
- Define the three tool shapes (`create_schedule`, `list_schedules`, `delete_schedule`).
- Backend: harden the endpoints for localhost-loopback access (no per-tool token, just trust loopback + secret header).
- Hermes-side: register the tools (this is in the Hermes Agent codebase, NOT here).
- Test: say "every 5 min give me the weather" → verify Hermes calls tool → verify backend creates schedule → verify it fires.

## Acceptance — schedules feature is "done" when

- [ ] Voice command "every 5 minutes give me the weather" creates a schedule
- [ ] The schedule fires every 5 min and each fire shows up in History
- [ ] Phone receives a push notification with the Hermes chime when each fire completes
- [ ] Tapping the notification opens the app to the right session and plays the audio
- [ ] If the app is foreground, the chime + reply audio play automatically without notification
- [ ] Voice command "stop the weather updates" deletes the schedule
- [ ] In-app Schedules screen lists active schedules and lets me edit/pause/delete any of them
- [ ] If Hermes is offline when a schedule fires: skip recorded in History, no false push, schedule resumes next cycle
- [ ] Schedule survives backend restart (next_fire_at recalculated on startup)

## Verify

After all phases:
- `curl -X POST http://stiletto.local:8765/api/schedules -H "Authorization: Bearer $TOKEN" -d '{"cadence_seconds":60,"prompt":"say hello","display_name":"test"}'`
- Wait 3 minutes, watch for 3 push notifications.
- `curl http://stiletto.local:8765/api/sessions` shows 3 new sessions with `source="schedule"`.
- `curl -X DELETE http://stiletto.local:8765/api/schedules/<id>` removes it; no further fires.

## Open questions / future work

- **Watch involvement**: watchOS forwards iPhone notifications by default — should be fine without a custom Watch handler. Validate when testing.
- **Multiple devices**: if you install on two phones, both get the push. Probably what you want (redundancy) but worth checking. Could be a per-schedule "deliver to" toggle.
- **Quiet hours**: "don't fire schedules between 11pm and 7am" — could be a Settings toggle later. Not in scope.
- **Token rotation**: APNs tokens change occasionally (reinstall, restore from backup). The `/api/devices` POST is upsert so this should just work; defensive test only.

## Tier hint

- Phase A: Sonnet — multi-file but mostly mechanical (CRUD + cron loop + UI list)
- Phase B: Sonnet → Opus — APNs setup is finicky; need Opus only if the wiring drifts
- Phase C: Opus — cross-codebase, Hermes-side tool registration is unfamiliar territory

## Implementation notes — patterns to mirror

- Backend route shape: see `_register_routes` in `backend/app/main.py:104` for the `Depends(_require_token)` + `response_model` idiom.
- SQLite access: `backend/app/sessions.py` shows the `aiosqlite` async cursor pattern. Mirror it.
- iOS API client: extend `HermesVoiceAPI` with `listSchedules() / createSchedule() / deleteSchedule()` following the existing `listSessions() / getSession()` patterns.
- iOS UI: new SchedulesView should reuse `HVColor`, `HVFont`, the brand row treatment from the redesigned HistoryView. Don't recreate styling.
