# On-Device STT (parakeet-v2 via FluidAudio) — Spec

> From on-device feedback (2026-05-29): user wants to "prioritize on-device stuff…
> like parakeet v2 — I use it in ~/git/tesela and it works well." Chosen direction
> (AskUserQuestion): **On-iPhone (FluidAudio)** — transcribe on the phone, send text.
> Recon confirmed tesela's parakeet is iOS-only via `FluidInference/FluidAudio` (CoreML),
> NOT Mac/MLX. So we mirror tesela's `LocalTranscriptionEngine` parakeet path.

## Why this is the right shape

- **An audio turn becomes a text turn.** The app already has `sendText → streamText →
  consumeTurn(appendUserFromTranscribed:false)`. On-device STT just produces the text
  locally, then reuses that proven path. The existing `streamAudio` upload path becomes
  the **automatic fallback** (model not downloaded yet, or transcription fails).
- **Maximal win:** audio never leaves the phone; transcript is ready *before* any network
  hop; the "transcribing + dispatching" wait (server STT round-trip) largely disappears.
- **Proven tech for this user:** FluidAudio at `branch main`, consumed by a Swift-5 app
  (tesela does exactly this from `SWIFT_VERSION 5.0`). FluidAudio `Package.swift` declares
  `platforms: [.macOS(.v14), .iOS(.v17)]` — Hermes Voice's iOS 17.0 floor is compatible.

## Locked decisions

| Decision | Choice |
|---|---|
| Where STT runs | On the iPhone (FluidAudio / CoreML), mirroring tesela. |
| Model | **parakeet-tdt-0.6b-v2** (English, ~450 MB) — the variant the user trusts in tesela. v3/tdtCtc110m deferred. |
| Package pin | Pin FluidAudio to the **exact revision tesela proved** (`50aa07193e84b9cf192d8f36041c24a9a4867cd6`), not `branch: main` — guarantees the API we mirror. Loosen later if desired. |
| Model delivery | **Downloaded at runtime** by `AsrModels.downloadAndLoad` (NOT bundled — app stays small). Cached in Application Support, survives launches. |
| Download trigger | **Explicit, in Settings** (a "Download model (~450 MB)" button) — no silent 450 MB pull. |
| Default usage | `useOnDeviceSTT` defaults **ON**, but is a no-op until the model is downloaded → until then, today's upload path runs unchanged (zero regression). |
| Fallback | If on-device is disabled OR model not ready OR transcription throws → upload audio to `/api/audio/stream` exactly as today. |
| Cancellation | Barge-in / dock-X must cancel during on-device transcription too (same `currentTurn` task ownership as the streaming turn). |

## Phasing (one testable TestFlight build per phase)

### Phase A — On-device STT core  ← THIS BUILD
1. **`project.yml`** — add `packages: FluidAudio` (pinned `revision`) and a
   `package: FluidAudio / product: FluidAudio` dependency on the **HermesVoice app target
   only** (not Watch/Widget). Regenerate with `xcodegen generate`.
2. **`Services/LocalTranscriber.swift`** (new, `@MainActor`, `ObservableObject`, shared
   singleton like `AudioSessionCoordinator.shared`):
   - Publishes `state: ModelState { notDownloaded, downloading, ready, failed(String) }`.
   - `prepare()` → `AsrModels.downloadAndLoad(to: cacheURL, version: .v2)` then
     `AsrManager(config: .default).loadModels(...)`; cache the manager statically; set state.
   - `transcribe(audioFileURL:) async throws -> String` — decode the m4a to **16 kHz mono
     float32** via `AVAudioFile` + `AVAudioConverter` (mirror tesela `readWavSamples`), then
     `TdtDecoderState.make(decoderLayers: manager.decoderLayerCount)` +
     `manager.transcribe(samples, decoderState:&)` → `result.text` trimmed.
   - `isReady: Bool` convenience. Cache dir: Application Support/`HermesTranscription/parakeet-v2/`.
3. **`Models/AppSettings.swift`** — add `useOnDeviceSTT: Bool` (Keys + init default **true**).
4. **`ViewModels/ConversationViewModel.swift`** — rewire `stopRecordingAndSend()`:
   - If `settings.useOnDeviceSTT && LocalTranscriber.shared.isReady`: transcribe locally
     (inside `currentTurn` so it's cancellable). On success → discard audio, append the user
     message, `state = .thinking`, run the **text-stream** turn (factor a private
     `runTextTurn(_:)` shared with `sendText`). Empty transcript → back to `.idle`.
     `httpStatus` from the stream → `sendTextFallback`. Transcription throws → fall through
     to the **upload** path (audio not yet discarded).
   - Else: existing upload path, unchanged.
   - Add `SendingPhase.transcribing` for the local case (pipeline label).
5. **`DesignSystem/HeroPane.swift`** — for the local path, the `.sending` pipeline shows
   "transcribing on device" instead of "uploading to backend / dispatching" (the audio-upload
   steps are wrong when nothing uploads). Minimal: drive the third step's label off
   `sendingPhase == .transcribing`.
6. **`Views/SettingsView.swift`** — new `transcriptionSection` (observes
   `LocalTranscriber.shared`): model status row, Download/Retry button (→ `prepare()`),
   spinner while `.downloading`, "parakeet-v2 · ready" when ready, and a "Transcribe on
   device" toggle bound to `settings.useOnDeviceSTT` (effective only when ready).

**Verify:** `xcodebuild … build CODE_SIGNING_ALLOWED=NO` SUCCEEDS (resolves the SPM pkg).
On device: Settings shows the model section; Download fetches the model once; after that, a
mic turn transcribes locally (no audio upload — confirmable via backend logs showing
`/api/text/stream`, not `/api/audio/stream`); barge-in/cancel still work; disabling the
toggle or deleting the model reverts to upload with no error.

### Phase B — Live-progress bundle (task #49)
With local STT the transcript is instant; the remaining wait is purely Hermes. Adapt the
pipeline (transcript shown immediately, real-event-driven steps) + add a live "thinking Ns"
elapsed clock to `HeroSending`/`HeroThinks`. Detailed in the earlier latency synthesis.

### Phase C — Stream Hermes's thinking (task #50)
Backend spike: confirm `hermes` flushes usable intermediate stdout; if so forward it
(`StreamThink` → new `TurnEvent`) so no-tool replies aren't a silent wait.

## Risks / unknowns
- **SPM resolution at build time** pulls FluidAudio from GitHub — the build environment needs
  network. Pinned revision = reproducible.
- **Model API drift** avoided by pinning to tesela's exact proven revision.
- **First-call cost:** 450 MB one-time download (explicit, in Settings) + a model-load beat.
  Load is via `prepare()` so the first *mic* turn isn't the one paying download cost.
- **Audio decode:** `VoiceRecorder` writes m4a/AAC 16 kHz mono; `AVAudioFile` decodes it and
  `AVAudioConverter` yields the 16 kHz mono float32 parakeet wants (same as tesela).
- **Watch path** unchanged (Watch turns still relay through the phone's existing flow).

## Status

- **Phase A — BUILT (iOS BUILD SUCCEEDED), 2026-05-29.** FluidAudio SPM package resolves +
  compiles (first resolve fetches from GitHub; pinned revision). `LocalTranscriber`,
  `AppSettings.useOnDeviceSTT`, the `stopRecordingAndSend` rewire (local→text, upload
  fallback) + `streamTextTurnBody`, the `HeroSending` "transcribing on device" label, the
  Settings section, and launch warm-up are all in. Backend untouched. **Not cut to a
  TestFlight build and NOT device-tested** — the ~450 MB model download + the local-vs-upload
  routing only exist at runtime on a real device.
- **Phase B / C** — not started (tasks #49 / #50).

## Out of scope
- On-device TTS (user flagged as a separate future pursuit — roadmap, not now).
- Streaming/partial on-device STT (single-shot per clip for v1).
- Model picker (v3/multilingual, lighter tdtCtc110m) — v1 ships v2 only.
