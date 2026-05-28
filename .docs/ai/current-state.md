# Current State

> Updated at the end of every work session. Read this first.

## Active Branch

`main` (large uncommitted diff: redesign + schedules A/B/C; user will commit/push)

## Last Session Summary

**Date**: 2026-05-27

- Shipped the SwiftUI redesign ("E · Focus / Now-Playing — deepened") across all six screens; new icon and brand design system.
- Scoped and shipped all three schedule phases per `.docs/ai/phases/schedules-spec.md`.
- **Phase A** (store + cron + in-app UI): SQLite at `~/.hermes-voice/schedules.db`, 5s-tick asyncio executor in lifespan, `/api/schedules` CRUD, iOS SchedulesView.
- **Phase B** (APNs + chime + foreground auto-play): `app/push.py` with aioapns, devices table + `/api/devices` register/unregister, `Services/NotificationManager.swift` + `ChimePlayer.swift` + `AppDelegate.swift`, bundled `hermes-chime.caf` (8-bit ascending arpeggio, ~330ms), new Settings toggles for notifications/auto-play/chime.
- **Phase C** (Hermes voice integration): stdio MCP server at `app/mcp_schedules.py` exposing `create_schedule / list_schedules / delete_schedule`. Defaults to TLS verify=true with `HERMES_VOICE_CA_BUNDLE` env for custom CAs (security hook caught the original `verify=False` lazy default and rightly flagged it). User-facing setup guide at `backend/docs/schedules-setup.md`.
- Dropped wake-word (Apple won't grant background mic to indie apps; Siri shortcut covers lock-screen).
- Roadmap backlog still has: Bonjour/mDNS discovery + onboarding, Live Activity / Dynamic Island, CarPlay (entitlement probe first), redesign polish threads (on-device walkthrough, scrollback expand, ActionCard variants, voice picker).

## Build Status

- Backend: `uv run pytest` → **41/41 passing** (10 Phase A + 6 Phase B + 5 Phase C MCP + 20 pre-existing)
- iOS: `xcodebuild -scheme HermesVoice -destination 'generic/platform=iOS Simulator'` → **BUILD SUCCEEDED** (iOS + embedded Watch)
- App icon updated, chime bundled in app bundle, all UI toolbars match brand
- Nothing smoke-tested on real device yet

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

## Release tooling

`scripts/release.sh` cuts TestFlight builds: bumps `CURRENT_PROJECT_VERSION` in `ios/HermesVoice/project.yml`, regenerates, archives Release/generic-iOS, exports + uploads via the account-wide ASC API key (`~/.appstoreconnect/AuthKey_J79935N6P6.p8`), commits the bump. Flags: `--build` (default), `--patch`, `--minor`, `--no-commit`. An agent can run it. Modeled on open-feelings-ios/simmersmith scripts. `ios/HermesVoice/ExportOptions.plist` = app-store-connect upload, team K7CBQW6MPG. NOTE: ASC upload key ≠ APNs push key (two different .p8s). First archive must go through Xcode GUI (registers App ID); script works for every release after.

## Next Session

User picked the schedules track first; all three phases now done. Reasonable next steps from the roadmap (any of):

1. APNs setup + smoke-test schedules end-to-end on real device.
2. Wire `NotificationManager.lastScheduledArrival` into MainView (route to session, show badge).
3. On-device walkthrough every state of the redesign; fix layout bugs.
4. Bonjour/mDNS backend discovery + onboarding flow.
5. Live Activity / Dynamic Island ("Hermes is speaking…" with tap-to-interrupt).
6. CarPlay entitlement probe.
