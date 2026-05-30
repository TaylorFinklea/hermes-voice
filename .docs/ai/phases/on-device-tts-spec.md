# On-Device TTS (Kokoro via FluidAudio) — Spec

> From the 2026-05-29 brainstorm after on-device STT landed instant. User: "this would
> be incredibly powerful paired with [TTS] on device just as fast reading it back… and
> more natural [hands-free] follow-ups." Decomposed into two sub-projects; **this spec is
> sub-project 1: on-device TTS.** Sub-project 2 (hands-free conversation mode w/ VAD) is
> the next brainstorm. Locked decisions: TTS runs **on the phone** (Kokoro), playback is
> **sentence-chunked** (instant start).

## Why this shape

- **Phone owns voice I/O; backend becomes a swappable text brain.** When a local voice is
  selected the phone tells the backend **`tts=none`** (skip synthesis, emit no `audio`
  event) and synthesizes the reply itself. That `tts=none` mode is exactly what a future
  Claude-Code / other-harness backend would speak — this is the architectural hook for the
  multi-harness ambition, captured now without building it.
- **No new dependency** — Kokoro ships inside the FluidAudio package already in build 9.

## Proven API (read from FluidAudio source + its CLI — NOT guessed)

```swift
let m = KokoroAneManager(variant: .english, defaultVoice: "af_heart")
try await m.initialize()                                   // downloads (if missing) + loads models; cached
let wav = try await m.synthesize(text:, voice:, speed:)    // → 24 kHz mono 16-bit PCM WAV (Data)
// or: m.synthesizeDetailed(...) -> KokoroAneSynthesisResult { samples:[Float], sampleRate:Int, timings }
```
- Runs on the Neural Engine **faster than real-time** (CLI logs RTFx > 1).
- English voices are string ids: `af_heart` (default), `am_*`, `bf_*`, `bm_*` (Am/Br female/male).
- Models cached by FluidAudio under `~/.cache/fluidaudio/Models/kokoro/` (a few hundred MB).

## Locked decisions

| Decision | Choice |
|---|---|
| Where TTS runs | On the iPhone (Kokoro / Neural Engine). |
| Playback | **Sentence-chunked**: synthesize + play sentence-by-sentence, prefetching the next while the current plays → first words in ~0.3s even on long replies. |
| Backend role | New **`tts=none`** request mode on the stream endpoints → skip synthesis, emit no `audio` event. Default (omitted) = synthesize as today. |
| Voice selection | Reuse the existing Settings VOICE picker; add an "On-device (Kokoro)" group whose ids use a **`local:` sentinel** (`selectedVoiceId = "local:af_heart"`). One picker, one setting. |
| Default | **Unchanged** (ElevenLabs/server). User opts in by picking a Kokoro voice; fully reversible. |
| Model delivery | Downloaded at runtime by `initialize()` (not bundled); explicit Download in Settings; cached across launches. |
| Cancellation | Barge-in / dock-X stops local playback (`LocalSpeaker.stop()`) the same way it stops the streaming `AudioPlayer` today. |
| Scope | **Interactive turns only.** Scheduled-fire push audio stays server-side. ElevenLabs stays a first-class option. No VAD/conversation-mode (sub-project 2). |

## Implementation

### iOS
1. **`Services/LocalSpeaker.swift`** (NEW, `@MainActor`, `ObservableObject`, `shared` singleton — mirror `LocalTranscriber`):
   - `state: ModelState { notDownloaded, downloading, ready, failed(String) }`; persisted "downloaded" flag; `prepare()` → `KokoroAneManager.initialize()`; `warmUpIfDownloaded()` at launch.
   - `speak(_ text: String, voice: String) async` — split into sentences; pipeline synth→play with a **1-ahead prefetch** (synthesize sentence *n+1* while sentence *n* plays); play each WAV via `AVAudioPlayer` with a finish-continuation; cancellable. Acquire/release `AudioSessionCoordinator.shared` (`.playback`) around the whole utterance (mirror `AudioPlayer`).
   - `stop()` — cancel the speak task, stop the current player, release the session.
   - Sentence splitter: pragmatic split on `.?!` boundaries with a min-length merge (don't over-fragment); keep it simple, tune on-device.
2. **`Models/AppSettings.swift`** — helpers on the existing `selectedVoiceId`: `isLocalVoiceSelected` (`hasPrefix("local:")`) and `localVoiceName` (the suffix). No new stored field needed beyond what the picker writes.
3. **`ViewModels/ConversationViewModel.swift`**:
   - `consumeTurn` `.assistant(txt, sid)` arm: after committing the message, if `settings.isLocalVoiceSelected` → `state = .speaking` → `await LocalSpeaker.shared.speak(txt, voice: settings.localVoiceName)` → `state = .idle`. Guard the `.audio` arm to ignore any server audio when a local voice is active.
   - Send `tts=none` on the turn request when a local voice is selected (both `streamText` and the `streamAudio` fallback).
   - `.speaking` teardown in `userPressedMic` / `cancelCurrentTurn` also calls `LocalSpeaker.shared.stop()`.
4. **`Services/HermesVoiceAPI.swift`** — thread an optional `tts: String?` (or `Bool`) through `streamText`/`streamAudio` (+ the single-shot `sendText`/`sendAudio` fallbacks): when set, add `"tts": "none"` to the JSON / a `tts` form field.
5. **`Views/SettingsView.swift`** — extend the VOICE picker with an "On-device (Kokoro)" group (a curated few: `af_heart`, an `am_*`, a `bf_*`, a `bm_*`), tagged `local:<id>`; add a model-download row (observes `LocalSpeaker.shared`: Download / downloading / "Kokoro · ready" / Remove), mirroring the ON-DEVICE TRANSCRIPTION section.
6. **`HermesVoiceApp.swift`** — `LocalSpeaker.shared.warmUpIfDownloaded()` alongside the transcriber warm-up.
7. **Watch** (`PhoneWatchBridge`): when `playReplyOnWatch` + a local voice, synthesize the reply to a file on the phone and transfer via the existing path instead of downloading server audio. (Keep minimal; verify the transfer path still gets a file URL.)

### Backend (small)
8. **`app/main.py`** stream endpoints + `_stream_turn`, and `app/models.py` request shapes: accept `tts` (`"none"` to skip). When `tts == "none"`, do not start TTS / do not emit the `audio` event (the `assistant` + `done` events still flow). Mirror on the single-shot `/api/text` + `/api/audio` so the fallbacks honor it too.
9. **Tests** (`backend/tests`): a `tts=none` case asserting no `audio` event / null `audioUrl`; existing TTS tests stay green.

**Verify:** iOS `xcodebuild … build CODE_SIGNING_ALLOWED=NO` SUCCEEDS; backend `uv run --extra dev pytest` green. On device: download the Kokoro model in Settings; pick a Kokoro voice; a turn's reply is **spoken on-device, first words within a beat**, with **no `audio` event from the backend** (logs show `tts=none`); switching back to an ElevenLabs voice restores server TTS; barge-in/cancel cut playback cleanly.

## Risks / unknowns
- **Exact model-set size** unknown from source (a few hundred MB); surface whatever the download reports, keep the Settings copy generic.
- **Sentence-boundary quality** — naive split can clip abbreviations/decimals; acceptable for v1, tune on-device (this is the most likely polish item).
- **Gapless-ness** — `AVAudioPlayer`-per-sentence may leave tiny inter-sentence gaps; natural for speech, but if jarring, move to `AVAudioPlayerNode` buffer scheduling later.
- **Session coordination** — playback must go through `AudioSessionCoordinator` so it composes with record/chime; mirror `AudioPlayer`'s acquire/release exactly.
- **First-call cost** — model download (Settings, explicit) + a load beat hidden by `warmUpIfDownloaded()`.

## Status

- **BUILT, 2026-05-29.** iOS **BUILD SUCCEEDED** (Kokoro API + sentence-chunked
  `LocalSpeaker` + `tts=none` wiring). Backend `tts=none` added with 3 tests; suite green
  (the 2 `test_mdns.py` failures in a full run are a **pre-existing** ordering/event-loop
  flake — they fail at HEAD too and pass in isolation). **Not cut to a build / device-tested.**
- **Watch decision:** `PhoneWatchBridge` already sends no `voice_id`/`tts`, so Watch replies
  always used **server** TTS independent of the phone's voice — left unchanged (no
  regression, no on-phone-synth-then-transfer needed for v1).
- Device-test checklist: download Kokoro in Settings → pick an "On-device" voice → a reply
  is spoken on-device (first words within a beat), backend shows `tts=none`/no audio event;
  barge-in/cancel cut playback; switching back to an ElevenLabs voice restores server TTS.

## Out of scope (future)
- Hands-free conversation mode + VAD turn-taking (sub-project 2 — `VadManager`/`StreamingEouAsrManager` are already in FluidAudio).
- Vocal barge-in / full-duplex echo cancellation (user deferred; tap-to-interrupt already covers it).
- On-device TTS for scheduled-fire push audio.
- Multi-harness backends (the `tts=none` hook is laid; the actual Claude-Code front-end is later).
