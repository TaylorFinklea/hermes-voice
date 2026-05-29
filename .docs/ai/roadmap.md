# Roadmap

> Durable goals and milestones. Updated when scope changes, not every session.

## Vision

Hermes Voice — voice-native iOS + watchOS interface to a self-hosted Hermes Agent on macOS, secured via Tailscale. Push-to-talk, streaming STT/TTS, tool-call audit, conversation history. Personal operator-style "Jarvis" for memory capture, control, and admin.

## Now / Next / Later

### Now
- [x] G — App polish + frontend-design redesign (E · Focus / Now-Playing — deepened) — built; awaiting on-device visual review

### Next — scoped via `.docs/ai/phases/schedules-spec.md`
- [x] Schedules Phase A — store + cron + in-app UI (no push)
- [x] Schedules Phase B — APNs + chime + foreground auto-play (code complete; needs user's APNs .p8 key to actually deliver)
- [x] Schedules Phase C — Hermes voice creation/cancel via MCP — REGISTERED + VERIFIED LIVE (create + delete by voice both confirmed)

### In progress — TestFlight (pulled forward; unblocks APNs topic-scoping + on-device testing)
- [x] Code prep: Push entitlement (`aps-environment`), version numbers, signing config
- [ ] User: create App Store Connect record + archive + upload (see `ios/docs/testflight.md`)
- [ ] User: create topic-scoped APNs key (App ID surfaces after first archive)
- [ ] Wire APNs key into `backend/.env`, register device, fire test schedule

### Then — daily-driver features (sequenced)
- [x] Bonjour/mDNS backend discovery + first-launch onboarding — SHIPPED (`3558dff` backend, `35ff045` iOS, 2026-05-28). Backend advertises `_hermes-voice._tcp`; iOS full-screen `OnboardingView` discovers LAN backends + manual MagicDNS entry, test-connects `/health` before saving. LAN-only (mDNS doesn't traverse Tailscale). **User step:** set `HERMES_VOICE_PUBLIC_HOST` in `backend/.env` for cert-valid discovered URLs. On-device test pending. Spec: `.docs/ai/phases/bonjour-onboarding-spec.md`.
- [x] Live Activity / Dynamic Island — SHIPPED (`0b204e1`, 2026-05-28); v1 informational (tap opens app), interactive stop button is v2 per `.docs/ai/phases/live-activity-spec.md`. Hardened in `e5b88e6` (teardown race fixed via serial task-chain, `staleDate` safety net, request errors logged). On-device smoke test still pending.
- [ ] CarPlay support — **probe entitlement first**, Apple may refuse indie request

### Redesign polish (interleave with above)
- [ ] On-device walkthrough every state, fix layout bugs
- [x] Scrollback tap → in-app expand transcript — SHIPPED (`e5b88e6`); opens in-app `TranscriptView` (live in-memory transcript), no longer the History sheet
- [x] ActionCard variants beyond calendar — bulleted/numbered-list `.bullets` variant SHIPPED (`e5b88e6`). Device-list / todo-with-checkboxes / key-value still **blocked on structured backend tool output** (today only `ToolCall(name, preview, ok)` arrives)
- [x] Scheduled-arrival badge in MainView (tap → resume session) — SHIPPED (`e5b88e6`)
- [x] Voice picker in Settings wired to ElevenLabs voices — SHIPPED (`27d04c6` backend, `6f2f3ad` iOS, 2026-05-29). `GET /api/voices` + per-request `voice_id` override (no server-global mutation); Settings VOICE picker bound to `AppSettings.selectedVoiceId`. Also fixed onboarding to skip when a non-default backend is already configured (upgrade path).

### Dropped
- ~~D — Wake word~~ — iOS won't allow background mic for indie apps; Siri shortcut (`AskHermesIntent`) covers the lock-screen case. Foreground-only wake-word didn't earn its keep.

### Later
- [ ] TestFlight prep (diff project.yml against patchstand-ios / open-feelings-ios)
- [ ] App Store hardening (tighten ATS via NSExceptionDomains rather than NSAllowsArbitraryLoads)

## Completed

- [x] Streaming TTS + barge-in (cancellable Task pattern)
- [x] ElevenLabs Scribe + OpenAI Whisper STT options
- [x] Conversation history (backend `/api/sessions` + iOS UI + audio replay)
- [x] C — Backend reliability (launchd + Tailscale cert renewal + iOS last-seen indicator)
- [x] F — Latency wins (parallelize audit/TTS, A/B Groq STT)
- [x] E — Apple Watch companion (one-tap memory capture, WCSession-relayed)

## Backlog

> Self-contained items any agent can execute.

### Scheduled recurring Hermes messages

**Status**: Scoped — see `.docs/ai/phases/schedules-spec.md` for full spec. Phase A is the next executable chunk.

### Bug + architecture review findings (2026-05-29)

From the adversarially-verified review (40 kept / 34 confirmed; harness-deck report `20260529-bug-arch-review`; full data in workflow output `wf42mvxx6`). `voice_id` path-injection already fixed (`0deab6a`).

**Quick wins (localized, high-confidence) — DONE (`bffaa5e` backend, `74a96e4` iOS, 2026-05-29):**
- [x] `schedules.py` — in-flight id set so a slow (>5s) Hermes turn isn't re-fired every 5s tick (~36× duplicate subprocesses/pushes). **Top bug.**
- [x] `main.py` — lifespan: cancel executor before mDNS teardown; wrap `stop_mdns` in its own try/except.
- [x] `main.py` + `schedules.py` — `create_task` refs held in a set + `add_done_callback(discard)` (GC-cancellation guard).
- [x] `ConversationDetailView` — `.onDisappear { player.stop() }`.
- [x] `models.py` — `DeviceRegisterRequest.token` pattern `^[0-9a-fA-F]{64}$`.
- [x] `schedules.py:_connect` — `PRAGMA journal_mode=WAL` + `busy_timeout`.
- [x] `OnboardingView` — observes `browser.resolveError`.
- [x] `BackendBrowser` — `ObjectIdentifier` generation guard on resolve.

**Audio-session coordination cluster — DONE via one ref-counted coordinator (`2736b96`, 2026-05-29), except barge-in:**
- [x] New `AudioSessionCoordinator` (@MainActor, ref-counted acquire/release); `AudioPlayer` natural-end now releases session + observers (unified teardown) — no more ducking leak.
- [x] `VoiceRecorder` + `ChimePlayer` routed through the coordinator — can't yank the session out from under each other.
- [x] Foreground scheduled-arrival auto-play gated to idle (weak VM ref) + holds one coordinator session across chime→reply + single owned player (no throwaway fight, no LA double-drive).
- [x] Barge-in during `.sending/.thinking` — FIXED (`8a687fd`, 2026-05-29). Confirmed on device (stuck on Sending/Thinking, only X worked) + by a verified 12-agent state-machine trace: `userPressedMic`'s `.thinking/.sending` arm called `startRecording()` whose guard blocks from non-idle states. Fix: set `state = .idle` after cancel, before `startRecording()`. (The trace also REFUTED the feared "clobber race" — all components are @MainActor/serialized, so a cancelled turn can't run `handle()` concurrently; `.speaking` barge-in was already correct + deterministic.)

**Other confirmed:**
- [ ] Streaming-TTS producer blocks forever / leaks the ElevenLabs connection if no consumer drains the queue (`main.py:404-425`; + `audio_store` eviction should cancel the producer).
- [ ] HeroPane renders the reply twice when a `.bullets` ActionCard is detected (strip card-consumed lines).
- [ ] `AudioStore` — no TTL/disk cleanup; temp dir leaks each restart (lifespan `rmtree` + TTL sweep).
- [ ] `PhoneWatchBridge` keeps a divergent `AppSettings()` copy → stale watch settings (single shared settings).
- [ ] Bullets ActionCard over-triggers on dashed/numbered prose (tighten heuristic).

**Security hardening (needs product decision):**
- [ ] `/health` unauthenticated + discloses provider/runtime config — gate behind token OR trim to `{status, mock}` (affects the Settings diagnostics view + onboarding test-connection; decide first).
- [ ] Auth token optional while launchd binds `0.0.0.0` — fail closed on non-loopback bind with empty token, or document the token as mandatory.

**Architecture (needs design + prioritization):**
- [ ] Extract a `TurnPipeline`/`HermesTurnService` from the `ConversationViewModel` god-object (and make it testable).
- [ ] Inject one `BackendClient` instead of ad-hoc `HermesVoiceAPI(...)` in ~8 sites.
- [ ] Add an iOS test target (start with `pairedTurns`, decoders, VM transitions).
- [ ] Long-lived per-provider `httpx.AsyncClient` (TLS reuse) for TTS/STT/MCP.
- [ ] `Semaphore(2-3)` around `_fire_one`; text-only path flag for scheduled fires.
- [ ] Typed tool-output schema (unblocks richer ActionCard variants).

### From on-device testing (2026-05-29)

- [x] History sheet stopped opening — FIXED (`efd121f`): three stacked `.sheet(isPresented:)` on MainView shadowed each other once the transcript sheet was added; collapsed to one `.sheet(item:)` enum.
- [ ] **Turn hangs at "transcribing + dispatching to hermes" with no response/timeout** (reported on device; recording+upload succeeded, so it's server-side STT or `hermes.ask`). Needs backend-log diagnosis. Consider a client-side turn timeout + clear error so a hung turn surfaces instead of an indefinite spinner (today only URLSession's 60s default applies).
- [ ] **Live tool-calls during thinking/sending** (feature request): stream tool-call events as Hermes emits them and render them in the pipeline UI (condensed, Hermes-like). Today tool-calls are audited only AFTER the turn (`fetch_tool_calls_since` post-`hermes.ask`). Needs backend streaming (SSE/WS or mid-turn session-DB polling) + client stream consumption; pairs with the typed-tool-output item above.

## Constraints

- iOS 17+ / watchOS 10+
- No new third-party iOS dependencies if avoidable (use Apple frameworks)
- Backend stays a single FastAPI app (no microservices)
- Tailscale-only access (CGNAT 100.64/10); ATS configured to allow this
