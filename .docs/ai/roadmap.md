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
- [ ] **Conversational voice (the "Jarvis" endgame)** — decomposed after on-device STT landed instant. **Sub-project 1: on-device TTS — SWAPPED Kokoro→Apple AVSpeech (2026-06-15, iOS BUILD SUCCEEDED), build + device-test pending.** Originally Kokoro/FluidAudio, but on-device testing (build 23) exposed 3 Kokoro pronunciation/voice bugs all internal to FluidAudio (voice selection ignored; "is"→"eyes"; numbers→"x") — see `current-state.md` + `decisions.md [2026-06-15]`. Now uses Apple `AVSpeechSynthesizer` (offline, real selectable voices, robust number/date/homograph normalization, no model download). Voice picker `local:` sentinel kept; backend `tts=none` = the "text brain" hook for fronting **Claude Code / other harnesses** later. Spec: `.docs/ai/phases/on-device-tts-spec.md`. **Sub-project 2: hands-free conversation mode — BUILT (iOS BUILD SUCCEEDED), not cut/device-tested.** VAD turn-taking (listen→endpoint→transcribe→reply→re-listen), no mic press between turns; top-bar toggle, 1.0s endpoint, single-turn hero re-arming, real-level waveform, barge-in via mic-tap + End, auto-exit after 3 empty cycles. New: `LocalVad`, `ConversationCaptureEngine`, `ConversationModeController`. Backend untouched (reuses `tts=none`). Spec: `.docs/ai/phases/conversation-mode-spec.md`. Deferred: vocal barge-in / full-duplex echo cancellation (→ then `StreamingEouAsrManager` earns its second model).
- [ ] On-device STT (parakeet-v2 via FluidAudio, **on-iPhone**) — **SHIPPED in TestFlight build 9 (`a88fa59`); device-test pending.** Mirrors the user's tesela setup (`FluidInference/FluidAudio`, CoreML); transcribes on the phone → reuses the text-stream path; audio-upload is the automatic fallback. Spec: `.docs/ai/phases/on-device-stt-spec.md`. Queued: **Phase B** live-progress bundle (split transcribing/dispatching on the real STT-done event, instant transcript, "thinking Ns" elapsed clock); **Phase C** stream Hermes's thinking (needs a backend stdout spike). Groq STT dropped (local supersedes; kept only as a cloud fallback).
- [ ] CarPlay support — **probe entitlement first**, Apple may refuse indie request

### Redesign polish (interleave with above)
- [ ] On-device walkthrough every state, fix layout bugs
- [x] Thinking-state progress affordance + live-pane recovery for History-only replies — FIXED (2026-06-01). "Composing reply…" now has visible motion + elapsed time; if a streamed turn ends/errors after Hermes persisted an answer but before the phone receives `assistant`, the current session is backfilled from History so the reply appears in the live pane.
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

**Other confirmed — DONE (2026-06-04, bug+security sweep):**
- [x] Streaming-TTS producer blocked forever / leaked the upstream connection with no consumer (`4789ec4`): `wait_for` timeout on `queue.put` abandons a dead consumer; generator `aclose()`d; `AudioStore` holds the producer task so eviction/TTL/shutdown cancels it.
- [x] HeroPane double-rendered a `.bullets`/calendar reply (`d93a301`): `ActionCard.residual(in:)` strips the card-consumed lines; only the remainder renders.
- [x] `AudioStore` TTL + disk cleanup (`4789ec4`): opportunistic 30-min sweep of files+streams; lifespan `store.close()` cancels producers + `rmtree`s the temp dir.
- [x] `PhoneWatchBridge` stale settings (`d93a301`): inject the app's shared `AppSettings` via `start(settings:)` (weak, mirrors NotificationManager) so Watch turns read live values.
- [x] Bullets ActionCard over-trigger (`d93a301`): majority threshold 0.6→0.7.

**Security hardening — DONE (2026-06-04):**
- [x] `/health` disclosure (`6707697`): public response is `{status, mock, scheme}` only (onboarding reachability still token-free); provider/runtime details disclosed only to an authenticated caller (`_token_ok` shared with `_require_token`). iOS diagnostics already sends the token, so it still shows full details.
- [x] Fail closed on exposed bind (`6707697`): `assert_safe_bind()` refuses to start when bound to a non-loopback host with an empty token; called from `__main__` (the bind path), so `TestClient` stays exempt.

**Architecture (needs design + prioritization):**
- [ ] Extract a `TurnPipeline`/`HermesTurnService` from the `ConversationViewModel` god-object (and make it testable).
- [ ] Inject one `BackendClient` instead of ad-hoc `HermesVoiceAPI(...)` in ~8 sites.
- [ ] Add an iOS test target (start with `pairedTurns`, decoders, VM transitions, **+ `LocalSpeaker.makeSpeakable` parity vs backend `make_speakable` using the shared fixture corpus `backend/tests/fixtures/speakable_cases.json`** — the Swift mirror is currently hand-matched only).
- [ ] Migrate Hermes + Codex voice preludes to a per-invocation system prompt like Claude (done 2026-06-05): they still prepend a first-turn-only USER-text `_VOICE_PRELUDE`, so resumed turns get no shaping. The `make_speakable` sanitizer already protects their *spoken* output, but the model still emits verbose markdown on resume. Needs verifying whether the `hermes`/`codex` CLIs expose an append-system-prompt equivalent.
- [x] Long-lived per-provider `httpx.AsyncClient` (TLS reuse) for TTS/STT — DONE (2026-06-20). `app/_http.py acquire_client()` + a lifespan-managed `app.state.http_client` injected into all 6 TTS/STT providers (graceful per-call fallback). The out-of-process schedules MCP (`mcp_schedules.py`) keeps its own per-call client (separate process, can't share `app.state`).
- [ ] `Semaphore(2-3)` around `_fire_one`; text-only path flag for scheduled fires.
- [ ] Typed tool-output schema (unblocks richer ActionCard variants).

### From on-device testing (2026-05-29)

- [x] History sheet stopped opening — FIXED (`efd121f`): three stacked `.sheet(isPresented:)` on MainView shadowed each other once the transcript sheet was added; collapsed to one `.sheet(item:)` enum.
- [x] **"Turn hangs"** — DIAGNOSED (2026-05-29): not a hang. STT (≤90s) and `hermes.ask` (≤180s) are both bounded, and the client times out at ~60s → `.error`. It was a *slow* Hermes turn (a trivial "list home dir" took 22s) with no live feedback + (now-fixed) broken barge-in, so it *felt* frozen. The real fix is live progress (below). (Optional future polish: a tighter client turn timeout + clearer message.)
- [x] **Live tool-calls during thinking** — SHIPPED (Phase 2: `d6377cc` backend, `67a04a9` iOS, 2026-05-29). Validated that Hermes flushes tool previews to stdout incrementally through a pipe; backend runs non-`-Q` + streams `tool` events over SSE (`/api/text/stream`, `/api/audio/stream`), authoritative reply + tools from the session export; iOS consumes the SSE and renders chips live in the thinking pane, with single-shot fallback. Spec + status: `.docs/ai/phases/live-progress-convo-control-spec.md`. **On-device test pending.**

### Large-session resume warning + remedy (2026-06-03)

Resuming a long Claude session replays its whole transcript before the first
reply streams (e.g. a ~5k-message session blew past the old 180s timeout;
mitigated to 300s in `a061863`). No native way to partial-load history —
`--resume`/`--fork-session` always load the full transcript. So warn the user
*before* they attach, and **always pair the warning with the fix** (run
`/compact`), never a dead-end.

- [x] **Backend — surface a "heavy session" signal.** SHIPPED (2026-06-04).
  `size_bytes` (raw `st_size`, single stat in `session_meta_from_file`) added to
  `HarnessSession` (`harness.py`) + `SessionListItem` (`models.py`), threaded
  through the `/api/harnesses/{id}/sessions` endpoint. Optional/default-0, so
  Hermes + older clients are unaffected. iOS owns the threshold.
- [x] **iOS — chip in the session browser, before attach.** SHIPPED. Heavy rows
  (`HarnessSession.isHeavy`: >2 MB or >500 msgs) show
  `⚠ Large · ~5k msgs · slow to resume` in `SessionBrowserView`. `size_bytes`
  decoded with a default so older backends just never flag heavy.
- [x] **iOS — attach-time notice that carries the remedy.** SHIPPED. Tapping a
  heavy session shows a confirm alert ("Large history") whose body spells out
  the `/compact` remedy before "Attach anyway"; light sessions attach straight
  through. Remedy is mandatory copy, paired with the warning.
- **Acceptance**: a >2 MB session shows the chip in the browser and the
  remedy-bearing notice on attach; a small session shows neither; the field is
  optional so Hermes sessions and older clients are unaffected.
- **Verify**: `uv run --project backend pytest` green (add a scanner test:
  big-fixture → `heavy`/`size_bytes` set; small → not); `xcodebuild … build
  CODE_SIGNING_ALLOWED=NO` green.
- **Tier hint**: Sonnet — multi-file but localized (one backend field + two iOS
  surfaces).
- **Deferred follow-up (separate item, do NOT bundle):** execute the remedy
  *from the app* — a "Compact this session" button. Lead with triggering
  `/compact` in place (preserves continuity); fork-from-summary is the fallback
  but **forks the session ID** (diverges from the terminal) and is lossy.
  Gotcha to remember: a real model summary of a huge session is itself slow
  (something must load the history to summarize it), so a free/instant version
  seeds the new session with the raw last-K-messages tail + `ai-title`, not a
  model summary. **Needs a spike**: whether `/compact` can be driven headlessly
  (slash commands in `-p` mode are unverified).

## Constraints

- iOS 17+ / watchOS 10+
- No new third-party iOS dependencies if avoidable (use Apple frameworks)
- Backend stays a single FastAPI app (no microservices)
- Tailscale-only access (CGNAT 100.64/10); ATS configured to allow this
