# Current State

> Updated at the end of every work session. Read this first.

## Server profiles — MERGED to main (2026-07-16); on-device acceptance pending

Two-laptop backend switching SHIPPED in code: `BackendProfile` persistence + one-time legacy migration; main-header picker; Settings server manager/editor (authenticated `/api/harnesses` save-gate — unauthenticated `/health` can't validate tokens); profile-scoped Watch (`(sessionId, profileId)` pair marker) + Siri (profileID-guarded session, harness routing) continuity; active-only APNs handoff with per-backend registration records (decision: `decisions.md [2026-07-15]`). Branch `server-profiles` (`d4b8035..ce3f5e1`, 9 commits) merged; 71 tests + build green on merged main. Executed via subagent-driven development off `docs/superpowers/plans/2026-07-10-server-profiles.md` with Lead-revised Task 2-4 briefs; GPT-5.6 Sol adversarial-reviewed plan AND branch (4 convergence rounds → MERGE); full trail: `.superpowers/sdd/progress.md` (git-ignored).

- [?] Task 5 — on-device acceptance (USER): add both laptops as profiles, verify routing isolation, gate during turns/hands-free/Watch relay, APNs re-registration on switch. **TestFlight build 29 uploaded 2026-07-16** (first build with server profiles; processing ~5-15 min). Note: this Mac's Xcode has no signed-in account — `release.sh` now passes the ASC API key at archive time too (headless provisioning). Secrets: repo onboarded to Bitwarden Secrets Manager 2026-07-16 (`bws-project` registry) — ASC identifiers + the 4 backend runtime secrets live in the BWS `hermes-voice` project; `.release-ios.env` DELETED (release via `bws-project run -- ./scripts/release.sh --build`). `backend/.env` still exists locally — the launchd service reads it directly; migrating the service to `bws-project run` is an open follow-up.
- Follow-ups DONE + merged (2026-07-16, same day): continuity hardening (attach teardown, harness-aware Siri/Watch route snapshots), Siri configured-detection, injection seams + 29 regression tests (101 iOS tests). Sol re-converged to MERGE after 2 fix rounds.
- Landmine: this machine has iPhone 17 simulators, not iPhone 16 (plan/docs referencing 16 are stale). Beads: `bd` backlog = dolt repo (~`backlog-hermes-voice`), NOT present on this machine — prose roadmap canonical here until wired.

## Spoken conversational filler — ack + contextual narration (2026-06-26)

User feedback, the real reason they don't use it: a turn is SILENT while the agent works → feels broken even when fast. Fix = spoken filler (see [[voice-perceived-latency-needs-spoken-filler]]). Designed via judged design workflow (`w8y7ffq3k`); built + adversarially reviewed (`wmedfcx0d` — both halves APPROVE, every risk-checklist item PASS). Tone = warm/casual/first-person; scope = full (user choices).
- **iOS (committed):** instant first-person ACK at dispatch (`FillerPhrases.ack()`, local, zero-latency, one/turn via `didAckThisTurn`) + non-blocking `LocalSpeaker.narrate()` with a 1-deep coalescing queue (reply `speak()`/`stop()` hard-cuts it) + speaks `.narrate` SSE events. **Fixed a real barge-in bug**: `stop()` now fires in the `.thinking`/`.sending` arms of `userPressedMic` + `cancelCurrentTurn` (was `.speaking`-only → Hermes talked over a mid-think interrupt). Leak guard: `ConversationModeController` stops narration before the hands-free loop re-arms `listen()`. 44 iOS tests (+4).
- **Backend (committed):** new pure `app/narration.py tool_narration(name, preview, args)` (warm phrases per tool family + weather-location arg enrichment + None for noise) → `StreamNarration` side-channel (kept OUT of `reply_parts` → can't corrupt the reply or the empty-reply guard) yielded from `_process_update`'s tool_call branch → `_stream_turn` emits additive `sse({"type":"narrate","text":...})`. Only the warm ACP path emits it; legacy/mock unaffected. 216 backend tests (+24). **Needs backend restart + a TestFlight build to reach the device.**
- Contract: `{"type":"narrate","text":...}` ↔ iOS `TurnEvent.narrate(String)`. Minor known: `FillerPhrases.ack()` static counter is main-actor-only by usage, not annotated.
- **Verbosity setting (DONE 2026-06-26, committed, iOS-only).** `AppSettings.fillerVerbosity` (off<quiet<normal<chatty, default normal) gates: ack (`!=off`), narrate events (`>=normal`), and a **chatty-only heartbeat** ("still working on it" via `LocalSpeaker.narrate()` after ~9s of filler-silence). `heartbeatTask` cancelled at all 11 turn-end paths + before the hands-free re-arm (adversarially traced, no leak). Settings → ON-DEVICE VOICE → "Spoken updates" picker (gated on `isLocalVoiceSelected`). 50 iOS tests (+6). Deferred: full-duplex talk-over-the-filler barge-in (large, separate — today barge-in is button/tap).

## Backlog burn (ultracode workflows, 2026-06-20)

Triage workflow (`wllyeadau`, 8 parallel readers) assessed every open backlog item vs live code; burn workflow (`wgeycmki7`, implement→verify→adversarial-review) landed the two autoburnable ones.
- **schedules concurrency + text-only fires (DONE, committed).** `backend/app/schedules.py`: `MAX_CONCURRENT_FIRES=3` semaphore caps concurrent `_fire_one`; fires pass `tts_mode="none"` (push re-synthesizes via `/api/replay`). +2 mutation-verified tests. 184 backend tests green.
- **iOS test expansion (DONE, committed).** `HermesVoiceTests` +3 files (pairedTurns, answer parsers, decoders + `parseEvent` SSE; bumped `parseEvent` `private`→`internal static`). 40 tests, `xcodebuild test` green.
- **Compact this session (DONE, committed — wave 2).** Spike resolved (`claude -p /compact --resume` preserves session_id, no fork). `ClaudeAdapter.compact_session` + `POST /api/harnesses/{id}/sessions/{sid}/compact` + iOS Compact button in SessionBrowserView. 192 backend tests (+6, subprocess mocked); iOS BUILD SUCCEEDED. **Needs backend restart + a TestFlight build before on-device use.**
- **Triage verdicts for the rest:** `compact-from-app` → **spike RESOLVED** (an agent live-probed `claude 2.1.185`: `-p /compact --resume` works AND preserves session_id, no fork) → wave-2 do-now. `backend-client-injection` → backlog premise wrong (18 sites/11 files, value struct, 3 config sources); Lead call = factory-on-config (`AppSettings.makeAPI()`); wave-2. `prelude-migration` → mostly superseded (Hermes `_meta` + Claude `--append-system-prompt` done); only Codex adapter first-turn prepend remains + needs CLI-override verification. `typed-tool-output` → defer (cross-repo: needs hermes-agent to emit structured `rawOutput`). `turn-pipeline` → defer (XL, needs Lead spec + DI seam; blocks deep VM tests). `launchd-plist-rebrand` → **user-run** (live `~/Library/LaunchAgents/`, agents never apply to live HOME).

## Latency optimization — voice fast profile + shared HTTP client (2026-06-20)

User: "responses super slow, focus on optimization." Systematic-debug of the live log traced all latency to the **agent loop**, NOT the hermes-voice transport: (1) agentic tool loop = 7–16 sequential model round-trips/turn (2–9s each); (2) one 60s `rg --files --sortr=modified` over `/Users/tfinklea` (ACP cwd = home dir) — already timeout-bounded, *shared* tool layer, left as-is; (3) post-turn self-improvement review (~45s, 2nd forked agent) tying up the warm child between turns.

- **Voice fast profile — CROSS-REPO (hermes-agent `acp_adapter/server.py`; UNCOMMITTED on its local `main`).** Gated on the `voice_system_prompt` `_meta` the backend sends every turn: voice/ACP turns set `reasoning_config={'effort':'low'}` + `_skill_nudge_interval=0` + `_memory_nudge_interval=0` (skips bg review). Defaults captured once + restored for non-voice ACP turns (Zed) → terminal Hermes keeps full effort + self-improvement. Decision: `decisions.md [2026-06-20]`. **Backend RESTARTED 2026-06-20** (child PID 52995, clean ACP init, no errors). **PENDING user device test** — confirm faster TTFB + NO `💾 Self-improvement review` after a heavy turn (discriminator in `/tmp/hermes-voice.log`).
- **Shared `httpx.AsyncClient` (hermes-voice, committed).** TTS/STT providers opened a fresh `httpx.AsyncClient` per call (new TLS handshake each synth/transcribe). New `app/_http.py acquire_client()` + optional `client` injected into all 6 providers (graceful per-call fallback for direct construction/tests); lifespan-managed client on `app.state.http_client`, closed on shutdown; threaded via `make_tts`/`make_stt`. Helps server-TTS (Watch/default) + cloud STT + connection churn; does NOT touch the on-device path (`tts=none`, on-device STT). **182 backend tests (+4), ruff clean on touched files.** Out-of-process schedules MCP (`mcp_schedules.py _client()`) left as-is (separate process, can't share `app.state`).

## Voice/TTS polish + rock-solid tails (DONE, 2026-06-15; on-device turn-test pending)

Four follow-ups after the AVSpeech swap + Phase 4 cutover. All committed; backend RESTARTED-LIVE.
- **TTS gender note (iOS, `9a978c1`):** Settings warns when the selected on-device voice's gender
  isn't installed (fires only on a confirmed opposite-gender fall-through). iOS build green.
- **Server-side ACP cancel (backend, `f5ab123`):** abandoned turns (barge-in/disconnect) send
  `conn.cancel` (`session/cancel`) so the warm child stops generating; `ask_streaming` wraps
  `_drive_turn` in `contextlib.aclosing` for prompt cleanup. ruff + 178 tests.
- **iOS parity test target (`eda7120`):** new `HermesVoiceTests` runs the shared
  `backend/tests/fixtures/speakable_cases.json` corpus through Swift `makeSpeakable` (referenced
  IN PLACE → can't drift from `test_speakable.py`). `xcodebuild test -scheme HermesVoice
  -destination 'platform=iOS Simulator,name=iPhone 16'` → TEST SUCCEEDED. project.yml + regenerated
  `.xcodeproj` + shared scheme committed.
- **Hermes voice-prelude every turn — CROSS-REPO (`5911c44` hermes-voice + `fda7e544e` hermes-agent):**
  the prelude now rides as ACP `_meta` on every prompt instead of prepended only on turn 1.
  hermes-voice `acp_client.py` sends `conn.prompt(..., voice_system_prompt=_VOICE_PRELUDE)`; the acp
  router flattens `_meta` into the agent's prompt kwargs; `~/.hermes/hermes-agent`
  `acp_adapter/server.py` sets `agent.ephemeral_system_prompt` per turn → shaped on resumes too,
  never written to the transcript. hermes-agent is an EDITABLE install (no rebuild). Decision:
  `decisions.md [2026-06-15]`. **Backend RESTARTED 2026-06-15:** `/health` ok, warm child respawned
  (PID 3646), clean ACP init, no errors. **⚠ hermes-agent commit `fda7e544e` is on their local
  `main`, NOT pushed** (only `acp_adapter/server.py` staged; pre-existing package.json/lock changes
  left untouched) — user may want to PR it per their monorepo workflow. **PENDING:** on-device turn
  test (confirm no regression + replies stay terse deep in a conversation).

## On-device TTS: Kokoro → Apple AVSpeech (DONE in code, 2026-06-15; build + device-test pending)

Live testing (build 23) surfaced 3 on-device TTS bugs — **all traced to FluidAudio's
on-device Kokoro, NOT the backend** (3-agent diagnosis, workflow `w33f0zdoe`): (1) voice
picker always spoke default female (only `af_heart.bin` ships in FluidAudio's English ANE
repo; `am_michael`/`bf_emma`/`bm_george` 404 → throw → `LocalSpeaker` silently fell back to
`af_heart`); (2) "is"→"eyes" (context-free per-word BART G2P, no lexicon hook); (3) numbers
dropped/"x" (FluidAudio's number normalizer is SSML-only, never wired into the Kokoro path).
Backend ruled out: `make_speakable` only strips markdown + on-device path sends `tts=none`.

**Fix (user chose "swap to Apple AVSpeech"):** rewrote `LocalSpeaker` from FluidAudio/Kokoro
to Apple `AVSpeechSynthesizer` — Apple's normalizer handles numbers/dates/homographs, always
on-device, offline, real selectable voices. Same public API; `makeSpeakable` kept; logical
voice ids (`en-US`/`en-GB` × male/female) with legacy `local:af_heart` migration; gender-
preference resolver (exact → `.unspecified` → other + breadcrumb). FluidAudio stays for
STT/VAD. **iOS BUILD SUCCEEDED**; adversarially reviewed (barge-in continuation race handled
via utterance-identity guard; silent gender-downgrade caught + fixed). Files: `LocalSpeaker.swift`
(rewrite), `SettingsView.swift` (removed Kokoro download UI → always-ready row), `AppSettings.swift`
+ `ConversationModeController.swift` + `ConversationViewModel.swift` (Kokoro→Apple wording).
Decision: `decisions.md [2026-06-15]`. **PENDING (user):** cut a TestFlight build + device-test
(confirm voice selection is honored, numbers/homographs spoken correctly). Follow-up: surface in
Settings when a requested gender isn't installed on the device (logs a breadcrumb only today).

## Hermes rock-solid — ACP warm-server migration (COMPLETE, 2026-06-15)

**Initiative:** make Hermes trustworthy end-to-end (user directive). Root cause
found + spike-verified: hermes-voice cold-starts the whole agent per turn
(`hermes chat`), and Hermes's only MCP server (`hermes-voice` schedules) points
back at THIS backend → blocking MCP discovery stalls 60-120s when the backend is
busy/restarting = the 2m56s "pong". Fix: drive ONE warm `hermes acp` server.
Spec: `.docs/ai/phases/hermes-acp-warm-server-spec.md`. **Hermes-only** (other
harnesses deferred by user). Recon workflow `wiphdg9to`; review workflow `wjv07uts3`.

- **Phase 0 — DONE:** `~/.hermes/config.yaml` `hermes-voice` MCP `connect_timeout: 5`
  (was unbounded). **User action pending:** kill stale 19-day `hermes` session
  PID 8503 (leaks an mcp_schedules child) — `kill 8503`.
- **Phase 1 — DONE (committed):** `backend/app/acp_client.py` warm-ACP client behind
  `HERMES_USE_ACP` (default OFF); lifespan-managed child; SYNC-observer event
  collection (race-free — the review caught + we fixed a dispatch race the sentinel
  approach had; see spec); per-turn/start timeouts, stderr-inherit, per-session lock,
  child-alive in /health. Live: 20 turns, 0 drops, ~2.3s warm. 176 backend tests green.
  `agent-client-protocol==0.9.0` added to backend deps. **Not device-tested through the
  app; flag still OFF in prod — turn it on (HERMES_USE_ACP=1 in backend/.env + restart)
  to try it.**
- **Phase 2 — DONE (correctness; shaping deferred by user):** session continuity
  across warm-child restart + History/replay both ALREADY work for ACP UUIDs
  (verified live: `get_session`→`_restore` rehydrates; `hermes sessions export
  <uuid>` returns ACP sessions). Voice-prelude-as-system_prompt SKIPPED (turn-1
  prelude shapes adequately; the hook if revisited is `AIAgent(ephemeral_system_prompt=…)`,
  appended every turn by `conversation_loop.py`).
- **Phase 3a — DONE (committed):** timeout unified (`HERMES_TIMEOUT_SECONDS` default
  180→300, ≥ iOS client); warm-child crash-respawn (`_ensure_healthy` respawns a
  dead child before a turn; sessions rehydrate from state.db) — live-verified by
  SIGKILL-ing the child mid-session and confirming the next turn self-heals.
- **Phase 3b — DONE in code (committed; iOS BUILD SUCCEEDED; device-test pending):**
  `ConversationViewModel.swift` — stream→single-shot fallback narrowed to 404/405
  only (+ log; missing endpoint = turn never ran, so retry is safe; other statuses
  fail loud, no silent re-fire of a maybe-run write); a server `error` after the
  reply no longer errors the turn (`.failed` checks `sawAssistant`; audio path got
  the text path's post-reply guard); history-recovery anchors on position
  (`currentTurnHasAssistantReply`) not global text (fixes the Saved./Done. dedup).
  **Not in a TestFlight build yet.**
- **DEPLOYED FOR VALIDATION (2026-06-13):** `HERMES_USE_ACP=1` set in `backend/.env`
  + backend restarted → warm path is **LIVE in prod** (confirmed: `hermes acp` child
  up, log shows clean `ACP client connected`/`Initialize protocol v1`/`startup
  complete`, no fallback). **TestFlight build 23** cut with the Phase 3b iOS fixes
  (processing). Subprocess fallback is one env-var away (remove the `.env` line +
  restart). **Awaiting on-device test of build 23:** feel the ~1-2s warm turns,
  multi-turn continuity, recovery.
- **Phase 4 — DONE (2026-06-15):** `HERMES_USE_ACP` now defaults ON in `config.py`
  (both the field default and the `_bool` env default); subprocess `HermesClient`
  KEPT as the documented fallback (`HERMES_USE_ACP=0` + backend restart reverts).
  176 backend tests green. The running backend already used ACP via the `.env`
  override, so no behavior change / restart was needed — the `backend/.env`
  `HERMES_USE_ACP=1` line is now redundant (harmless; remove it whenever).
  **On-device validated 2026-06-15 (warm child PID 66662 stable ~2 days; turns
  fast + reliable). INITIATIVE COMPLETE.**

## Active Branch

**Remote: PUBLISHED to GitHub 2026-06-05 — `github.com/TaylorFinklea/hermes-voice` (public, MIT). `origin` set, `main` tracks `origin/main`.** Repo was local-only for 89 commits before this (single-machine risk). Secret audit pre-push was clean (no `.env`/`.p8`/keys ever committed; only `.env.example` + a non-secret ElevenLabs voice-id are tracked). **User wants changes PUSHED going forward** (backup priority) — push after committing on this repo. Low-risk public exposure (NOT credentials, optional scrub): ASC key-id/issuer-id in `scripts/release.sh`, tailnet host `scadrial.tailceb58.ts.net` + `/Users/tfinklea` paths in docs.

`main` — **committed + pushed; speakable-output fix in TestFlight build 22 — `7919b8a` backend + `f9fc0fe` iOS/docs (backend 156/156 green + iOS BUILD SUCCEEDED, adversarially reviewed).** Recent before: `6707697` security (/health gate + fail-closed bind), `d93a301` iOS list-card double-render + Watch stale-settings, `4789ec4` TTS/AudioStore leak fixes, `e21a90d` large-session attach warning, `a061863` timeout 180→300s, `0a6c3f1` thinking bar→elapsed.

**Speakable Claude output — DONE + SHIPPED (committed `7919b8a`+`f9fc0fe`, 2026-06-05; backend RESTARTED-LIVE, iOS in TestFlight build 22 — processing).** Bug (user, on-device): an *attached/resumed* Claude session dumped full raw markdown — TTS read `##`/asterisks/code-fences/ASCII-diagrams aloud AND the transcript showed them raw. Root cause: the Claude `_VOICE_PRELUDE` was prepended only on the FIRST turn (`if not session_id`) and as USER text, so resumed/attached turns got zero shaping. User decisions: **terse voice / render markdown on screen / full scope**. Design via 2 workflows (design panel `wox697hg1`, review `wnn8gu2kq`). Verified facts: claude-agent-sdk 0.2.87 `system_prompt={type:preset,preset:claude_code,append:...}` → `--append-system-prompt`, per-invocation (NOT in session .jsonl), applied on resume; None→`--system-prompt ""` wipes default (footgun, avoided). Changes:
- Backend: new `app/speakable.py make_speakable()` (markdown→speech, unclosed-fence-safe, idempotent) wired at ALL 4 spoken-text sites — the 3 live `_start_stream` calls (`main.py` _run_turn/_stream_turn, `claude_sdk_turn.py`) AND `/api/replay` (replay re-synthesizes stored text for history-tap + scheduled-push auto-play; sanitizer covers both live turns and replay, idempotent so safe). Voice instruction moved off first-turn user text onto a per-invocation SYSTEM prompt on EVERY Claude turn incl. resume: SDK preset+append dict (`claude_sdk_turn.py`), CLI `--append-system-prompt` (`adapters/claude.py`, `_VOICE_PRELUDE`→`_VOICE_SYSTEM_PROMPT`). +`tests/test_speakable.py`(38, shared fixture incl. CRLF table case) + base_args resume-flag test. So `claude --resume <id>` in a terminal stays normal markdown.
- iOS: `LocalSpeaker.makeSpeakable` mirror for the on-device tts=none path (NO iOS test target → Python↔Swift parity is MANUAL only); new `DesignSystem/MarkdownText.swift` dep-free renderer (headings/lists/code/quotes + AttributedString inline) wired into HeroSpeaks/HeroJustArrived/TranscriptRow/MessageRow (display shows rich markdown, ear hears clean prose); `MainView.heroScroll` ScrollViewReader + bottom anchor + `onChange(messages.count)` auto-scrolls the live tool-call feed (was a bare VStack marching off-screen).
- **Shipped 2026-06-05:** (1) backend RESTARTED — note the live launchd service is still labeled `dev.finklea.hermesvoice.backend` (PID reloaded to 93502; the rebranded `dev.finklea.harnessvoice.*` plists were NEVER reinstalled, but the service runs the same repo code, so kickstart loaded the new code); `/health` green, mock=false. (2) `release.sh --build` cut **TestFlight build 22** (`91c9f22`, ARCHIVE+EXPORT SUCCEEDED) — also carries answer-by-voice (`e4bcb67`) + the bug/security-sweep iOS fixes that weren't in build 20. **Pending:** on-device test build 22 on a SMALL attached Claude session — confirm spoken output is terse/clean, the transcript renders formatted markdown, and the tool-call feed auto-scrolls. **Deferred follow-ups:** migrate Hermes/Codex preludes to system-prompt too (sanitizer already protects their *spoken* output, but their resumed turns still get no instruction); add an iOS test target to machine-verify Swift↔Python sanitizer parity against the shared fixture corpus; reinstall the rebranded launchd plists (`dev.finklea.harnessvoice.*`).

**Bug + security sweep — DONE (2026-06-04), backend LIVE, iOS NOT in a build yet.** Knocked out the open confirmed bugs + both security decisions (user picked: public-status/authed-details for /health; fail-closed at startup for the bind). Backend (`4789ec4` TTS producer timeout + AudioStore TTL/close; `6707697` /health gating + assert_safe_bind) is restart-live. iOS (`d93a301` ActionCard.residual double-render fix + bullets 0.6→0.7; PhoneWatchBridge shared AppSettings) **needs a build to reach the device.** 117 backend tests green. See roadmap Backlog "Other confirmed"/"Security hardening" (all checked).

**Answer-by-voice — DONE (`e4bcb67`), iOS NOT in a build yet.** Closes the Phase B "REMAINING" below. When an approval/question card appears the VM speaks the prompt then auto-arms a dedicated `ConversationCaptureEngine` (separate from the mic button, which stays barge-in/cancel) → `LocalTranscriber.transcribe(samples:)` → parse yes/no (approvals) or option label/ordinal (questions; multi keeps all named) → auto-submit via `answerTurn`. Tap still works; first to land wins. Gated on on-device voice + VAD ready (else tap-only). Cards show a "Listening — say yes/no" row (`conversation.listeningForAnswer`). Parsers `parseYesNo`/`parseSelection` are `static` on the VM (untestable until an iOS test target exists — backlog).

**TestFlight: build 20 uploaded (2026-06-04)** — 14=P0–P3; 15=+Phase A; 16=+agent-aware UI/token-fix/accent; 17=+Phase B (approval loop) + <AGENT> VOICE title; 18=thinking-bar→elapsed-time; 19=large-session attach warning + /compact remedy; **20=bug+security sweep iOS (double-render + Watch settings)**. **NOT in a build yet:** answer-by-voice (`e4bcb67`). Backend all LIVE (Phase B broker, ClaudeProbe filter, 300s timeout, `size_bytes`, /health gating, fail-closed bind). **Awaiting on-device test of Phase B (build 17+) on a SMALL session** (a huge session times out on resume — that's the warning the large-session feature adds).

**Build 19 — large-session resume warning (DONE).** Resuming a long Claude session replays its whole transcript (slow first reply; mitigated 180→300s in `a061863`). No native partial-load (`--resume`/`--fork-session` load the full transcript). So: backend adds `size_bytes` (raw `st_size`, one stat in `session_meta_from_file`) to `HarnessSession`/`SessionListItem`, threaded through `/api/harnesses/{id}/sessions` (`e21a90d`); iOS `HarnessSession.isHeavy` (>2 MB or >500 msgs) shows a `⚠ Large · ~Nk msgs · slow to resume` chip in `SessionBrowserView`, and tapping a heavy session confirms via an alert whose body carries the `/compact` remedy (keeps the same session id, unlike a fork). 10 claude-session tests + 100 backend total. **Deferred follow-up** (roadmap Backlog): run `/compact` *from the app* — needs a spike on whether slash commands work headlessly in `-p` mode; fork-from-summary is the lossy fallback.

**UI polish batch (in build 16):** state chips + title reflect the ACTIVE agent (`AppSettings.activeAgentLabel`/`activeAgentTitle`; `StatusChip` reads it via env, no call-site changes); token field placeholder + 401 errors fixed ("auth token required"); finished the uppercase HERMES→HARNESS rebrand misses; subtle per-agent header accent (`AppSettings.agentAccent`: Hermes amber, Claude coral 0xE8825A, Codex mono 0xE6E6E6, OpenCode violet 0x9B8CFF; applied to title + root .tint only). Accent can extend to the mic button / full theme / a user-selectable picker later.

**Phase B — voice-mediated write approval — DONE (all 4 slices), backend LIVE, NOT in a build yet.** Plan: `~/.claude/plans/mighty-dazzling-biscuit.md` §Phase B. Title fix `d8f2b6a` (<AGENT> VOICE) also not in a build.
- **Slice 1 (`d93894e`):** `ApprovalBroker` (`backend/app/approvals.py`) — per-turn pending-`Future` registry + emit queue; `request()`/`answer()`/`emit()`/`events()`/`close()`. `POST /api/turns/{turn_id}/answer` (TurnAnswer). `app.state.approvals`. 4 tests.
- **Slices 2-3 (`96e893a`):** added `claude-agent-sdk>=0.2.87`. `backend/app/claude_sdk_turn.py` (`stream_claude_approval_turn`): runs the SDK turn in a task that `emit()`s assistant/tool/done onto the broker queue; `can_use_tool` pauses writes/commands for a voice yes/no via `broker.request`; an in-process `ask_user` MCP tool (`mcp__voice__ask_user`) for select/multi-select; resumes in the session's real repo cwd; `permission_mode="default"` (reads auto, writes prompt); `setting_sources=["project"]`. New per-turn `mode` field; `_stream_turn` routes `mode=="write"` + Claude → SDK path. 98 tests + verified SDK option/tool construction.
- **Slice 4 iOS (`1efeee5`):** parse `turn`/`approval_request`/`question` SSE events; `answerTurn()` POST; `mode` threaded through stream methods; VM `pendingApproval`/`pendingQuestion` + answer methods + speaks the prompt; `ApprovalCards.swift` (Approve/Deny + single/multi-select), bottom overlay in MainView; SessionBrowserView **Write-mode toggle** (attach read-only by default → write w/ approval). iOS build green.
- **REMAINING:** ~~answering BY VOICE~~ DONE (`e4bcb67`, see top) — auto-listen separate from the barge-in mic, gated on on-device voice + VAD. Just needs a build to test on-device.

**To test Phase B:** build 17 (pending user authorization) → attach a Claude session with **Write mode** ON → ask it to make a change → an approval card appears (spoken) → Approve/Deny → verify the edit in the repo + that `claude --resume <id>` sees it.

Accent theming can also extend later (mic button / full theme / user-selectable picker).

## Flagship: Claude Code voice-attach — Phase A DONE, Phase B next

Plan: `~/.claude/plans/mighty-dazzling-biscuit.md`. Decision (2026-06-02): general architecture, **depth-first on Claude Code**, Hermes stays default. Keystone = drive an EXISTING coding session by voice; safety = voice-mediated approval (Phase B).

- **Phase A — attach + drive (DONE).** Backend (`22f5aec`): `list_sessions()` (optional, via getattr) + `GET /api/harnesses/{id}/sessions`; Claude adapter scans `~/.claude/projects/*/*.jsonl` (pure fns, fixture-tested + validated on real data), resumes in each session's ORIGINAL cwd (sessions are cwd-scoped), and runs **read-only** when the cwd is a real repo outside the shared workspace (`--permission-mode plan --allowedTools "Read,Bash(git *)"`). iOS (`b629d61`): `SessionBrowserView` + `ConversationViewModel.attach(...)` + a "Attach to a session" link under the AGENT picker (coding harnesses only). 94 backend tests; iOS build green.
  - **To live-test Phase A:** restart backend to load it, `GET /api/harnesses/claude/sessions` (401 w/o token = exists), then build 15 for the on-device attach UI.
- **Phase B — voice-mediated approval + structured questions (NEXT, large).** Verified mechanism: **Claude Agent SDK** (`claude-agent-sdk` pkg) `ClaudeSDKClient` + async `can_use_tool` + `permission_mode="plan"` → surface "Claude wants to <edit/run>" as an approval card confirmed by voice; custom `AskUser` MCP tool for voice-answerable select/multi-select. Needs a bidirectional channel (new `approval_request`/`question` SSE events + `turn_id`-keyed `POST …/answer` + asyncio futures) and iOS approval/question cards wired to on-device STT yes/no/option-matching. Bigger than Phase A; isolate it.

## Harness Voice initiative (rebrand + multi-harness) — IMPLEMENTED (P0–P3), in build 14

Spec: `.docs/ai/phases/harness-voice-multiharness-spec.md`. User decisions (2026-06-02): **full identity rebrand**, **shared workspace** `~/.harness-voice/workspace`, **workspace-write sandbox**, **per-turn `harness` param**, implement end-to-end. All four phases built + committed; iOS build green, backend 86/86.

**REMAINING:**
- **Live end-to-end test** of Claude/Codex/OpenCode through the app on a device (adapters verified against real CLI output at the unit level + a live Codex resume, but not yet driven through the running backend + app). To test locally now: restart the backend (`launchctl kickstart -k …harnessvoice.backend` AFTER reinstalling the renamed plist) then `GET /api/harnesses`.
- **⚠️ Before next TestFlight upload:** new bundle id `dev.finklea.harnessvoice` = NEW App Store Connect app — create the app record + APNs key first, else `release.sh` upload fails. Then cut build 14.
- **Backend redeploy** for the rebrand: reinstall the renamed launchd plists (`dev.finklea.harnessvoice.*`), re-register the MCP server as `harness-voice` if you use schedules. (Data dir `~/.hermes-voice` + `HERMES_VOICE_*` env intentionally unchanged.)
- Doc-prose rebrand (README architecture section, schedules-setup MCP name) + app-icon redesign — both deferred polish.

- **P0 Rebrand — DONE (`aca730d`).** Bundle id `dev.finklea.hermesvoice`→`dev.finklea.harnessvoice` (app/watch/widget, xcodegen-regenerated), display name Hermes→Harness, Bonjour `_harness-voice._tcp`, MCP `harness-voice-schedules`, package `harness-voice-backend`, launchd plists renamed, Live Activity URL scheme, release.sh, iOS UI/Siri copy. **KEPT (back-compat):** `HERMES_VOICE_*` env, `~/.hermes-voice` data dir, `X-Hermes-Voice-Token` header, repo dir path, Hermes-harness code identifiers (`HermesClient`/`hermes.py`/`hermes_bin`/`HERMES_*`), Xcode target/scheme/type codenames (so `release.sh -scheme HermesVoice` still works). Verified: iOS BUILD SUCCEEDED w/ new bundle id; backend 56/56. **App icon still winged-H (Hermes) — design follow-up.**
  - **⚠️ ACTION REQUIRED before next TestFlight upload:** new bundle id = NEW App Store Connect app — create the app record + APNs key for `dev.finklea.harnessvoice` first, else `release.sh` upload fails.
- **P1 Backend HarnessClient protocol + dispatch — DONE (`0315a52`).** `HarnessClient` Protocol (`backend/app/harness.py`); `app.state.harnesses` registry + `_resolve_harness` (422 on unknown); per-turn `harness` field threaded through all 4 turn endpoints (stream endpoints validate BEFORE streaming); `GET /api/harnesses`; config `default_harness`/`harness_workspace_dir`/`harness_sandbox`. Kept `HermesClient` class name. 62 tests.
- **P2 Claude/Codex/OpenCode adapters — DONE (`4f45971`).** `backend/app/adapters/{claude,codex,opencode}.py`, each satisfying the protocol, running in the shared workspace under a workspace-write non-interactive sandbox; parse split into pure functions (24 fixture tests vs REAL captured CLI output). Registered by availability in `create_app` (production only — tests inject FakeHermes and stay isolated). Codex 0.136.0 uses the NEW `thread.started`/`item.*` event schema. Claude `--permission-mode acceptEdits`; Codex `-c approval_policy=never -c sandbox_mode=workspace-write`; OpenCode `OPENCODE_CONFIG_CONTENT` perms + `--dir`. Smoke: registers `[claude,codex,hermes,opencode]`, default hermes. 86 tests.
- **P3 iOS harness picker + per-turn param — DONE (`8636c58`).** `AppSettings.selectedHarness` (default hermes); `HermesVoiceAPI.listHarnesses()` + `harness` threaded through sendText/sendAudio/streamText/streamAudio; ConversationViewModel passes it on every turn (incl. hands-free + Watch via PhoneWatchBridge); SettingsView "AGENT" picker fed by `/api/harnesses` w/ fallback reset. iOS BUILD SUCCEEDED.

## Prior Session Summary

**Date**: 2026-06-02

- **Reviewed GPT-5.5's `dbfafee` "Fix live turn visibility" + committed 3 hardening fixes (`91d9997`, ConversationViewModel.swift). iOS build SUCCEEDED; backend untouched. NOT yet in a TestFlight build.**
  - **Silent-failure:** `recoverMissingAssistantFromHistory` now returns true only when it appends a NEW reply; a dedup hit (coincidental duplicate from an earlier turn) returns false so the real error surfaces. The streamText catch first checks new `currentTurnHasAssistantReply()` so a late stream drop *after* the reply already streamed in resolves to idle (not an error).
  - **Cancellation:** recovery now bails on `Task.isCancelled` before AND after the `getSession` await — a barge-in/cancel can't append or speak a dismissed reply.
  - **Stale anchor:** `turnUserText` now updates from the live `.transcribed` event on the audio-upload path (user msg appended mid-stream) instead of the prior turn's `lastUserText`.
  - **IMPORTANT correction — a review false-positive debunked:** the worry that "session_id is never captured for new streaming conversations → new convos error / multi-turn broken / recovery useless" is **WRONG**. `_RESUME_LINE` (`--resume\s+(\S+)`, session_audit.py:29) matches Hermes's own stdout footer ("Resume this session with: hermes --resume <id>"), which prints on every non-quiet turn (`ask_streaming` runs `chat -q`, no `-Q`), so `captured` IS populated for new conversations. Confirmed by the direct `hermes chat -q` test output + the fact that streamed turns have produced replies all along. Multi-turn continuity works.
  - **Deferred (low sev, not fixed):** `HeroPane.BounceLabel` uses `TimelineView(.animation)` → 60–120fps redraws for the whole multi-minute thinking window; a `.periodic(by: 0.1)` schedule would cut redraws ~6–12× (battery, not correctness). Elapsed timer resets when the thinking pane is recreated post-barge-in (mostly expected).

- **TestFlight build 13 uploaded (2026-06-01).**
  - Ran XcodeBuildMCP `build_sim` (`HermesVoice`, Debug, iOS Simulator, `CODE_SIGNING_ALLOWED=NO`) → **SUCCEEDED**.
  - Ran `./scripts/release.sh --build`: bumped `CURRENT_PROJECT_VERSION` **12 → 13**, regenerated project, archived Release/generic iOS, exported/uploaded through App Store Connect → **EXPORT SUCCEEDED**.
  - Release script committed `f6da31b` (`Release 1.0 (build 13) to TestFlight`). App Store Connect processing expected 5-15 min.
- **Live-turn visibility fixes from on-device screenshots (2026-06-01) — BUILT (iOS simulator build succeeded).**
  - **Thinking affordance now visibly animates:** `HeroPane.BounceLabel` uses `TimelineView(.animation)` with pulsing dots, an elapsed `m:ss` counter, and a moving progress strip, replacing the too-subtle static-feeling opacity dots under "Composing reply…".
  - **Recovered "History-only" replies:** `ConversationViewModel.consumeTurn` now tracks whether a stream actually delivered an assistant event, stores `done.session_id`, and if the stream ends without assistant text it fetches the just-finished session from `/api/sessions/{id}` and appends the matching latest assistant reply. The same recovery runs on text-stream transport errors when a resume session id is available. This covers the observed bug where Hermes saved replies visible in History but the live pane returned to idle without showing them.
  - **Verify:** XcodeBuildMCP `build_sim` (`HermesVoice`, Debug, iOS Simulator, `CODE_SIGNING_ALLOWED=NO`) → **SUCCEEDED**; only pre-existing warnings (NotificationManager actor conformance, AVAudio warnings, AppSettings Swift 6 warning).
- **On-device feedback round (build 12) + a major backend gotcha caught.**
  - **Turns were "not processing" — ROOT CAUSE: the backend was running STALE code** (launchd service up since ~Thu 11 AM, before this session's Phase 2 streaming / voice picker / tts=none). Log `/tmp/hermes-voice.log` showed `POST /api/text/stream → 404`, `/api/audio/stream → 405`, `/api/voices → 404`, so the app silently fell back to single-shot `/api/text` (no live tool-calls, 60s client timeout). `/health` + `/api/sessions` kept working, masking it. **FIXED: `launchctl kickstart -k "gui/$(id -u)/dev.finklea.hermesvoice.backend"`** → verified `/api/text/stream` + `/api/voices` now 401 (exist). **Lesson saved to memory ([[backend-restart-required-for-backend-changes]]): release.sh only builds iOS; restart the backend after any `backend/app/**` change.**
  - **Second, separate cause: Hermes itself is slow.** Direct test on the Mac: `hermes chat -q "...pong"` → replied "pong" in **2m 56s** (mostly "Initializing agent…"), right under the 180s `hermes_timeout`. Agent-side (LLM provider degraded today, or slow MCP/agent init — noticed 3 leftover `mcp_schedules.py` procs). With the backend restarted, turns now use the 300s streaming path + show live progress, but any turn >180s still gets cut by the backend cap. **Open: make Hermes fast (investigate the ~3-min init) and/or raise `HERMES_TIMEOUT_SECONDS`.**
  - **Minor log issues (pre-existing, unrelated to turns):** APNs push key fails to load (`Unable to load PEM file … MalformedFraming`); schedules executor `unable to open database file`.
  - **UI changes shipped (commit `79b55b5`, iOS BUILD SUCCEEDED, build 12):** (1) hands-free entry moved from the top-bar bubble to a **dock mode toggle (∞) next to the mic** — toggle one-shot ⇄ hands-free there; removed `PlaybackTransport`/`ConversationModeDock`, rewrote `BottomDock` into left/center/right controls + `ModeToggleButton`/`ConversationCenterButton`; `isCancellable` now includes `.speaking`. (2) **Real push-to-talk waveform** via the recorder meter (`VoiceRecorder.currentLevel()` → `currentInputLevel` → shared `RealWaveform`), replacing the faked one. (3) `HeroError` shows "HERMES SLOW / didn't reply in time" for timeouts instead of "Backend unreachable."
- **Hands-free conversation mode (sub-project 2) — BUILT (iOS BUILD SUCCEEDED, 0 errors), shipped in build 11; device-test pending.** The "Jarvis" loop: listen → VAD endpoint → on-device parakeet → Hermes → on-device Kokoro → auto re-listen, no mic press between turns. Half-duplex (mic off while speaking → no echo cancellation). Brainstormed + grounded by the `conversation-mode-recon` workflow; spec `.docs/ai/phases/conversation-mode-spec.md`. **New files:** `Services/LocalVad.swift` (Silero VAD model lifecycle, mirrors LocalTranscriber/Speaker; separate small download), `Services/ConversationCaptureEngine.swift` (continuous `AVAudioEngine` tap mirroring tesela's StreamingVoiceRecorder + VAD streaming endpointing via `VadManager.processStreamingChunk`; emits endpointed `[Float]` utterances + **real** mic level; `.noDataNow` converter-reuse gotcha; routes session through `AudioSessionCoordinator`; single-utterance `listen()`), `ViewModels/ConversationModeController.swift` (the loop, composing turn primitives — does NOT extend the turn State enum). **Touched:** `LocalTranscriber` (+`transcribe(samples:)` overload — the VAD loop has samples, not a file), `MainView` (top-bar `bubble.left.and.bubble.right` toggle, mode-gated `heroScroll`, `ConversationModeDock` with barge-in + End, scenePhase-exit, error `.alert`), `HeroPane` (`HeroListeningHandsFree` + real-level `LiveWaveform` replacing the faked one), `SettingsView` (HANDS-FREE LISTENING VAD download row), `HermesVoiceApp` (controller wiring + VAD warm-up). **Decisions:** top-bar toggle entry; 1.0s endpoint silence; single-turn hero re-arming (not chat); interrupt = mic-tap/End (vocal barge-in deferred); auto-exit after 3 empty cycles + 15-min cap. **Simplifications vs spec:** reused `vm.sendText` (no new submit method); errors via published `errorMessage`+alert (no `.error` phase). Backend untouched (reuses `tts=none`). **Open follow-ups:** endpointing 1.0s likely needs on-device tuning; battery/thermal of a continuous tap + 3 warm ANE models wants a device thermal pass; gapless-ness of `AVAudioPlayer`-per-sentence (TTS) under rapid turns.
- **On-device TTS (Kokoro via FluidAudio) — SHIPPED in TestFlight build 10 (`529d6ab`), device-test pending.** Brainstormed after on-device STT landed instant; user wants the conversational "Jarvis" endgame (TTS + later hands-free VAD turn-taking), and to keep the architecture open to fronting **Claude Code / other harnesses**. Decomposed: **sub-project 1 = on-device TTS (this)**, sub-project 2 = hands-free conversation mode (next; FluidAudio already ships `VadManager`/`StreamingEouAsrManager`). Spec: `.docs/ai/phases/on-device-tts-spec.md`. Design: TTS runs **on the phone** (Kokoro/Neural Engine, in the FluidAudio pkg build 9 already has — no new dep), **sentence-chunked** playback (first words in ~0.3s). New `Services/LocalSpeaker.swift` (mirror `LocalTranscriber`: model download/cache + warm `KokoroAneManager` + `speak()` synth→play pipeline + `stop()`). Voice picker reuses one setting with a **`local:` sentinel** (`local:af_heart`); on-device voices appear once the Kokoro model is downloaded (Settings → ON-DEVICE VOICE). The strategic hook: when a local voice is selected the turn sends **`tts=none`** → backend skips synthesis / emits no `audio` event (the "text brain" decoupling that enables the multi-harness future); the phone speaks the reply on `.assistant`. Barge-in/cancel call `LocalSpeaker.stop()`. **Backend:** `TextRequest.tts` + `tts` form field threaded through `_run_turn`/`_stream_turn` + endpoints (`backend/app/{models,main}.py`); 3 new `test_stream.py` tests. Default unchanged (ElevenLabs/server) — opt in by picking a Kokoro voice. Watch stays server-TTS (no regression). **NOTE pre-existing flake:** 2 `test_mdns.py` tests fail in a *full* `pytest` run (ordering/event-loop) but pass in isolation and fail at HEAD too — not ours.
- **On-device STT — Phase A (parakeet-v2 via FluidAudio), SHIPPED in TestFlight build 9 (`a88fa59`), device-test pending.** Chosen direction (after recon): on-**iPhone** transcription mirroring the user's tesela setup (`FluidInference/FluidAudio`, CoreML), NOT Mac/MLX. Spec: `.docs/ai/phases/on-device-stt-spec.md`. New `Services/LocalTranscriber.swift` (@MainActor singleton; download/cache the ~450 MB model once, warm `AsrManager`, transcribe 16 kHz mono floats — mirrors tesela's `LocalTranscriptionEngine`). `project.yml` adds the FluidAudio package **pinned to tesela's exact revision** `50aa071…` (not branch main) on the app target only. **On-device transcription turns an audio turn into a text turn:** `ConversationViewModel.stopRecordingAndSend()` now transcribes locally (when `useOnDeviceSTT` + model ready) → appends user text → runs the existing `streamText`/`consumeTurn` path (factored into `streamTextTurnBody`, shared with `sendText`); audio-upload (`streamAudio`) is the automatic fallback (disabled / model not ready / transcription throws). `AppSettings.useOnDeviceSTT` (default ON, no-op until model downloaded). Settings → ON-DEVICE TRANSCRIPTION section (download/remove + toggle). `HeroSending` pipeline shows "transcribing on device" for the local path. Warm-up at launch via `MainView.task`. **Groq STT option dropped** (local beats cloud on speed + privacy; Groq stays only as a cloud fallback). Latency context: a parallel investigation found the old "feels frozen" is mostly a fake 500ms-timer spinner + serialized cloud STT — on-device kills the STT round-trip; the live-progress bundle (task #49) + stream-thinking (#50) are the queued follow-ups.
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
- **Re-verified after hands-free conversation mode (2026-05-30)**: iOS **BUILD SUCCEEDED, 0 errors** (LocalVad + ConversationCaptureEngine + ConversationModeController + UI). Backend untouched (still 54 pass + 2 pre-existing mdns ordering flakes). NOT device-tested — needs a device to download the VAD model, enter conversation mode, and exercise the listen→reply→re-listen loop + barge-in + auto-exit.
- **Re-verified after on-device TTS (Kokoro) (2026-05-29)**: iOS **BUILD SUCCEEDED** (Kokoro API + sentence-chunked LocalSpeaker + tts=none wiring). Backend: `tts=none` added, `pytest` **54 passed** + the 2 pre-existing `test_mdns` ordering failures (fail at HEAD too; pass in isolation) — 3 new `test_stream.py` tts=none tests green. NOT on-device-tested — needs a device to download the Kokoro model, pick an on-device voice, and confirm spoken-on-device replies + `tts=none` (no audio event) + barge-in.
- **Re-verified after on-device STT Phase A (2026-05-29)**: iOS **BUILD SUCCEEDED** with the FluidAudio SPM package resolved (first resolve fetches from GitHub; pinned revision = reproducible). Backend untouched (53/53 holds). Shipped in TestFlight build 9 (`a88fa59`). NOT on-device-tested — needs a real device to: download the ~450 MB model in Settings, confirm a mic turn hits `/api/text/stream` (not `/api/audio/stream`) i.e. transcribes locally, verify barge-in/cancel during local transcription, and confirm the upload fallback when the model is absent/disabled. Not yet in a TestFlight build.
- **Re-verified + released after live-turn visibility fix (2026-06-01)**: XcodeBuildMCP `build_sim` → **SUCCEEDED**; `scripts/release.sh --build` archived Release/generic iOS and uploaded **Hermes Voice 1.0 build 13** to TestFlight. No backend changes.

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

**In flight (2026-05-29): on-device STT.** Phase A (on-iPhone parakeet via FluidAudio) is built + green, NOT yet cut to a build or device-tested. Next steps:
1. **Cut a build with Phase A** (when authorized) so the user can download the model + test on-device. Then queued: **Phase B = live-progress bundle** (task #49 — split transcribing/dispatching on the real STT-done event, instant transcript, "thinking Ns" elapsed clock) and **Phase C = stream Hermes's thinking** (task #50 — needs a backend stdout spike first). Spec: `.docs/ai/phases/on-device-stt-spec.md`.

Older remaining (any of — all need a real device):
1. On-device smoke test: Live Activity (PTT + scheduled fire), arrival badge, transcript expand, AND the new onboarding + Bonjour discovery (needs a same-Wi-Fi Mac running the backend).
2. On-device walkthrough every state of the redesign; fix layout bugs.
3. CarPlay entitlement probe.
