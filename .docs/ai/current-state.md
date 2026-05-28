# Current State

> Updated at the end of every work session. Read this first.

## Active Branch

`main` — working tree clean (all work committed). Recent: `0b204e1` Live Activity (2026-05-28), `6b91d4e` schedules/APNs fixes (2026-05-28), `7d3a94b` initial.

## Last Session Summary

**Date**: 2026-05-28

- Shipped the SwiftUI redesign ("E · Focus / Now-Playing — deepened") across all six screens; new icon and brand design system.
- Scoped and shipped all three schedule phases per `.docs/ai/phases/schedules-spec.md`.
- **Phase A** (store + cron + in-app UI): SQLite at `~/.hermes-voice/schedules.db`, 5s-tick asyncio executor in lifespan, `/api/schedules` CRUD, iOS SchedulesView.
- **Phase B** (APNs + chime + foreground auto-play): `app/push.py` with aioapns, devices table + `/api/devices` register/unregister, `Services/NotificationManager.swift` + `ChimePlayer.swift` + `AppDelegate.swift`, bundled `hermes-chime.caf` (8-bit ascending arpeggio, ~330ms), new Settings toggles for notifications/auto-play/chime.
- **Phase C** (Hermes voice integration): stdio MCP server at `app/mcp_schedules.py` exposing `create_schedule / list_schedules / delete_schedule`. Defaults to TLS verify=true with `HERMES_VOICE_CA_BUNDLE` env for custom CAs (security hook caught the original `verify=False` lazy default and rightly flagged it). User-facing setup guide at `backend/docs/schedules-setup.md`.
- Dropped wake-word (Apple won't grant background mic to indie apps; Siri shortcut covers lock-screen).
- **Live Activity / Dynamic Island** (commit `0b204e1`, 2026-05-28): ActivityKit local-update controller (`LiveActivityController`), shared `HermesActivityAttributes`, new widget-extension target (`HermesVoiceWidget`) rendering lock-screen + Dynamic Island (compact/expanded/minimal). Driven from `ConversationViewModel.syncLiveActivity()` (thinking/speaking; recording excluded) and `NotificationManager` for scheduled-fire auto-play. v1 informational — tap opens app; interactive stop is v2 per spec. Known follow-up: `finish()` fire-and-forget teardown can transiently double-up activities on rapid barge-in (see Known Limits).
- Roadmap backlog still has: Bonjour/mDNS discovery + onboarding, CarPlay (entitlement probe first), redesign polish threads (on-device walkthrough, scrollback expand, ActionCard variants, voice picker).

## Build Status

Re-verified 2026-05-28 (post-Live-Activity commit `0b204e1`):
- Backend: `uv run pytest` (synced with `uv sync --extra dev`, **not** `--all-extras` — that pulls faster-whisper and breaks the "no STT configured" assertions) → **41/41 passing** (10 Phase A + 6 Phase B + 5 Phase C MCP + 20 pre-existing). Live Activity was iOS-only; backend unchanged.
- iOS: `xcodegen generate && xcodebuild -project HermesVoice.xcodeproj -scheme HermesVoice -destination 'generic/platform=iOS Simulator' build CODE_SIGNING_ALLOWED=NO` → **BUILD SUCCEEDED** — app + embedded Watch + new `HermesVoiceWidget.appex`. `HermesActivityAttributes` compiles into both app and widget targets (no dup-symbol / missing-type).
- App icon updated, chime bundled in app bundle, all UI toolbars match brand.
- Schedules confirmed working end-to-end on device (push + chime + voice create/delete). **Live Activity NOT yet smoke-tested on a real device.**

## Schedules — CONFIRMED WORKING END-TO-END (2026-05-28)

Push pipeline verified live on device: executor fires → Hermes turn → APNs push delivers (chime + body). Two on-device-only bugs found + fixed during the smoke test:
- SchedulesView crashed on open (nested-sheet env-object gap) — fixed in build 4.
- APNs delivered nothing (`push.py` passed the .p8 *path* to aioapns, which wants PEM *contents*) — fixed; `send_push` returned `delivered: 1` after.
Device registered as iOS/production; APNS_USE_SANDBOX=false is correct for the TestFlight build. Backend restarted with both fixes loaded.

**Phase C voice creation also verified working (2026-05-28).** MCP server registered via `hermes mcp add hermes-voice` (3 tools enabled) — `~/.hermes/config.yaml` is NOT chezmoi-managed, so no drift. Registered as the backend venv python running `app/mcp_schedules.py` directly (self-contained, no relative imports) with `--env HERMES_VOICE_BASE_URL=https://scadrial.tailceb58.ts.net:8765`; the script loads `backend/.env` for the auth token. Live test: "create a schedule… every 2 hours" → Hermes called create_schedule (parsed cadence + refined prompt); "stop the market check schedule" → list_schedules + delete_schedule by name. Both confirmed against the store.

Minor follow-up: voice-created schedules show `source=ios` (the POST endpoint hardcodes it); would be nicer as `source=voice`. Not blocking.

Still uncommitted: build 4 `project.yml` bump + the two fixes (SettingsView env injection, push.py PEM read). Worth a commit.

## Blockers

None for code. Sequencing pivoted: we're doing **TestFlight first** because it's
the natural unblock for the topic-scoped APNs key AND for all on-device testing.

Phase B push had a real gap that's now fixed: the `aps-environment` entitlement
was missing entirely (only `UIBackgroundModes: remote-notification` was set).
Added `HermesVoice/HermesVoice.entitlements` + wired it + version numbers. Build
embeds + codesigns the entitlement cleanly.

User-side steps remaining (all in `ios/docs/testflight.md`):
1. App Store Connect record for `dev.finklea.hermesvoice` (registers App ID).
2. Archive + upload via Xcode (first archive enables Push capability on the App ID — this is what "surfaces the topic").
3. Create topic-scoped APNs key, place `.p8` at `~/.hermes-voice/apns-key.p8`.
4. Append APNS_* to `backend/.env` (Claude provides `! cat >>` one-liner — never reads .env). **APNS_USE_SANDBOX=false for TestFlight (Release) builds.**
5. Register device in-app, fire a 1-min test schedule.

Phase C voice (separate, can happen anytime): `hermes mcp add hermes-voice ...` per `backend/docs/schedules-setup.md`.

Without push key: schedules fire silently — visible in History.
Without MCP registration: schedules only creatable via in-app UI, not voice.

## Open Questions / Known Limits

- Schedule fires synthesize TTS via `/api/replay` rather than reusing the original turn's audio. Slight extra latency on foreground auto-play; not worth caching.
- `lastScheduledArrival` is published from `NotificationManager` but no view consumes it yet — tap-to-route-into-session is a small follow-up.
- ActionCard variants beyond calendar still pending. ActionCard heuristic still keys on `calendar` tool name + HH:MM lines.
- On-device walkthrough of the redesign is still un-done. Highest-priority polish item.
- **Live Activity `finish()` race** (`LiveActivityController.swift:50-56`): clears `self.activity` synchronously then ends the old activity in a fire-and-forget `Task`, so a subsequent `showThinking/showSpeaking` can `Activity.request` a new one before teardown completes. Class is `@MainActor` so no data race, and the old activity is captured locally so it isn't accidentally ended — real-world impact is low (transient duplicate activity, or a rare silent no-show if the 8-activity limit is momentarily hit on rapid barge-in). **Not a crash.** Fix: gate new requests behind teardown (a `tearingDown` flag, or await `end()` before clearing). Two minor nits alongside: `staleDate: nil` (activity never auto-dims when idle) and the `Activity.request` catch swallows errors with no log.

## Release tooling

`scripts/release.sh` cuts TestFlight builds: bumps `CURRENT_PROJECT_VERSION` in `ios/HermesVoice/project.yml`, regenerates, archives Release/generic-iOS, exports + uploads via the account-wide ASC API key (`~/.appstoreconnect/AuthKey_J79935N6P6.p8`), commits the bump. Flags: `--build` (default), `--patch`, `--minor`, `--no-commit`. An agent can run it. Modeled on open-feelings-ios/simmersmith scripts. `ios/HermesVoice/ExportOptions.plist` = app-store-connect upload, team K7CBQW6MPG. NOTE: ASC upload key ≠ APNs push key (two different .p8s). First archive must go through Xcode GUI (registers App ID); script works for every release after.

## Next Session

Schedules (A/B/C) shipped + live-verified; Live Activity v1 shipped (build + 41/41 tests re-verified green 2026-05-28). Reasonable next steps from the roadmap (any of):

1. Live Activity: on-device smoke test (PTT + scheduled fire) + harden `finish()` race / add `staleDate` / log request errors (see Known Limits).
2. Wire `NotificationManager.lastScheduledArrival` into MainView (route to session, show badge).
3. On-device walkthrough every state of the redesign; fix layout bugs.
4. Bonjour/mDNS backend discovery + onboarding flow.
5. CarPlay entitlement probe.
