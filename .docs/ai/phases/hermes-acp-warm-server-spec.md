# Hermes ACP Warm-Server Migration — Spec

> Initiative: **make Hermes rock solid** (trust it like Jarvis, no babysitting).
> Author: Opus 4.8. Date: 2026-06-13. Scope: **Hermes harness only** — Claude /
> Codex / OpenCode are explicitly out of scope for this initiative (user
> directive 2026-06-13). Spike-validated before writing (see §2).

## 1. Problem — verified diagnosis

The whole "Hermes feels unreliable" complaint traces to one structural choice and
a vicious feedback loop on top of it.

1. **Subprocess-per-turn cold start.** `backend/app/hermes.py` runs `hermes chat
   -q <prompt>` (and `-Q -q`) as a **fresh subprocess on every turn**. Each
   invocation re-pays full agent init: imports (~1–1.5s), MCP discovery, provider
   credential resolution, model-client construction, then the first model call.
   `_run_cleanup` (atexit) tears the MCP server down on exit, so nothing is
   amortized. (`hermes.py:124,179`; Hermes `hermes_cli/main.py:14770` atexit.)
2. **Synchronous, blocking MCP discovery before the agent is built.** The non-TUI
   `chat` path calls `_prepare_agent_startup → tools.mcp_tool.discover_mcp_tools()`
   **inline** (Hermes `hermes_cli/main.py:14495 → :11289`). It blocks up to **120s**
   (`_run_on_mcp_loop(..., timeout=120)`), 60s per-server connect timeout × 3
   retries (`tools/mcp_tool.py:261-263,3336,3432`). The recent perf fix
   (`cbf851ae1`) that backgrounds discovery **only touched `tui_gateway/`** — the
   `chat -q` path never got it.
3. **The circular dependency.** The user's **only** configured MCP server is
   `hermes-voice` (the schedules server), which spawns a venv subprocess pointed at
   `HERMES_VOICE_BASE_URL=https://scadrial.tailceb58.ts.net:8765` — **the
   hermes-voice backend itself** (`~/.hermes/config.yaml:588-595`). So every voice
   turn is: backend receives turn → spawns `hermes chat` → Hermes blocks
   discovering the schedules MCP → which calls *back into the backend*. Healthy:
   ~0.4s. **Backend restarting/slow (the documented 404 failure mode): discovery
   stalls toward 60–120s on every turn** — the measured **2m56s "pong"**. That MCP
   server has been **called 3 times ever** vs **15,734 tool-list round-trips** —
   near-pure tax.
4. **Brittle text-scraping contracts.** The live turn path scrapes stdout/stderr:
   `session_id:` line (Hermes `cli.py:15455`), the `--resume` footer
   (`cli.py:12406`), and the `┊` tool-preview lines (Rich console formatting). Any
   cosmetic CLI change silently breaks these. The authoritative reply + tools come
   from a *separate* `hermes sessions export <id>` re-read of `state.db`, windowed
   by `time.time()` (`session_audit.py`).
5. **Wrapper resilience gaps** (independent of speed; from the recon):
   - Backend `hermes_timeout` env-default **180s** < iOS client **300s** → turns
     killed server-side while the phone still waits (`config.py:109`,
     `HermesVoiceAPI.swift:473`). Dataclass default is 300 — config is the bug.
   - Streaming adapters `await proc.wait()` but **never check `returncode`**
     (`hermes.py:215-222`); a crashed agent can surface as success-with-stale-reply
     or as a misleading "no assistant text" error.
   - iOS stream→single-shot fallback fires on **any** non-2xx
     (`ConversationViewModel.swift:235-237,279-280`), **silently**, and can
     **re-run a side-effectful turn**.
   - Auxiliary failures (post-hoc export, tool audit, TTS) can **downgrade a
     succeeded turn into an on-screen error** (`hermes.py:217-222`,
     `main.py:768-773,835-837`).
   - History-recovery dedups by **exact assistant text**, so identical short
     confirmations (`Saved.`/`Done.` — exactly what the prelude promotes) defeat
     recovery (`ConversationViewModel.swift:427-429`).
   - Subprocess teardown only happens on `TimeoutError`; an abandoned generator can
     leave an agent child running (`hermes.py:197-215`).

## 2. What we verified (spike + recon, 2026-06-13)

A throwaway ACP client (`/tmp/acp_spike.py`) driving `hermes acp` proved every
load-bearing claim:

| Measurement | Result |
|---|---|
| spawn → `initialize` ready (one-time boot incl. MCP discovery) | **1.05s** |
| `new_session` | 1.90s |
| turn 1 (first model call) | 3.66s → `pong` |
| **turn 2 (WARM)** | **1.97s** → `ping` |
| **turn 3 (WARM)** | **1.27s** → `pong` |
| events received | `agent_message_chunk`, `agent_thought_chunk`, `usage_update` |

**~1–2s warm vs 2m56s subprocess** (~100×). Confirmed in `~/.hermes/state.db`:
the ACP session `ab686cf5-…` landed with `source='acp'`, 6 messages — the **same
store** the terminal CLI reads (`hermes --resume <uuid>` would see it;
`hermes_cli/main.py:1070 db.get_session` has no source filter).

Verified API surface (installed `agent-client-protocol==0.9.0` in the hermes venv):
- **Client entry:** `acp.spawn_agent_process(to_client, "<hermes>", "acp",
  use_unstable_protocol=True)` → async-context `(ClientSideConnection, process)`.
- **Agent methods (we call):** `conn.initialize(protocol_version=acp.PROTOCOL_VERSION)`,
  `conn.new_session(cwd=...)` → `NewSessionResponse.session_id`,
  `conn.prompt(prompt=[TextContentBlock(type="text", text=...)], session_id=...)`
  → `PromptResponse.stop_reason`. Also available: `resume_session`, `load_session`,
  `list_sessions`, `cancel`, `set_session_model`, `fork_session`, `close_session`.
- **Client callbacks (we implement):** `session_update(session_id, update)` (push
  events), `request_permission(options, session_id, tool_call)` (write approval).
  Interface: `acp/interfaces.py` `Client`/`Agent` protocols.
- **Event types:** `AgentMessageChunk` (`.content.text`), `AgentThoughtChunk`,
  `ToolCallStart`/`ToolCallProgress` (`.tool_call_id`, `.title`, `.status`,
  `.content`), `UsageUpdate`, `AvailableCommandsUpdate`. Each carries a
  `session_update` discriminator string (`agent_message_chunk`, `tool_call`,
  `tool_call_update`, …). See `acp_adapter/events.py`, `acp/schema.py`.
- **Session schema:** `sessions` table has a `system_prompt TEXT` column —
  the hook for persistent voice shaping.
- **Start command:** `~/.local/bin/hermes acp` (bash wrapper unsets PYTHONPATH/HOME,
  execs the venv hermes). The `acp` extra is already installed.

## 3. Goals / Non-goals

**Goals**
- Eliminate per-turn cold start: one warm agent across turns (target: a trivial
  turn returns in ≤3s wall-clock end-to-end, vs minutes).
- Replace stdout/stderr scraping with ACP structured events on the live path.
- Persist voice shaping across all turns including resume (cure the verbose-on-
  resume bug at the source via per-session `system_prompt`).
- Every turn **succeeds or fails loudly + recovers** — close the resilience gaps.
- Preserve terminal⇄voice session continuity (same `state.db`) and the history /
  replay features.
- Ship behind a flag with the subprocess path as instant rollback.

**Non-goals (this initiative)**
- Other harnesses (Claude/Codex/OpenCode) — untouched; their `_VOICE_PRELUDE`
  first-turn handling stays as-is.
- A native HTTP/websocket ACP front-door — the co-located **stdio child process**
  is sufficient and matches how editors drive ACP. (A socket shim is a small
  future option since `acp.run_agent` accepts arbitrary streams.)
- Rewriting the history-browser/replay UI. It keeps reading `state.db` by id.
- Exposing ACP on a network socket (it is local-trust/no-auth by design).

## 4. Architecture

```
FastAPI lifespan
  └── HermesAcpServer (owns ONE long-lived `hermes acp` child, ACP/JSON-RPC/stdio)
        ├── health/respawn supervision
        └── N ACP sessions (one per iOS conversation), UUID ids in state.db
HermesAcpClient (implements the existing HermesClient interface)
  ├── ask(prompt, session_id)            -> HermesReply         (non-streaming)
  └── ask_streaming(prompt, session_id)  -> StreamTool|StreamReply (live events)
        maps ACP session_update -> existing StreamTool / StreamReply types
main.py turn pipeline  (unchanged shape; resolves Hermes harness to HermesAcpClient
                        when HERMES_USE_ACP=1, else the legacy subprocess client)
```

**Event mapping** (ACP `session_update` → existing wrapper types):

| ACP event | Wrapper output |
|---|---|
| `agent_message_chunk` (`.content.text`) | accumulates `StreamReply.text` (no export re-read) |
| `tool_call` (`ToolCallStart`) | `StreamTool(name, preview)` live chip |
| `tool_call_update` (`ToolCallProgress`) | tool completion / `ok` status for the authoritative list |
| `agent_thought_chunk` | optional live "thinking" stream (future) |
| `usage_update` | token counts (future telemetry) |
| `PromptResponse.stop_reason` | turn-complete signal |

**Key properties**
- **One server, N sessions.** `SessionManager` keeps a warm `AIAgent` per session;
  multiple iOS conversations = multiple ACP sessions in the one child.
- **Sequential per conversation** (voice is one turn at a time); concurrent prompts
  on one session queue server-side. Different sessions are independent.
- **Voice shaping via `system_prompt`** set once at `new_session` → persists for
  every turn including resume (structural fix). [Spike S1 confirms the mechanism.]
- **Flag + fallback:** `HERMES_USE_ACP` (default off until Phase 4). The legacy
  `HermesClient` subprocess path remains and is the rollback.

## 5. Phases

Each phase is independently shippable, has its own commit(s), and a Verify gate.
Backend test command (per repo convention): `uv run --project backend pytest`
(sync `uv sync --extra dev`, **not** `--all-extras`). iOS: `xcodegen generate &&
xcodebuild -project ios/HermesVoice/HermesVoice.xcodeproj -scheme HermesVoice
-destination 'generic/platform=iOS Simulator' build CODE_SIGNING_ALLOWED=NO`.

### Phase 0 — Tier-0 quick win — **DONE (2026-06-13)**
- `~/.hermes/config.yaml`: `hermes-voice` MCP server `connect_timeout: 5` (was
  unbounded → 60–120s). Takes effect next `hermes` invocation; no restart for the
  voice path. **Lossless** (healthy connects ~0.4s).
- **User action (flagged, not done by agent):** kill the stale 19-day interactive
  `hermes` session (PID 8503) leaking `mcp_schedules.py` child (5126).
- Acceptance: a voice turn while the backend is mid-restart no longer hangs minutes.

### Phase 1 — `HermesAcpClient` foundation (the cold-start killer)
- **Scope:** new `backend/app/acp_client.py` — `HermesAcpServer` (lifespan-owned
  warm child + supervision) + `HermesAcpClient` satisfying the **existing
  `HermesClient` interface** (`is_available`, `describe`, `ask`, `ask_streaming`).
  Map ACP events → `StreamTool`/`StreamReply` (defined in `hermes.py`). Register it
  in `create_app` behind `settings` flag `HERMES_USE_ACP`; **mirror the existing
  `HermesClient` registration pattern** — do not re-architect the registry.
- **Files:** new `acp_client.py`; `config.py` (+`use_acp: bool` from
  `HERMES_USE_ACP`); `main.py` lifespan (spawn/teardown the child — mirror how
  mdns/schedules executor are started/stopped in lifespan); `harness.py`/registry
  wiring. New `backend/tests/test_acp_client.py`.
- **Codebase-derived (read first, don't prescribe blind):** the exact
  `HermesClient` Protocol shape and how `create_app` registers harnesses
  (`harness.py`, `main.py`); the lifespan start/stop idiom; the `StreamTool`/
  `StreamReply` fields (`hermes.py:82-95`).
- **Acceptance:** with `HERMES_USE_ACP=1`, a text turn through `/api/text` and a
  streamed turn through `/api/text/stream` both return a correct reply sourced from
  ACP events (no `hermes chat` subprocess spawned for the turn; verify via process
  inspection / logs). Warm second turn ≤3s end-to-end.
- **Verify:** `uv run --project backend pytest` green (new tests: event→type
  mapping with a fake ACP connection; flag routing; warm-child reuse). Manual:
  restart backend with the flag, drive two turns, confirm no per-turn `hermes chat`.

### Phase 2 — Session model + persistent shaping
- **Scope:** iOS conversation ↔ ACP session lifecycle: `new_session` on first turn
  (capture UUID as the conversation's `session_id`), reuse it on subsequent turns,
  `resume_session`/`load_session` for continuing a prior voice session. Set the
  **voice prelude as the session `system_prompt`** at creation [pending Spike S1 —
  if `new_session` can't carry it, add the minimal Hermes-side support; you own
  Hermes]. Confirm the history browser + `/api/replay` still resolve ACP sessions
  (`hermes sessions export <uuid>` reads `state.db` by id — verify).
- **Acceptance:** a multi-turn voice conversation keeps context across turns;
  resuming it later works; a *resumed* turn obeys the terse voice shaping (no
  markdown/verbosity) **without** re-sending the prelude each turn; the session
  appears in History and replays.
- **Verify:** pytest green; manual on-device: 3-turn conversation, background the
  app, resume, confirm continuity + terse shaping + History/replay.

### Phase 3 — Resilience hardening (the gaps ACP doesn't auto-fix)
- **Scope (each item independently testable):**
  1. **Timeout unification** — one source of truth; backend ceiling ≥ client (or
     iOS reads `/health.timeout_seconds`, already exposed); a **typed** timeout
     error distinguishable from other failures. (`config.py`, `hermes.py`/
     `acp_client.py`, iOS error mapping.)
  2. **iOS fallback** — fire stream→single-shot **only on 404/405**; surface
     401/413/422/503 directly; **never auto-retry a possibly-side-effectful turn**;
     make any fallback **visible** (indicator/telemetry).
     (`ConversationViewModel.swift:235-237,279-280`.)
  3. **Don't downgrade success** — an auxiliary failure (export/audit/TTS) must not
     turn a succeeded turn into an error; keep the ACP reply authoritative; mark
     "audit unavailable" distinctly from "zero tools"; emit `tts_unavailable`
     rather than going silent. (`main.py:768-773,835-837`.)
  4. **No post-reply error events** — once the authoritative reply is emitted,
     downstream failures must not paint the turn red; iOS `.failed` ignores an
     error arriving after a reply is on screen. (`main.py:844-846`,
     `ConversationViewModel.swift:373-375`.)
  5. **History-recovery anchor** — recover by message position/timestamp after the
     known user text, not global text-uniqueness, so `Saved.`/`Done.` recover.
     (`ConversationViewModel.swift:427-429`.)
  6. **Teardown guarantees** — ACP removes per-turn subprocess teardown, but add an
     idle/approval-wait timeout and confirm child reap on shutdown/crash.
- **Acceptance:** each gap has a regression test or a named on-device check; a
  crashed/killed agent turn surfaces a clear typed error; a backend restart mid-
  turn recovers or fails loudly (never silently degrades unobserved).
- **Verify:** pytest green (new resilience tests); iOS build green; on-device
  checklist for the UI-visible items.

### Phase 4 — Cutover + cleanup
- **Scope:** flip `HERMES_USE_ACP` default on; retain the subprocess path as an
  explicit fallback (`HERMES_USE_ACP=0`) for ≥1 release, OR retire it once trusted.
  Update README/architecture + `backend/docs`, `.docs/ai/*`, and memory
  ([[backend-restart-required-for-backend-changes]] still applies; add an ACP-server
  restart note).
- **Acceptance:** default voice path is warm-ACP; rollback is one env var; docs
  current.
- **Verify:** full pytest + iOS build green; a TestFlight build cut and on-device
  smoke-tested (warm latency + terse shaping + tool feed + recovery).

## 6. Open questions → resolve via spike before/within their phase

- **S1 (Phase 2, do first):** Can `new_session` carry a per-session `system_prompt`
  (voice prelude)? Check `NewSessionRequest`/`HermesACPAgent.new_session`
  (`acp_adapter/server.py`, `acp_adapter/session.py`) and whether it writes
  `sessions.system_prompt`. If not exposed, add minimal Hermes-side support
  (you own the repo). Extend `/tmp/acp_spike.py` to assert a resumed turn obeys it.
- **S2 (Phase 1):** Warm-child lifecycle — crash detection + respawn, startup
  readiness gating, and graceful shutdown reaping the child + its MCP children on
  backend stop. Decide the supervision model (restart-on-exit with backoff).
- **S3 (Phase 2):** "Attach to a *terminal-created* Hermes session" — ACP refuses
  to warm-restore a `source='cli'` row into its pool
  (`acp_adapter/session.py:493-495`). Confirm voice never needs this (the attach
  feature was Claude-specific); if it does, design the bridge or document the limit.
- **S4 (later, optional):** Write-turn approval via ACP-native
  `session/request_permission` (simpler than the Claude-SDK broker) — Hermes
  write turns could ride it. Out of the critical path; note for a follow-up.
- **S5 (Phase 2):** Verify `hermes sessions export <acp-uuid>` returns the
  transcript so History/replay are unaffected.

## 7. Risks + rollback

- **Unstable protocol:** ACP runs `use_unstable_protocol=True` (agent-client-
  protocol 0.9.0); a Hermes update could shift it. **Mitigation:** the
  `HERMES_USE_ACP` flag + retained subprocess fallback; pin/track the `acp`
  version; the spike is re-runnable as a canary.
- **Single warm child = SPOF:** one crash kills all live sessions. **Mitigation:**
  S2 supervision (respawn + per-session re-`new_session`/`resume`), and the
  subprocess fallback.
- **UUID session ids** differ from the CLI `YYYYMMDD_…` format — confirm iOS +
  History tolerate either (they treat session_id as opaque; verify).
- **Local-trust transport:** keep `hermes acp` a co-located child over stdio; never
  bind it to a network socket without adding auth.

## 8. Out of scope / deferred (tracked, not bundled)

- Claude/Codex/OpenCode parity (separate initiative; their prelude migration item
  stays in the roadmap backlog).
- Native HTTP/websocket ACP front-door.
- ACP-native write approval (S4) — follow-up.
- Removing the schedules MCP from the voice path entirely (the backend owns
  schedules; the MCP round-trip may be redundant) — revisit after cutover.
