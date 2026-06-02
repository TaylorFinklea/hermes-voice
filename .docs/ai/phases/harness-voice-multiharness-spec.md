# Harness Voice — rebrand + multi-harness backend

Spec authored 2026-06-02 (Opus). Status: in progress. Drives the rebrand of
"Hermes Voice" → "Harness Voice" and the addition of Claude Code / Codex /
OpenCode as selectable backends alongside Hermes.

## Decisions (locked by user 2026-06-02)

- **Rebrand scope: full identity** — new bundle id `dev.finklea.harnessvoice`,
  renamed services/data-dir/Bonjour/MCP, display name + UI strings. Accepted
  consequence: a NEW App Store Connect app record + APNs key are required before
  the next TestFlight upload (the old `dev.finklea.hermesvoice` record is left
  behind). User chose this knowingly.
- **Working dir for coding harnesses: one shared workspace** at
  `~/.harness-voice/workspace` (created on startup). Claude/Codex/OpenCode are
  cwd-scoped coding agents — Hermes is not.
- **Capability level: workspace-write, sandboxed** — agents may edit files in
  the workspace + run sandboxed commands, no system-wide escape / destructive
  ops, no blanket auto-approve-everything.
- **Harness selection: per-turn `harness` param** (mirrors existing
  `tts`/`voice_id`), default `hermes`; iOS Settings picker chooses the default.
  No server restart to switch.

## CRITICAL: rebrand is surgical, NOT a blind s/hermes/harness/

"Hermes" becomes the name of ONE harness. Three token classes:

| Class | Examples | Action |
|---|---|---|
| Product identity | `hermes-voice` (slug), `hermesvoice` (bundle id), `Hermes Voice`, `Ask Hermes`, `CFBundleDisplayName: Hermes` | **REBRAND** → harness-voice / harnessvoice / Harness Voice / Ask Harness / Harness |
| Hermes the harness | `HermesClient`, `hermes.py`, `hermes_bin`, `HERMES_*` env, `~/.hermes/state.db`, `hermes sessions export`, "Hermes Agent" | **KEEP** (one harness among several) |
| Internal codename | `HermesVoice` Xcode targets, Swift types (`HermesVoiceApp`, `HermesVoiceAPI`, `HermesActivityAttributes`, `AskHermesIntent`…), source dir tree, `.xcodeproj`, scheme | **KEEP** — renaming = high churn + breaks `release.sh -scheme HermesVoice`; invisible to users/store. Internal codename ≠ product name. |

Safe case-sensitive global tokens (only ever denote the product, never the harness):
- `hermes-voice` → `harness-voice` (Bonjour `_hermes-voice._tcp`, `~/.hermes-voice`, `hermes-voice-backend`, `hermes-voice-schedules`, `/tmp/hermes-voice.log`, repo/docs refs)
- `hermesvoice` → `harnessvoice` (bundle ids `dev.finklea.hermesvoice[.*]`)
- `Hermes Voice` → `Harness Voice` (UI copy, comments)
- `Ask Hermes` → `Ask Harness` (Siri intent titles)

Bare-word "Hermes" / "Hermes Agent" in copy: handle per-file — change product
refs to "Harness"; change agent refs ("your self-hosted Hermes Agent") to "your
agent" (generic, since multi-harness). Do NOT touch `Hermes`-the-harness in
code identifiers.

## Phases

### P0 — Rebrand (identity + strings)  ← do first, commit, build-verify
- `ios/HermesVoice/project.yml` (source of truth for plists): CFBundleDisplayName ×3 Hermes→Harness; bundle ids hermesvoice→harnessvoice (app, `.watchkitapp`, `.widget`, watch `WKCompanionAppBundleIdentifier`); Bonjour `_hermes-voice._tcp`→`_harness-voice._tcp`; usage-description copy.
- Backend identity: `config.py` apns_bundle_id; `mdns.py` SERVICE_TYPE; `schedules.py` data dir `~/.hermes-voice`→`~/.harness-voice` (+ best-effort one-time rename of old dir if present); `mcp_schedules.py` FastMCP name; `pyproject.toml` package name; `push.py` if it hardcodes bundle id.
- iOS: `NotificationManager.swift` fallback bundle id; `BackendBrowser.swift` Bonjour type; UI strings across Views/Intents.
- launchd: `git mv` the two plists to `dev.finklea.harnessvoice.*`; fix Label + StandardOut/Err paths inside.
- Regenerate: `cd ios/HermesVoice && xcodegen generate`. Grep generated plists for residual product tokens.
- Verify: iOS `xcodebuild … build CODE_SIGNING_ALLOWED=NO` SUCCEEDED; `uv run --project backend pytest -q` (mdns 2 flakes known). Commit.
- ACTION ITEM for user (not blocking sim build): create new ASC app for `dev.finklea.harnessvoice` + APNs key before next `release.sh`.

### P1 — Backend HarnessClient protocol refactor (no behavior change)
- New `backend/app/harness/__init__.py` (or `harness_base.py`): `HarnessClient` Protocol with: `is_available() -> bool`, `describe() -> dict`, `async ask(prompt, session_id=None) -> Reply(text, session_id)`, `async ask_streaming(prompt, session_id=None) -> AsyncIterator[StreamTool|StreamReply]`, `async fetch_tool_calls(session_id, since_ts) -> list[ToolCallSummary]`. Shared dataclasses (Reply/StreamTool/StreamReply/ToolCallSummary) move here.
- `hermes.py`: `HermesClient`→`HermesAdapter` implementing the protocol (mechanical; keep all current logic incl. the resume-footer session_id capture — that mechanism is correct, see [[backend-restart-required-for-backend-changes]] sibling notes). `MockHermesClient`→`MockAdapter`.
- `config.py`: add generalized `harness_bin`/`harness_timeout`/`harness_extra_args` (keep reading `HERMES_*` env for back-compat; Hermes adapter uses them). Add `harness_workspace_dir` (default `~/.harness-voice/workspace`), `harness_sandbox` (default `workspace-write`).
- `main.py`: `app.state.hermes`→`app.state.harness` as a registry `{name: HarnessClient}` built from available bins; keep a `default_harness` (`hermes`). `_run_turn`/`_stream_turn` take a `harness` name, look it up, fall back to default. `/health` `describe()` lists all available harnesses.
- Verify: backend tests green (existing tests must pass unchanged — Hermes still default). Commit.

### P2 — Claude / Codex / OpenCode adapters + dispatch
Each adapter implements `HarnessClient`, runs in `harness_workspace_dir` with the workspace-write sandbox. Verified CLI shapes (machine probe 2026-06-02):
- **ClaudeAdapter** (`claude` 2.1.160): one-shot `claude -p "<prompt>" --output-format json`; live `claude -p "<prompt>" --output-format stream-json --include-partial-messages --verbose`. session_id in the system/init event; tool_use/tool_result + final text inline in the stream → ask + ask_streaming + authoritative reply all from ONE invocation. Resume: `-r/--resume <id>` (or `--session-id <uuid>` to pin). Sandbox: permission mode (acceptEdits within cwd; no bypass). Backfill (History): read `~/.claude/projects/<slug-cwd>/<session_id>.jsonl`. Synthesize StreamTool previews from tool_use args (reuse `_preview` logic).
- **CodexAdapter** (`codex` 0.136.0): `codex exec "<prompt>" --json` (JSONL) + optional `-o <file>` final msg; sandbox `--sandbox workspace-write`. session_id = `session_meta.payload.id`; tool calls = `response_item function_call`/`function_call_output`, `exec_command_end.exit_code`→`ok`; assistant text = `agent_message`. Resume: `codex exec resume <id> "<prompt>" --json`. Backfill: `~/.codex/sessions/YYYY/MM/DD/rollout-*-<id>.jsonl`.
- **OpenCodeAdapter** (`opencode` 1.15.13): `opencode run "<msg>" --format json` (raw JSON events); resume `-s/--session <id>` / `-c`. Closest Hermes twin: has `opencode export <id> --sanitize` → `{info, messages[]}` with `parts[]` (type `tool` = authoritative tool list) → direct analog of `hermes sessions export`. Walk `parts[type==tool]` for ToolCallSummary.
- Common: none need the stderr-regex/boxed-stdout hacks Hermes uses; all emit session_id in structured stdout. `since_ts` filtering only needed for on-disk backfill (each line carries ISO ts).
- Backend wiring: `models.py` add `harness: str|None` (validated against available names) to TextRequest + audio form; thread through all 4 turn endpoints (text/audio × turn/stream) like `tts`. New `GET /api/harnesses` → `[{id,name,available}]` (like `/api/voices`).
- Workspace: create `harness_workspace_dir` on lifespan startup.
- Tests: per-adapter parse tests with canned CLI JSONL fixtures (don't launch real agents in CI); endpoint dispatch test (unknown harness → 400/422; default when omitted).
- Verify: backend tests green. Commit.

### P3 — iOS harness picker + per-turn param
- `HermesVoiceAPI`: add `listHarnesses()` (decode `/api/harnesses`); add `harness` param to `sendText`/`sendAudio`/`streamText`/`streamAudio` (include in JSON body / multipart like `tts`).
- `AppSettings`: `selectedHarness` persisted (default `hermes`).
- `ConversationViewModel`: pass `settings.selectedHarness` on every turn.
- `SettingsView`: a "Harness" picker section fed by `listHarnesses()` (Hermes / Claude Code / Codex / OpenCode), gated to available ones.
- Harness-aware UI strings: "{harness} is thinking…" / "dispatching to {harness}" (HeroPane / pipeline copy) instead of hardcoded "Hermes".
- Verify: iOS build SUCCEEDED. Commit.

## Notes / open risks
- Safety: workspace-write means a misheard voice command could edit files in the
  workspace. Sandbox confines blast radius to `~/.harness-voice/workspace`; no
  destructive/system ops. Revisit if we later point harnesses at real repos.
- `release.sh` still builds scheme `HermesVoice` (codename kept) — unaffected by
  rebrand except the new bundle id needs the ASC app record first.
- Hermes remains the default harness so existing behavior/tests are unchanged
  until the user explicitly switches in Settings.
