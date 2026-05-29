# Live Progress + Conversation Control — Spec

> From on-device feedback (2026-05-29): "it's not showing me what it's doing live"
> and "every time I hit the microphone it creates a new conversation… I'd rather
> control when a new conversation starts and scroll through history." Brainstormed
> design: **enhance the now-playing model** (don't pivot to a threaded chat view).

## Decisions (locked via brainstorm)

| Decision | Choice |
|---|---|
| Conversation model | Keep now-playing focus; add live action + conversation control *into* it (user picked "Enhance now-playing"). |
| Continuity | Already preserved server-side (`sessionId` threads via `--resume`). This is a visibility/control gap, NOT lost context. |
| New conversation | Explicit **"+ New conversation"** control in the top bar → `conversation.reset()`. Old thread persists in Hermes → appears in History (not destructive, no confirm). |
| Dock X | Simplify to **cancel-only** (drop its overloaded idle "new conversation" role, which caused the confusion). |
| Live tool-calls | Stream them into the PONDERS/SENDING pane as they happen, reusing the existing `ToolChip` look. |
| Phasing | **Phase 1** (iOS-only conversation control) ships first; **Phase 2** (live streaming) follows after a feasibility check. |

## Phase 1 — Conversation control + visible thread (iOS only)

- **`MainView` top bar**: add a "+ New conversation" button (e.g. `square.and.pencil` / `plus.bubble`) → `conversation.reset()`. Keep History (clock) + Settings (gear).
- **Dock X**: becomes cancel-only — `cancelCurrentTurn()` during an active turn; hidden / disabled when `.idle` (no more `reset()` on the X). Removes the overloaded glyph.
- **"continuing · N" pill**: shown under the title (or in the scrollback area) when `conversation.sessionId != nil`; N = completed turns in the in-memory thread. Tapping it opens the in-app `TranscriptView` (the live thread). Hidden in a fresh/empty conversation.
- **Thread discoverability**: the pill (+ a chevron) is the obvious entry to the transcript; scrollback-rail tap still opens it too.
- No backend changes.

**Verify:** iOS BUILD SUCCEEDED. On device: new-convo button starts a fresh session (next turn has no `--resume`); pill shows turn count + opens the transcript; X only cancels.

## Phase 2 — Live tool-call streaming (backend + iOS)

- **Feasibility check FIRST (plan step 1):** determine which yields tool-calls *mid-turn*:
  (a) poll `hermes sessions export --session-id <id>` during the turn (id known on `--resume`; first-turn id via newest-session-by-time), or
  (b) run `hermes chat` WITHOUT `-Q` and parse the streamed tool-preview lines.
  Pick whichever returns partial results live; keep today's after-the-fact audit as the fallback.
- **Backend**: a streaming turn endpoint (SSE) emitting ordered events: `transcribed` → `tool` (each call as it lands: name/preview/ok) → `assistant` (final text) → `audio` (the existing progressive-TTS URL) → `done` (session_id). Reuses `session_audit._summarize` shaping. Token-gated like the rest.
- **iOS**: consume the SSE stream; append tool chips **live** to the thinking/sending pane (reuse `ToolChip`); keep the progressive `AudioPlayer` for TTS. Degrade to the current single-shot `/api/audio`/`/api/text` if the stream errors or isn't available.

**Verify:** backend tests stay green (+ new streaming tests); iOS BUILD SUCCEEDED. On device: tool chips appear *during* the turn, not only after; audio still streams; a slow turn no longer feels frozen.

## Out of scope

- Threaded/chat main view (rejected in favor of enhancing now-playing).
- Streaming STT (separate roadmap item).
- The "can't launch a new conversation from the Claude harness" aside (not an app concern).

## Status — SHIPPED 2026-05-29

- **Phase 1** (`47994f7`): MainView "+ New conversation" button, "continuing · N" pill → transcript, cancel-only dock X. In TestFlight build 7.
- **Phase 2** (`d6377cc` backend, `67a04a9` iOS): validated Hermes flushes tool previews to stdout incrementally through a pipe (probe), and the session export JSON carries the clean reply. `hermes.ask_streaming` (non-`-Q`) + `fetch_turn_result` (export) + SSE `/api/text/stream` & `/api/audio/stream`; iOS `HermesVoiceAPI.streamText/streamAudio` (URLSession.bytes) + `ConversationViewModel.consumeTurn` render chips live with single-shot fallback. Backend **53/53**, iOS **BUILD SUCCEEDED**. **Not yet in a build; not on-device-tested.**
- **On-device checklist:** tool chips appear *during* the turn (not only after); a slow turn no longer feels frozen; audio still streams; barge-in still cancels; fallback path works if `/stream` is unavailable.
- **Follow-ups:** the live `┊`-line parser is display-only (reconciled by the export) and may need format tweaks across Hermes versions; consider a tighter client turn-timeout/clear-error for genuinely slow turns.
