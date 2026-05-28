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

