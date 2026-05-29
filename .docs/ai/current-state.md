# Current State

> Updated at the end of every work session. Read this first.

## Active Branch

`main` — working tree clean (all work committed). Recent: `0b204e1` Live Activity (2026-05-28), `6b91d4e` schedules/APNs fixes (2026-05-28), `7d3a94b` initial.

## Last Session Summary

**Date**: 2026-05-29

- **Live progress + conversation control (2026-05-29)** — brainstormed; spec `7752de3` (`.docs/ai/phases/live-progress-convo-control-spec.md`); "enhance now-playing", not a threaded pivot. **Phase 1** (`47994f7`): explicit "+ New conversation" top-bar button, "continuing · N" pill → transcript, cancel-only dock X. **Phase 2 — live tool-calls** (`d6377cc` backend, `67a04a9` iOS): SSE turn endpoints (`/api/text/stream`, `/api/audio/stream`) stream `tool` events live (Hermes non-`-Q` stdout, proven to flush incrementally through a pipe); reply + authoritative tools come from the session export; iOS renders chips live in the thinking pane with single-shot fallback. **Shipped in build 8 (`44c30d0`); on-device test pending.**
- **The "turn hang" was NOT a hang** (diagnosed 2026-05-29): STT (≤90s) and `hermes.ask` (≤180s) are both bounded and the client times out ~60s → `.error`; it was a *slow* Hermes turn (a trivial "list home dir" took 22s) with no live feedback — exactly what Phase 2 fixes. Text mode + ping confirmed the backend healthy.
- **Builds:** build 7 (`022728f`) = build 6 content + Phase 1 + barge-in fix (`8a687fd`) + History fix (`efd121f`). Build 6 (`a89a966`) already shipped the **voice picker** + the review fixes (quick wins, audio coordinator, voice_id validation). (Build 5 `5b7e786` earlier = redesign/schedules/LiveActivity/Bonjour.) **Build 8 (`44c30d0`) adds Phase 2 (live tool-calls)** on top of build 7. Everything committed is now in a build; **on-device testing of build 8 is the open item** (live tool feed + conversation control + barge-in/History/audio-coordinator all need a real-device pass).
- Device feedback fixed earlier this session: History sheet (`efd121f` — three stacked `.sheet(isPresented:)` shadowed each other → one `.sheet(item:)`), barge-in from Sending/Thinking silently dropped (`8a687fd` — `state=.idle` before `startRecording()`; a 12-agent verified trace also refuted the feared clobber race).
- **TestFlight build 5 (1.0) uploaded** (`5b7e786`, 2026-05-29) via `scripts/release.sh` — first archive to include the `HermesVoiceWidget` extension; auto-provisioning worked. Contains the redesign + schedules + Live Activity + loose-ends/polish + Bonjour/onboarding. Processing on App Store Connect; installable via TestFlight.
- **Bug + architecture review** (2026-05-29): adversarially-verified (5 finders → 2 skeptics each), 40 kept findings; harness-deck report `20260529-bug-arch-review`, backlog in roadmap. Fixed this session: `voice_id` path-injection (`0deab6a`); 8 quick wins (`bffaa5e` backend, `74a96e4` iOS) incl. the **top scheduler concurrent-re-fire bug** (in-flight guard); and the **audio-session cluster** via a new ref-counted `AudioSessionCoordinator` (`2736b96`) routing recorder/player/chime through one owner + gated scheduled-arrival auto-play. **Deferred:** the barge-in cancellation race (review "likely"; entangled with the `startRecording()` guard ordering — needs on-device verification first). Remaining backlog: other-confirmed defects, security hardening (`/health` disclosure, token-on-0.0.0.0), architecture refactors.
- **Voice picker** (`27d04c6` backend, `6f2f3ad` iOS, 2026-05-29): TTS `voice_id` is now a per-request override (Protocol `synthesize`/`stream` take `voice_id`; ElevenLabs honors it, others ignore); `GET /api/voices` lists the ElevenLabs catalog (`[]` for other providers). iOS Settings VOICE picker → `AppSettings.selectedVoiceId`, sent with every turn + replay. Onboarding now auto-skips when a non-default backend is already configured (upgrade path).
- Shipped the SwiftUI redesign ("E · Focus / Now-Playing — deepened") across all six screens; new icon and brand design system.
- Scoped and shipped all three schedule phases per `.docs/ai/phases/schedules-spec.md`.
- **Phase A** (store + cron + in-app UI): SQLite at `~/.hermes-voice/schedules.db`, 5s-tick asyncio executor in lifespan, `/api/schedules` CRUD, iOS SchedulesView.
- **Phase B** (APNs + chime + foreground auto-play): `app/push.py` with aioapns, devices table + `/api/devices` register/unregister, `Services/NotificationManager.swift` + `ChimePlayer.swift` + `AppDelegate.swift`, bundled `hermes-chime.caf` (8-bit ascending arpeggio, ~330ms), new Settings toggles for notifications/auto-play/chime.
- **Phase C** (Hermes voice integration): stdio MCP server at `app/mcp_schedules.py` exposing `create_schedule / list_schedules / delete_schedule`. Defaults to TLS verify=true with `HERMES_VOICE_CA_BUNDLE` env for custom CAs (security hook caught the original `verify=False` lazy default and rightly flagged it). User-facing setup guide at `backend/docs/schedules-setup.md`.
- Dropped wake-word (Apple won't grant background mic to indie apps; Siri shortcut covers lock-screen).
- **Live Activity / Dynamic Island** (commit `0b204e1`, 2026-05-28): ActivityKit local-update controller (`LiveActivityController`), shared `HermesActivityAttributes`, new widget-extension target (`HermesVoiceWidget`) rendering lock-screen + Dynamic Island (compact/expanded/minimal). Driven from `ConversationViewModel.syncLiveActivity()` (thinking/speaking; recording excluded) and `NotificationManager` for scheduled-fire auto-play. v1 informational — tap opens app; interactive stop is v2 per spec. **Hardened in `e5b88e6`**: the `finish()` teardown race is fixed (serial task-chain so `end()` always precedes the next `request()`), a 180s `staleDate` safety net was added, and the swallowed `Activity.request` error is now logged.
- **Loose ends + polish** (commit `e5b88e6`, 2026-05-28): (1) wired `lastScheduledArrival` → a tappable "SCHEDULED UPDATE" badge in MainView (idle-only) that resumes the session and clears itself; (2) scrollback-rail tap now opens an in-app `TranscriptView` (live in-memory transcript) instead of the all-sessions History sheet; (3) added a tool-agnostic `.bullets` ActionCard variant (conservative bulleted/numbered-list detection, falls back to plain text).
- **Bonjour discovery + first-launch onboarding** (commits `3558dff` backend, `35ff045` iOS, 2026-05-28): backend advertises `_hermes-voice._tcp` via zeroconf (`app/mdns.py`, lifespan-wired; LAN IP via UDP-connect trick to dodge the Tailscale 100.x addr; crash-safe lazy-import). iOS `OnboardingView` (full-screen until configured) discovers LAN backends (`BackendBrowser` = NWBrowser browse + NetService resolve) and/or takes a manual MagicDNS URL, test-connecting `/health` before saving + flipping `hasCompletedOnboarding`. `NSBonjourServices` added to Info.plist (required or discovery finds nothing). Spec + status: `.docs/ai/phases/bonjour-onboarding-spec.md`.
- Roadmap backlog still has: CarPlay (entitlement probe first), remaining redesign polish (on-device walkthrough, voice picker; richer ActionCard variants need structured backend tool output).

## Build Status

Re-verified 2026-05-28 (post-Live-Activity commit `0b204e1`):
- Backend: `uv run pytest` (synced with `uv sync --extra dev`, **not** `--all-extras` — that pulls faster-whisper and breaks the "no STT configured" assertions) → **41/41 passing** (10 Phase A + 6 Phase B + 5 Phase C MCP + 20 pre-existing). Live Activity was iOS-only; backend unchanged.
- iOS: `xcodegen generate && xcodebuild -project HermesVoice.xcodeproj -scheme HermesVoice -destination 'generic/platform=iOS Simulator' build CODE_SIGNING_ALLOWED=NO` → **BUILD SUCCEEDED** — app + embedded Watch + new `HermesVoiceWidget.appex`. `HermesActivityAttributes` compiles into both app and widget targets (no dup-symbol / missing-type).
- App icon updated, chime bundled in app bundle, all UI toolbars match brand.
- Schedules confirmed working end-to-end on device (push + chime + voice create/delete). **Live Activity NOT yet smoke-tested on a real device.**
- **Re-verified after polish/hardening commit `e5b88e6`** (Live Activity serialization + arrival badge + in-app transcript + bullet ActionCard): iOS **BUILD SUCCEEDED** (incl. widget); backend untouched (41/41 holds). Not yet on-device.
- **Re-verified after Bonjour/onboarding commits `3558dff`/`35ff045`**: backend `uv run pytest` → **44/44** (+3 `test_mdns.py`); iOS **BUILD SUCCEEDED** (new OnboardingView + BackendBrowser + NSBonjourServices). Not yet on-device — discovery + onboarding need a real device with a same-Wi-Fi Mac to verify.
- **Re-verified after voice-picker commits `27d04c6`/`6f2f3ad` (2026-05-29)**: backend `uv run pytest` → **48/48** (+4 `test_voices.py`); iOS **BUILD SUCCEEDED**. (Voice picker is NOT in TestFlight build 5 — landed after that archive.)
- **Re-verified after review fixes (2026-05-29)**: backend `uv run pytest` → **50/50** (+2 `test_voices` security tests); iOS **BUILD SUCCEEDED** (quick wins + audio-session coordinator). **None of the review fixes are on-device-tested yet** — the audio-session coordinator changes session lifecycle and needs a real-device pass (build 6).
- **Re-verified after Phase 1 + Phase 2 (2026-05-29)**: backend `uv run pytest` → **53/53** (+3 `test_stream.py`); iOS **BUILD SUCCEEDED** (conversation control + SSE live-tool consumer). On-device test pending — Phase 2 live tool feed + the barge-in/History/conversation-control changes all need a real-device pass.

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
- ActionCard now has calendar + a conservative `.bullets` (bulleted/numbered-list) variant. Richer variants (device list, todo with checkboxes, key-value) still need structured backend tool output — today only `ToolCall(name, preview, ok)` arrives, so detection is heuristic on freeform preview/text.
- On-device walkthrough of the redesign is still un-done. Highest-priority polish item.
- Live Activity `finish()` race, `staleDate`, and swallowed-request-error nits are all FIXED in `e5b88e6` (serial task-chain + 180s stale safety net + logged catch). Still un-smoke-tested on a real device.

## Release tooling

`scripts/release.sh` cuts TestFlight builds: bumps `CURRENT_PROJECT_VERSION` in `ios/HermesVoice/project.yml`, regenerates, archives Release/generic-iOS, exports + uploads via the account-wide ASC API key (`~/.appstoreconnect/AuthKey_J79935N6P6.p8`), commits the bump. Flags: `--build` (default), `--patch`, `--minor`, `--no-commit`. An agent can run it. Modeled on open-feelings-ios/simmersmith scripts. `ios/HermesVoice/ExportOptions.plist` = app-store-connect upload, team K7CBQW6MPG. NOTE: ASC upload key ≠ APNs push key (two different .p8s). First archive must go through Xcode GUI (registers App ID); script works for every release after.

## Next Session

All three workstreams from the 2026-05-28 session are shipped + build-green: Schedules (A/B/C, live-verified), Live Activity v1 (shipped + hardened), loose ends + polish (`e5b88e6`), and Bonjour discovery + onboarding (`3558dff`/`35ff045`). Nothing in flight.

**User setup to make LAN discovery useful (one line):** the backend serves HTTPS with a Tailscale cert (valid only for `*.ts.net`). For a discovered LAN backend's URL to validate, set `HERMES_VOICE_PUBLIC_HOST=<your-mac>.tailXXXX.ts.net` in `backend/.env` and restart — then discovery (same Wi-Fi) prefills the cert-valid Tailscale URL. Leave it empty only if the backend serves plain HTTP on the LAN. (No public_host → a discovered HTTPS LAN-IP URL will cert-mismatch; manual MagicDNS entry still works.)

Remaining (any of — all need a real device):
1. On-device smoke test: Live Activity (PTT + scheduled fire), arrival badge, transcript expand, AND the new onboarding + Bonjour discovery (needs a same-Wi-Fi Mac running the backend).
2. On-device walkthrough every state of the redesign; fix layout bugs.
3. Voice picker in Settings → ElevenLabs voices.
4. CarPlay entitlement probe.
