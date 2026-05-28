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

