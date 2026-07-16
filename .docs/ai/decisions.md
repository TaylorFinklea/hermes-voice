# Decisions

> Architecture decision records. Append-only — one entry per decision.

<!-- Template for each entry:

## [YYYY-MM-DD] Decision Title

**Context**: What prompted this decision?
**Decision**: What was chosen?
**Alternatives considered**: What else was evaluated?
**Rationale**: Why this over the alternatives?
-->

## [2026-05-27] Use SF Mono instead of bundling JetBrains Mono

**Context**: Mockups specified JetBrains Mono for all type. Bundling that font in the iOS bundle costs ~400KB and adds an Info.plist UIAppFonts entry.

**Decision**: Use `.system(.size:, design: .monospaced)` everywhere — Apple's SF Mono ships with iOS.

**Alternatives considered**: Bundle JetBrains Mono; bundle IBM Plex Mono as fallback; mix system + bundled.

**Rationale**: SF Mono is geometrically very close to JetBrains Mono on iOS, has perfect rendering across all sizes, and avoids any binary weight. We can revisit if the rhythm feels wrong against the mockup. The decision is reversible — Brand.swift centralizes all font references, swapping is one file.

## [2026-05-27] Redesign as one PR rather than staged screens

**Context**: Could ship MainView first, then Settings, then Watch, etc. Or ship all at once.

**Decision**: One coordinated rewrite of all 6 screens.

**Rationale**: Partial redesigns look broken — old chat-bubble screens next to new now-playing layout creates a worse impression than the status quo. Coherent visual identity demands all-or-nothing.

## [2026-05-27] ActionCard detection: client-side heuristic for v1, structured backend later

**Context**: Mockup includes a calendar action card; backend has no structured response field.

**Decision**: Build the ActionCard SwiftUI component AND a heuristic detector that pattern-matches `HH:MM` lines in assistant text when a calendar tool was called. Falls back gracefully when no parse.

**Alternatives considered**: Pure-component (never render until backend ships structured); add structured TurnResponse field now and detect on backend.

**Rationale**: Heuristic works today for the demo case and stays useful when Hermes ships a real calendar tool. Backend-side structured detection is the right long-term move but requires Hermes itself to expose tool output, not just preview strings — that's a multi-system change. Swap the detector when the data is there; rendering stays unchanged.

## [2026-05-27] Schedules store lives in its own SQLite DB, not Hermes's

**Context**: Schedules need persistence. Easy option: cohabit Hermes's `~/.hermes/state.db`. Right option: separate file.

**Decision**: `~/.hermes-voice/schedules.db` — our own file, owned by this app, read/write.

**Rationale**: Hermes's DB is read-only from our perspective (we don't own its schema). Mixing tables risks schema-migration collisions and corruption when Hermes updates. Separate file also makes the backend self-contained — destroy `schedules.db`, lose your schedules, but Hermes's history is intact.

## [2026-05-27] Resolve `DEFAULT_DB_PATH` at call time, not as a function default arg

**Context**: First pass had `async def create(..., path: Path = DEFAULT_DB_PATH)`. Tests monkey-patched the module's `DEFAULT_DB_PATH` to a temp file, but Python binds default args at function-definition time. The endpoint tests silently wrote to the real `~/.hermes-voice/schedules.db` while pretending to use the temp.

**Decision**: All schedules functions take `path: Path | None = None` and call `_resolve_path(path)` internally, which reads the current module-level `DEFAULT_DB_PATH` at call time.

**Rationale**: Restores monkey-patchability without forcing every caller to thread the path explicitly. The cost is one extra function call per CRUD operation — irrelevant. This pattern should be the default for any module-global-default plumbing where tests need to override.

## [2026-05-28] aioapns `key` is PEM contents, not a file path

**Context**: First live scheduled fire pushed nothing — backend log showed `Unable to load PEM file ... MalformedFraming` per device, even though the .p8 loaded fine via `cryptography.load_pem_private_key`. `push.py` passed `key=settings.apns_key_path` (the file path).

**Decision**: Read the .p8 file and pass its contents: `key_pem = Path(apns_key_path).read_text(); APNs(key=key_pem, ...)`.

**Rationale**: aioapns hands `key` straight to `jwt.encode(key=..., algorithm="ES256")`. PyJWT expects the PEM key material (str/bytes), so a path string gets parsed as a key and fails with the misleading framing error. Verified the fix live: `send_push(...)` returned `devices delivered to: 1` and the notification + chime arrived on device. Schedules feature is now confirmed working end-to-end (executor → Hermes turn → APNs).

## [2026-05-28] Always re-inject @EnvironmentObject across nested sheets

**Context**: Build 3 (first on-device TestFlight) crashed instantly when opening Settings → Manage schedules. SchedulesView declares `@EnvironmentObject var settings: AppSettings` but was presented as a sheet *from within* SettingsView (itself a sheet from MainView). Environment objects don't reliably propagate across nested sheet boundaries; in a Release build the missing object is a hard `fatalError` on first render — looks like the view "instantly closes." First-level sheets (MainView → Settings/History) inherit fine, so the simulator-less workflow never caught it.

**Decision**: Every sheet that presents a view requiring an env object injects it explicitly — `SchedulesView().environmentObject(settings)`. This matches the pattern already used for ScheduleEditView and ConversationDetailView.

**Rationale**: Relying on implicit propagation is the actual bug class here, not a one-off. Explicit injection at every sheet boundary is cheap and removes the whole category. Lesson for on-device testing: env-object crashes are Release-only and sheet-depth-dependent — they cannot be caught by `xcodebuild build` alone; only running the app surfaces them.

## [2026-05-27] Schedules Phase C: stdio MCP server proxying to REST, not native MCP HTTP endpoints

**Context**: Hermes accepts both stdio and HTTP MCP servers via `hermes mcp add`. We could expose MCP-over-HTTP from the existing FastAPI app, or ship a small stdio Python script.

**Decision**: Stdio script at `backend/app/mcp_schedules.py` using `mcp.server.fastmcp.FastMCP`. It calls our REST endpoints via httpx.

**Alternatives considered**: MCP HTTP/SSE endpoints in FastAPI; custom Hermes tool config (non-MCP).

**Rationale**: Stdio is the simpler and more conventional MCP install pattern (`hermes mcp add hermes-voice --command uv --args run python -m app.mcp_schedules`). It also gives us a process boundary: even if Hermes Agent restarts, the FastAPI backend keeps running its cron loop unaffected. The proxy layer is ~20 lines of httpx calls — cheap. The user only pays for the indirection at tool-call time, which happens during chat anyway.

## [2026-05-27] MCP server defaults to TLS verify=true; HERMES_VOICE_CA_BUNDLE for custom CAs

**Context**: First draft of `mcp_schedules.py` used `httpx.AsyncClient(verify=False)` because the backend is on the same machine and "obviously trusted." The security-guidance hook caught this — disabling verification globally is a footgun even on localhost.

**Decision**: Default to `verify=True`. If a user genuinely needs a custom CA bundle (rare — Tailscale-issued certs chain to Let's Encrypt and verify natively), they set `HERMES_VOICE_CA_BUNDLE=/path/to/ca.pem`. No env to disable verification entirely.

**Rationale**: Tailscale's cert path verifies cleanly out of the box. The only case where `verify=False` would help is a homegrown self-signed setup, which deserves a proper trust-store fix rather than a silent bypass. Documenting the escape hatch (CA bundle) covers the legitimate case without normalizing "just turn it off."

## [2026-05-27] Schedules executor loop runs in lifespan, table init runs at create_app

**Context**: TestClient doesn't fire the lifespan handler unless used as a context manager. If both the table init AND the executor loop live in lifespan, tests that don't `with TestClient` fail with `no such table: schedules`.

**Decision**: Call `schedules._init_sync()` inline at the bottom of `create_app` (cheap — just sqlite3 CREATE IF NOT EXISTS). The executor loop stays in `@asynccontextmanager lifespan` since it needs an event loop.

**Rationale**: Idempotent table creation is fine to run on every app boot. Tests get a working DB without needing the lifespan plumbing. Production gets the same code path; just runs once at start.

## [2026-05-27] BottomDock close button calls `cancelCurrentTurn()` not `reset()` during active turns

**Context**: The X side button needs different semantics depending on state. During recording we want to discard the audio; during sending/thinking we want to abort the in-flight URL request; during idle there's nothing to cancel.

**Decision**: Added `ConversationViewModel.cancelCurrentTurn()` that switches on state and does the right thing. `reset()` is only used when state is `.idle` or `.error`.

**Rationale**: One-button-many-meanings, but the glyph itself changes to telegraph intent (X during active turn, counterclockwise-arrow during idle).

## [2026-05-28] Live Activity: local ActivityKit updates, v1 informational, no push token

**Context**: Wanted lock-screen + Dynamic Island presence for in-flight Hermes turns (thinking/speaking). ActivityKit supports both local (`Activity.update`) and push-driven updates.

**Decision**: Local updates only — a `@MainActor LiveActivityController` singleton calls `Activity.request/.update/.end` in-process, driven from `ConversationViewModel.state.didSet` (`.sending/.thinking → showThinking`, `.speaking → showSpeaking`, `.idle/.error/.recording → finish`) plus `NotificationManager` for scheduled-fire foreground auto-play. No ActivityKit push token. v1 is informational (tap opens the app); the interactive `LiveActivityIntent` stop button is deferred to v2.

**Alternatives considered**: Push-to-update Live Activity (needs an APNs Live Activity channel + push-token plumbing); ship the interactive stop button in v1.

**Rationale**: The app is always running when our triggers fire — PTT is foreground, scheduled auto-play only runs in `willPresent` (foreground), and background-audio keeps the app alive through `.speaking`. So in-process updates suffice; no push infra needed. The interactive stop button requires extracting `AudioPlayer` control into a shared `PlaybackController` (out of the SwiftUI VM) so a widget-process intent can call `stop()` — a bigger refactor that doesn't block the informational v1. Full spec: `.docs/ai/phases/live-activity-spec.md`.

**Known follow-up**: `finish()` clears `self.activity` then ends it in a fire-and-forget `Task`, so a fast subsequent `showThinking/showSpeaking` can request a new activity mid-teardown (transient duplicate, or a rare silent no-show on the active-activity limit). `@MainActor` means no data race and the old activity is captured locally, so it's not a crash. Tracked in `current-state.md` Known Limits. *(Resolved 2026-05-28, commit `e5b88e6` — see next entry.)*

## [2026-05-28] Serialize ActivityKit ops via a task-chain, not a fire-and-forget end()

**Context**: The v1 `LiveActivityController.finish()` nilled `self.activity` then ended it in an un-awaited `Task`. Because `finish()` is called from `ConversationViewModel.state.didSet` — a **synchronous** context — it cannot `await`. So a fast `finish()` → `showThinking()` (a barge-in: speaking → recording → thinking within tens of ms) could `Activity.request` a new activity while the old one was still tearing down: transient duplicate, or a rare silent no-show if the 8-activity system limit was momentarily hit.

**Decision**: Route every ActivityKit operation through a serial `pending: Task<Void, Never>?` chain — each enqueued op `await`s the prior one before running. `request`/`update`/`end` therefore never overlap, and `end()` always completes before the next `request()`. `finish()` stays synchronously callable (it just enqueues). Also added a 180s `staleDate` (refreshed each update) as a dead-app safety net, and logged the previously-swallowed `Activity.request` error.

**Alternatives considered**: (a) make `finish()` async + `await end()` before returning — rejected, the caller (`didSet`) is synchronous; (b) a `tearingDown` bool guard that no-ops new requests during teardown — rejected, it has its own gap (a legitimate new turn during teardown would silently show nothing, and the bool has no handle to await).

**Rationale**: The task-chain is the idiomatic Swift-concurrency way to serialize async work on an actor and subsumes the flag approach (it *is* the handle). ~10 lines, no new dependencies, kills the whole race class rather than papering over it. `staleDate` was deliberately set generous (far longer than any single turn) so it never marks a live turn stale — distinct from `nil` ("never stale"), which left a force-quit activity stuck on the lock screen forever.

## [2026-06-15] Hermes voice prelude rides as ACP `_meta` → per-turn ephemeral system prompt (cross-repo)

**Context**: The "keep replies terse/plain" voice prelude was applied to Hermes only on turn 1 (prepended to the user text); resumed turns drifted verbose. ACP has no system-prompt field, so there was no obvious place for a persistent voice instruction. (`make_speakable` already guarantees CLEAN spoken output every turn — this is only the CONCISENESS lever.)

**Decision**: Send the prelude as ACP `_meta` on every `conn.prompt(...)` from hermes-voice (`acp_client.py`: `voice_system_prompt=_VOICE_PRELUDE`). The acp client maps extra prompt kwargs to the request's `_meta`; the acp router flattens `_meta` into the agent handler's kwargs (`router.py: params.update(meta)`). The Hermes agent (`~/.hermes/hermes-agent` `acp_adapter/server.py` prompt handler) reads `kwargs.get("voice_system_prompt")` and sets `agent.ephemeral_system_prompt` before `run_conversation` — appended to the system prompt at API-call time every turn, never written to the transcript.

**Alternatives considered**: (a) prepend the prelude to the user text every turn (in-repo only) — rejected: costs prelude tokens AND pollutes stored history every turn, needing a `sessions.py` strip-all-user-messages fix; (b) leave it turn-1-only — rejected: the drift is the bug; (c) bake a voice prelude into the Hermes agent — rejected: keeps the agent general by having it honor a generic ACP `_meta` extension instead of hardcoding a client's concern.

**Rationale**: `_meta` is ACP's sanctioned extension channel, so an unpatched agent absorbs it harmlessly (the handler has `**kwargs`) — safe to deploy in either order. `ephemeral_system_prompt` is already a mutable per-turn AIAgent attribute (the tui_gateway sets it live), so the prelude shapes every turn (incl. resumes) at the cost of only the prelude tokens per call, and never lands in the transcript — the same never-stored property as Claude's `--append-system-prompt`. The Hermes agent is an editable install, so no rebuild — a backend restart respawns the warm child with the new code. Cross-repo commits: hermes-voice `5911c44`, hermes-agent `fda7e544e` (local `main`, NOT pushed — user PRs per their monorepo workflow). Verified: backend restarted clean (`/health` ok, warm child PID 3646, clean ACP init); hermes-voice unit test asserts the `_meta` is sent on a resume turn. On-device turn-test pending.

## [2026-06-15] Swap on-device TTS from Kokoro (FluidAudio) to Apple AVSpeechSynthesizer

**Context**: On-device live testing (build 23) surfaced three Kokoro TTS bugs: (1) the voice picker always spoke the default female voice regardless of selection; (2) homographs mispronounced ("is" → "eyes"); (3) numeric values dropped/garbled ("72" spoken as "x"). A 3-agent diagnosis (workflow `w33f0zdoe`) traced ALL three to FluidAudio's on-device Kokoro, NOT the backend: (a) the English KokoroAne variant only ships ONE voice embedding (`af_heart.bin`) on HuggingFace — `am_michael`/`bf_emma`/`bm_george` 404, throw, and `LocalSpeaker` silently fell back to `af_heart`; (b) Kokoro's English G2P is a context-free per-word BART char model with no runtime lexicon hook, so it guesses homographs wrong; (c) FluidAudio's number/ITN normalizer (`SayAsInterpreter`/`TextNormalizer`) is dead code reachable only via SSML, never wired into the KokoroAne path. The backend `make_speakable` only strips markdown and the on-device path sends `tts=none`, so the backend was provably not involved.

**Decision**: Replace FluidAudio/Kokoro in `LocalSpeaker` with Apple's `AVSpeechSynthesizer`. Keep the same public API (`speak`/`stop`/`voices`/`isReady`), keep `makeSpeakable` for markdown stripping, and resolve voices via logical `<lang>-<gender>` ids (`en-US-female`, `en-US-male`, `en-GB-female`, `en-GB-male`) to the best-quality installed `AVSpeechSynthesisVoice`, migrating legacy `local:af_heart`-style selections.

**Alternatives considered**: (a) keep Kokoro + add a number/symbol pre-normalization shim — rejected as insufficient: a shim fixes numbers but cannot fix context-dependent homographs (no lexicon API on Kokoro's English path); (b) generate/host the missing Kokoro `.bin` voice packs ourselves — large effort, doesn't fix pronunciation; (c) route TTS server-side (ElevenLabs) — gives up the offline/private/zero-cost properties on-device TTS exists to provide.

**Rationale**: AVSpeech inherits Apple's mature text normalizer (numbers, dates, currency, homographs), ships with the OS (no model download), is always available, gives real selectable voices, and stays fully offline/private — fixing all three bugs at once with the smallest, lowest-risk change. Trade-off: more "system TTS" voice character than Kokoro's neural voices (mitigable with downloaded Enhanced/Premium voices). FluidAudio stays a dependency for on-device STT (`LocalTranscriber`) and VAD. Verified: iOS BUILD SUCCEEDED (simulator); adversarial review confirmed the barge-in continuation race is handled (an utterance-identity guard ignores the async `didCancel` from `stopSpeaking(.immediate)` so it can't tear down the next turn's continuation) and caught a silent gender-downgrade in the resolver (fixed: prefer exact gender → `.unspecified` → other, with a breadcrumb log).

**Known follow-up**: surface a Settings note when a requested voice's gender isn't installed on the device (today it logs a breadcrumb + degrades silently). Swift↔backend `make_speakable` parity is still manual (no iOS test target).

## [2026-06-15] ACP warm path is the default; subprocess kept as the HERMES_USE_ACP=0 fallback

**Context**: The "make Hermes rock solid" migration (Phases 0–3b) shipped a warm `hermes acp` server behind `HERMES_USE_ACP` (default OFF), validated in prod via a `backend/.env` override for ~2 days (warm child PID 66662 stable) and on-device. Phase 4 was the cutover decision: make the warm path permanent, and either retire or keep the legacy per-turn subprocess `HermesClient`.

**Decision**: Flip `HERMES_USE_ACP` to default ON (`config.py` field default + the `_bool` env default). KEEP the subprocess `HermesClient` path as an explicit, documented fallback — `HERMES_USE_ACP=0` + backend restart reverts to it. No code deleted.

**Alternatives considered**: Delete the subprocess path entirely (smaller surface, but removes the escape hatch); leave the default OFF and rely on the `.env` override indefinitely (fragile — a fresh deploy without the `.env` line silently regresses to the 2m56s cold-start).

**Rationale**: Default-ON makes the fast path the one you get without special configuration, so a clean redeploy can't silently regress. Keeping the subprocess path costs ~nothing (already written + tested) and preserves a one-env-var rollback if the warm server ever misbehaves — the reversible safety the "rock solid" goal wants. The running prod backend already used ACP via the override, so the flip was behavior-neutral (no restart needed); the now-redundant `.env` line is harmless. Completes the initiative.

## [2026-05-29] One `.sheet(item:)` per view, never stacked `.sheet(isPresented:)`

**Context**: Adding the in-app transcript sheet to MainView (redesign W3) silently broke the History sheet — discovered only on device. MainView had three `.sheet(isPresented:)` modifiers stacked on one view (settings/history/transcript). SwiftUI lets a later sheet modifier shadow earlier ones on the same view, so History stopped presenting once transcript was added.

**Decision**: MainView drives all modal presentation from a single `.sheet(item: $activeSheet)` with an `ActiveSheet` enum (`settings`/`history`/`transcript`); env objects injected explicitly per case.

**Rationale**: One presenter per view is the reliable SwiftUI pattern; stacking `.sheet(isPresented:)` (or `.fullScreenCover`) on a single view is a known footgun. The enum also makes "one sheet at a time" explicit, and adding a sheet is one more `case` rather than another stacked modifier that can shadow the others. Lesson, like the nested-sheet env-object one: this class of bug is Release/runtime-only and won't show up in `xcodebuild` — it needs the app actually running.

## [2026-06-20] Voice fast profile gated on the ACP `_meta` voice signal (not a global config)

**Context**: User reported voice responses "super slow." Systematic-debug of the live backend log traced the latency entirely to the agent loop (not the hermes-voice transport): the agentic tool loop runs 7–16 sequential model round-trips/turn (2–9s each), and after tool-heavy turns a background "self-improvement review" forks a second agent (~45s, 3 more model calls) that ties up the single warm child right as the user speaks again. The high-leverage knobs (`reasoning_effort`, the review's nudge intervals) live in `~/.hermes/config.yaml` / hermes-agent — shared with the user's *terminal* Hermes.

**Decision**: Make a voice-only "fast profile" in the hermes-agent ACP adapter (`acp_adapter/server.py` prompt handler), keyed on the `voice_system_prompt` `_meta` field the voice backend already sends every turn: set `reasoning_config={'effort':'low'}`, `_skill_nudge_interval=0`, `_memory_nudge_interval=0`. Capture the configured defaults once and restore them for any non-voice ACP turn (e.g. Zed). Terminal Hermes is a separate process and is untouched.

**Alternatives considered**: (a) Global `reasoning_effort: medium→low` in config.yaml — one line, but drops the user's terminal Hermes to low effort too. (b) Raise the nudge thresholds globally. (c) Leave effort, only kill the review. The user explicitly chose the voice-only scoping + skip-review.

**Rationale**: Voice is a latency-sensitive *spoken* interface, not a coding session — low effort + no between-turn self-improvement is the right trade *there* without degrading full-power terminal use. Gating on the existing `_meta` voice signal needs no new protocol field and no hermes-voice change. Reversible (delete the block). Separately flagged but deferred: a 60s `rg --files --sortr=modified` over `/Users/tfinklea` (the ACP session cwd is the home dir) — real latency landmine but already timeout-bounded and in the *shared* tool layer, so out of scope for a voice-only change.

## [2026-06-26] Spoken filler: dedicated backend `narrate` event, NOT agent-narrated reply

**Context**: The felt problem with voice is silence during a turn (perceived latency), not raw speed. The user wants spoken acks + progress narration ("I'm looking up the weather in your area"). The obvious approach — tell the agent to narrate its own actions into its reply — was evaluated and rejected.

**Decision**: Two non-overlapping spoken sources. (1) An **instant on-device acknowledgment** synthesized by iOS at turn dispatch (`FillerPhrases.ack()`), because no backend signal exists yet at that instant and AVSpeech can speak with zero network latency. (2) **Tool-progress narration from a dedicated backend SSE event** (`{"type":"narrate","text":...}`), built by a pure `tool_narration(name, preview, args)` from the structured tool name+args the backend already receives at tool-call START — never parsed out of the agent's reply token stream. `.tool` events stay visual-only; the `narrate` event is the single spoken tool source.

**Alternatives considered**: (a) Agent narrates into its reply stream via sentinel tags — rejected: it fights the verified `_VOICE_PRELUDE` ("Do NOT narrate what you did", reasoning `low`), so the model skips it unreliably (a skip is indistinguishable from a fast turn), and tag-parsing risks leaking sentinel glyphs into TTS or swallowing the answer tail. (b) iOS-templated per-tool phrases (no backend) — reliable but generic, and duplicates phrase logic + suffers tool-name vocab rot in the app. (c) Backend synthesizes the filler audio — wrong for the on-device `tts="none"` path.

**Rationale**: Centralizing tool phrases in the backend gives context ("in your area" from the structured location arg) with one source of truth and no double-speak coordination, while the iOS-local ack gives the fastest possible time-to-first-sound. Keeping narration on its own SSE channel (out of `reply_parts`) means it can never corrupt the authoritative reply or trip the empty-reply guard. Phased + additive: new event type, legacy/mock paths simply never emit it. The judged design workflow (`w8y7ffq3k`) ranked agent-narrated lowest (reliability 2/5); this path scored highest on reliability + time-to-first-sound.

## [2026-07-15] APNs with multiple backends: active-only registration for v1

**Context**: Server profiles let one phone talk to two laptops. Sol's adversarial plan review found APNs pushes carry no backend identity (`backend/app/push.py` payload = `schedule_id` + `session_id` only), so with the device token registered on both laptops, a push from the *inactive* laptop would resume/replay its session against the *active* one — wrong backend, broken replay. The server-profiles design as written ("register the token with the newly active backend", "no backend API changes") cannot route two pushing laptops safely.

**Decision**: v1 is **active-only**: on a profile switch, best-effort unregister the device token from the previous backend, then register with the new one. Only the active laptop can deliver pushes. Registration/unregistration failures stay logged-and-non-blocking per the design.

**Alternatives considered**: (a) Multi-backend identity — add source/profile identity to device registration + push payload and route/switch on tap; correct but a backend API change the design forbade, and larger iOS routing work. (b) Defer — register everywhere, never unregister; zero work but mis-routes pushes silently.

**Rationale**: User decision (2026-07-15). Active-only preserves the explicit-switching philosophy and the no-backend-change constraint using the existing `/api/devices` unregister endpoint; multi-backend identity is deliberately queued as a v2 backlog item rather than scope-creeping v1.

