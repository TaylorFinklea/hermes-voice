# Hands-Free Conversation Mode — Spec

> Sub-project 2 of the conversational-voice vision (sub-project 1 = on-device TTS, shipped
> build 10). Brainstormed + grounded by the `conversation-mode-recon` workflow. Goal: a
> hands-free loop — **listen → endpoint → transcribe → Hermes → speak → auto re-listen** —
> with no mic press between turns, built entirely on primitives already shipped (on-device
> parakeet STT + Kokoro TTS + the `tts=none` text-brain backend).

## Locked decisions

| Decision | Choice |
|---|---|
| Turn-taking | Half-duplex: listen only *after* the reply finishes (mic & speaker never hot together → **no echo cancellation needed**). |
| STT in the loop | **VAD endpoints the utterance → existing parakeet** `AsrManager.transcribe(samples:)`. NO streaming-EOU model (it needs a separate 120M download; only worth it for full-duplex barge-in, deferred). |
| VAD | FluidAudio **`VadManager`** (Silero v6 CoreML) — streaming API, endpoint on `speechEnd`. Separate small model download. |
| Capture | New continuous **`AVAudioEngine`-tap** component (mirror tesela `StreamingVoiceRecorder`) feeding VAD + emitting endpointed `[Float]` utterances + live RMS level. Current file-based `VoiceRecorder` untouched (press-to-talk coexists). |
| Architecture | New **`ConversationModeController`** composing the VM's turn primitives. Does NOT extend the turn `State` enum. |
| Entry/exit | **Top-bar toggle** (between "+ New conversation" and Settings). Sticky mode. |
| Endpointing | **1.0 s** silence-to-endpoint default (calmer than VAD's 0.75 s ASR default); hysteresis on. Not user-tunable in v1. |
| Rendering | Keep the **focused single-turn hero**, re-arming in place (listening → thinking → speaking → listening). Scrollback rail still shows recent turns. No chat transcript. |
| Interrupt | **Tap the mic while speaking** = barge-in (stop reply → re-arm listening). **End** button + toggle-off exit the mode. Vocal barge-in deferred. |
| Safety | Always-visible **End** + **auto-exit after 3 consecutive empty cycles** + a max-session cap. Hot-mic / battery guard. |
| Backend | None. Reuses the `tts=none` local-voice turn path. (Keeps the multi-harness door open.) |

## Architecture

Three new units + two small additive hooks. Each unit has one job.

### 1. `Services/LocalVad.swift` (NEW) — VAD model lifecycle
`@MainActor ObservableObject` singleton, **mirroring `LocalTranscriber`/`LocalSpeaker` exactly**: `ModelState { notDownloaded, downloading, ready, failed }`, `prepare()` (downloads + loads `VadManager`), `warmUpIfDownloaded()`, persisted "downloaded" flag, `ensureManager() -> VadManager`. The Silero model auto-downloads via `VadManager(config:)` to FluidAudio's Application Support cache; gate it behind an explicit Settings download + warm — **never lazy-download on entering the loop**. Exposes the warm `VadManager` actor for the capture engine; the per-session `VadStreamState` is owned by the capture engine, not here.

### 2. `Services/ConversationCaptureEngine.swift` (NEW) — continuous capture + endpointing
`@MainActor ObservableObject`. **Mirror tesela's `StreamingVoiceRecorder`** for the engine/tap/converter mechanics — including the **`.noDataNow` converter-reuse gotcha** (using `.endOfStream` permanently finishes the converter; copy tesela's pattern). Differences from tesela:
- Feed each converted **4096-sample (256 ms) 16 kHz mono float** chunk into `VadManager.processStreamingChunk(_:state:config:)`, threading a `VadStreamState` across calls.
- Maintain a rolling sample buffer; on a `speechEnd` event, slice the utterance's samples (start→end, with VAD's `speechPadding`) and surface them.
- Skip utterances shorter than parakeet's 300 ms / 4800-sample floor (tesela already guards this).

Exposes:
- `start() async throws` / `stop()` / `cancel()` — install/remove tap; **acquire/release the session through `AudioSessionCoordinator`** (do NOT call `setActive` directly like tesela does — that bypasses the ref-count and would deactivate the session under the player).
- `onUtterance: ([Float]) -> Void` (or `@Published var lastUtterance`) — endpointed samples for the controller to transcribe.
- `levelMonitor` (a small `AudioLevelMonitor`, copy tesela) — **real** RMS level for the listening waveform.
- `@Published var phase: { idle, listening, speechDetected, failed }` for the hero pane.

`VadSegmentationConfig`: `minSilenceDuration = 1.0` (the locked endpointing value, overriding the 0.75 default), keep `minSpeechDuration ≈ 0.15`, `maxSpeechDuration ≈ 14`, default entry threshold (0.85) + hysteresis offset (0.15).

### 3. `ViewModels/ConversationModeController.swift` (NEW) — the loop
`@MainActor ObservableObject`. Owns the loop and the two services above. Its own phase enum (`idle/listening/thinking/speaking`) — **separate from the VM's `State`**.
- `start()`: enter mode → capture engine `start()` → `listening`.
- Loop, per endpointed utterance: `transcribe via LocalTranscriber.transcribe(samples:)` → if empty, bump the empty-cycle counter (auto-exit at 3) and re-arm; else reset the counter, `await vm.submitTranscribedText(text)` (runs the full turn incl. on-device speak), then **re-arm** listening. Because `submitTranscribedText` awaits the turn to completion (including Kokoro playback), the re-arm point is simply "after it returns" — no `$state` observation needed.
- `bargeIn()`: while `speaking`, stop the reply (`vm.cancelCurrentTurn()` / `LocalSpeaker.stop()`) → re-arm listening immediately. Wired to the mic tap in conversation mode.
- `stop()`: exit mode. Fixed teardown order: cancel capture task → stop speaker/player → release session. Auto-exit (3 empty cycles) and max-session cap both call `stop()`.
- Half-duplex session: capture engine releases the mic during `speaking` and re-acquires on re-arm (so the mic isn't hot during playback); reuse the existing 50 ms settle the barge-in path already uses.

### 4. VM hook (one additive method, NO enum change)
`ConversationViewModel.submitTranscribedText(_ text: String) async` — appends the user message, `state = .thinking`, runs `streamTextTurnBody(trimmed, sessionId:, voiceId: serverVoiceId, tts: isLocalVoiceSelected ? "none" : nil)`. This is the *exact* sequence the on-device-STT branch already runs (`stopRecordingAndSend` useLocal path), factored so conversation mode rides the identical pipeline (live tool chips, on-device Kokoro speak, fallback). Owns `currentTurn` so `cancelCurrentTurn()` interrupts it.

### 5. UI
- **`Views/MainView.swift`** — a `bubble.left.and.bubble.right` (filled when active) toggle in `.topBarTrailing`, between New-conversation and Settings, bound to the controller. An `isConversationMode` flag gates the hero + dock.
- **`DesignSystem/HeroPane.swift`** — new `HeroListeningHandsFree` (reuse the `HeroListens` elapsed/timer pattern) showing a **real** VAD-amplitude waveform from `levelMonitor` (replaces the faked `Waveform`). The hero cycles listening → (existing `HeroThinks`) → (existing speaking pane) → listening.
- **Dock** — in conversation mode the right slot shows **End** (reuse the conditional cancel-"X" slot); the center mic tap routes to `controller.bargeIn()` instead of `vm.userPressedMic()`.
- **`Views/SettingsView.swift`** — an `ON-DEVICE LISTENING (VAD)` download row (mirror the transcription/voice sections), observing `LocalVad.shared`.
- **`HermesVoiceApp.swift`** — `LocalVad.shared.warmUpIfDownloaded()` alongside the other warm-ups; inject the controller as an `@EnvironmentObject` (or hold it in the app like the VM).

## Data flow (one cycle)

```
capture tap → 16k float chunks → VadManager.processStreamingChunk (per 4096)
   → speechEnd → [Float] utterance
   → LocalTranscriber.transcribe(samples:) → text
   → (empty? bump counter, re-arm)  | (text → vm.submitTranscribedText)
   → streamText (tts=none) → consumeTurn → Kokoro speak → returns
   → controller re-arms capture → listening …
```

## Error handling / edge cases
- **Empty/garbage endpoint** → counts toward auto-exit (3); the VM already trims-empty-guards.
- **Transcription throws** → log, re-arm (don't kill the loop on one bad utterance); after repeated failures, exit with an error surface.
- **Turn (Hermes) error** → the VM's existing `failTurn` sets `.error`; the controller exits the loop on a turn error and shows it (don't auto-retry into a failing backend).
- **Mic permission denied** → capture `start()` fails → controller surfaces "mic needed", stays out of the mode.
- **App backgrounded** → exit conversation mode (no background mic; matches the dropped-wake-word constraint).
- **Interrupt during thinking** (no audio yet) → `bargeIn()` cancels the turn and re-arms.

## Files
**New:** `Services/LocalVad.swift`, `Services/ConversationCaptureEngine.swift`, `Services/AudioLevelMonitor.swift` (or fold into the engine), `ViewModels/ConversationModeController.swift`.
**Changed:** `ConversationViewModel.swift` (+`submitTranscribedText`), `LocalTranscriber.swift` (+`transcribe(samples:)` overload — body from `ensureManager()` onward, skipping `readSamples`), `MainView.swift` (toggle + mode gating), `HeroPane.swift` (`HeroListeningHandsFree` + real waveform), `SettingsView.swift` (VAD download row), `HermesVoiceApp.swift` (warm-up + controller wiring), `AppSettings.swift` (VAD-downloaded flag), `project.yml` regen (new files).

## Verify
- iOS `xcodebuild … build CODE_SIGNING_ALLOWED=NO` SUCCEEDS. Backend untouched.
- On device: Settings → download VAD model. Toggle conversation mode on → **speak, pause ~1 s, it transcribes + replies in Kokoro, then auto-listens again** with no taps. The listening waveform reflects your actual voice. Tap mic while it's speaking → it stops + listens. End / toggle-off exits and releases the mic. Walk away → auto-exits after 3 silent cycles. Push-to-talk still works unchanged.

## Risks (from recon)
- **Audio-session mode-switch glitches** every turn → route through `AudioSessionCoordinator`, reuse the 50 ms settle, release mic during speaking.
- **Endpointing tuning** — 1.0 s start, lean on hysteresis; budget an on-device tuning pass; it's the most-felt parameter.
- **Battery/thermal** — continuous tap + VAD every 256 ms + two warm ANE models; auto-exit + max-session cap are the defense; flag for device thermal testing.
- **VAD model download** is a *separate* fetch → explicit Settings download + warm, never lazy on entry.
- **Teardown ordering** — fixed order (cancel capture → stop speaker → release session) so nothing deactivates the session under another component.

## Status

- **BUILT (iOS BUILD SUCCEEDED, 0 errors), 2026-05-30.** Not cut to a build / device-tested.
  Files added: `LocalVad`, `ConversationCaptureEngine` (+ `AudioLevelMonitor`),
  `ConversationModeController`. Touched: `LocalTranscriber` (+`transcribe(samples:)`),
  `MainView` (top-bar toggle, mode-gated `heroScroll`, `ConversationModeDock`, scenePhase
  exit, error alert), `HeroPane` (`HeroListeningHandsFree` + real-level `LiveWaveform`),
  `SettingsView` (VAD download row), `HermesVoiceApp` (controller wiring + VAD warm-up).
- **Two simplifications vs the spec** (both reduce code/risk): (1) the controller calls the
  existing `vm.sendText` instead of a new `submitTranscribedText` — `sendText` already runs
  the exact text-turn pipeline (incl. `tts=none` → Kokoro); (2) failures surface via a
  published `errorMessage` + a MainView `.alert` instead of an `.error` phase, so the toggle
  never looks "active" in an error.
- Backend untouched (reuses the shipped `tts=none` local-voice path).
- Device-test checklist: Settings → download the VAD model + have a Kokoro voice selected →
  tap the top-bar bubble → speak, pause ~1 s, it transcribes + replies in Kokoro, then
  auto-listens with a real waveform; tap the center button while it's speaking to barge-in;
  End / toggle-off / backgrounding exits + releases the mic; walk away → auto-exits after 3
  silent cycles; push-to-talk still works unchanged.

## Out of scope (future)
- Vocal barge-in / full-duplex echo cancellation (→ then `StreamingEouAsrManager` becomes worth its second model).
- Streaming/partial transcripts; user-tunable endpointing; full chat-transcript view.
- Conversation mode for the Watch.
- Multi-harness backends (the `tts=none` hook is already laid).
