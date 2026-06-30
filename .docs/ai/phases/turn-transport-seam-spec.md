# Spec: `TurnTransport` seam for testable turn logic

**Date:** 2026-06-29
**Goal:** Unblock the deferred `ConversationViewModel` turn state-machine tests (roadmap line 99) by introducing a narrow protocol seam over the turn network calls. No behavior change; additive tests.
**Scope decision:** "Narrow seam + tests" (user-chosen 2026-06-29) — NOT the full `TurnPipeline` extraction, NOT the 18→1 BackendClient consolidation.

## Problem

The turn state machine lives entirely inside `ConversationViewModel` (936 lines) and reaches the backend through a concrete `HermesVoiceAPI` struct rebuilt from settings on every access (`api` computed prop, L142). There is no injection seam, so the turn flow (`consumeTurn` SSE loop, 404/405 single-shot fallbacks, History recovery, event→state transitions) cannot be driven in tests. The deferred VM tests were blocked on exactly this.

## VM backend surface (verified — every `api.*` call in the VM)

`grep 'api\.'` over the VM yields exactly 7 distinct `HermesVoiceAPI` methods. All 7 go on the protocol so the VM's `api` can be uniformly protocol-typed (mirroring each concrete signature exactly — `voiceId: String?` throughout, since the concrete stream/send methods all use `voiceId: String? = nil`):
- `streamText(_:sessionId:voiceId:tts:harness:mode:) -> AsyncThrowingStream<TurnEvent, Error>` (VM L316)
- `streamAudio(fileURL:mimeType:sessionId:voiceId:tts:harness:mode:) -> AsyncThrowingStream<TurnEvent, Error>` (VM L254)
- `sendText(_:sessionId:voiceId:tts:harness:) -> TurnResponse` — single-shot fallback (VM L565)
- `sendAudio(fileURL:mimeType:sessionId:voiceId:tts:harness:) -> TurnResponse` — single-shot fallback (VM L576)
- `getSession(id:) -> HistoryDetail` — History recovery (VM L498)
- `answerTurn(turnId:requestId:value:) async throws` — spoken answer-card path (VM L727)
- `makeURL(path:) -> URL?` — pure URL builder for audio playback (VM L426)

## Design

### 1. `TurnTransport` protocol — new `Services/TurnTransport.swift`

Declares the 7 methods above, returning the existing `HermesVoiceAPI.{TurnEvent,TurnResponse,HistoryDetail}` nested types (DTOs do NOT move). `HermesVoiceAPI` conforms via `extension HermesVoiceAPI: TurnTransport {}` — existing signatures already match (protocol requirements without defaults are satisfied by the concrete methods' defaulted params), so the conformance body is empty and behavior is unchanged.

### 2. VM injection

- `init(settings: AppSettings, transport: TurnTransport? = nil)` (was `init(settings:)`).
- `private var api: TurnTransport { transport ?? HermesVoiceAPI(baseURL: settings.backendURL, authToken: settings.authToken) }`
- Default `nil` preserves today's live-settings-following construction byte-for-byte; tests pass a fake.
- The `catch let HermesVoiceAPI.APIError.httpStatus(code, _)` clauses are unchanged — the fake throws that same error type to exercise the fallback path.

### 3. Tests — `HermesVoiceTests/TurnStateMachineTests.swift`

A `FakeTransport: TurnTransport` returns scripted `AsyncThrowingStream<TurnEvent>` (and scripted `getSession`/`sendText` results/throws). Drive `sendText(...)` (the audio-free entry — no recorder/transcriber needed) and assert:
- **Happy path:** `thinking → … → idle`; user + assistant messages committed; a `tools` event replaces the live best-effort chips with the authoritative list.
- **404/405 fallback:** stream throws `HermesVoiceAPI.APIError.httpStatus(404)` → `sendTextFallback` → `handle(response:)` commits the reply.
- **Mid-stream throw → recovery:** non-HTTP error with no surfaced reply → `recoverMissingAssistantFromHistory` (fake `getSession`) backfills the assistant message and returns to `.idle`; when nothing recovers → `failTurn` → `.error`.
- **Late-drop guard:** `currentTurnHasAssistantReply()` — a transport drop AFTER the assistant reply already streamed in does NOT downgrade to `.error`.

**Audio singletons stay inert:** set `settings` to `fillerVerbosity = .off` + a server (non-local) voice, and script streams WITHOUT `audio` events, so `LocalSpeaker.shared` / `player` are never touched. No audio seam required.

## Out of scope (deferred — remain on roadmap)

- 18→1 `BackendClient` consolidation of the ad-hoc `HermesVoiceAPI(...)` sites.
- Moving the ~10 DTOs out of the `HermesVoiceAPI` namespace.
- Full `TurnPipeline`/`HermesTurnService` object extraction.
- Audio-path (`stopRecordingAndSend`) tests — need recorder/transcriber/speaker seams.

## Verify

`xcodebuild test` green: existing 50 tests + new `TurnStateMachineTests`. Production turn behavior unchanged (no-op refactor + additive coverage).
