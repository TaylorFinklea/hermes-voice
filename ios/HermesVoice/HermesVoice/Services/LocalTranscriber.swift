import Foundation
import AVFoundation
import FluidAudio

/// On-device speech-to-text via NVIDIA Parakeet (TDT) through FluidAudio's
/// CoreML models — the same package + approach the user runs in ~/git/tesela
/// (`LocalTranscriptionEngine`). Audio never leaves the phone; the transcript
/// is ready before any network hop, which is the whole point of going on-device.
///
/// We ship a single model: **parakeet-tdt-0.6b-v2** (English, ~450 MB). The
/// model set is downloaded at runtime by `AsrModels.downloadAndLoad` (NOT
/// bundled, so the app stays small) on the user's explicit request from
/// Settings, and cached under Application Support across launches. `loadModels`
/// is idempotent + fast once the set is on disk.
///
/// `@MainActor` for two reasons, both mirroring tesela: the cached `AsrManager`
/// is shared mutable state accessed serially on the main actor, and `@Published
/// state` drives the Settings UI.
@MainActor
final class LocalTranscriber: ObservableObject {
    /// Shared instance — matches the `AudioSessionCoordinator.shared` /
    /// `LiveActivityController.shared` service pattern used elsewhere.
    static let shared = LocalTranscriber()

    /// Download/availability of the on-device model. Drives the Settings row
    /// and gates whether `ConversationViewModel` transcribes locally.
    enum ModelState: Equatable {
        case notDownloaded
        case downloading
        case ready
        case failed(String)
    }

    @Published private(set) var state: ModelState = .notDownloaded

    /// True when a mic turn may transcribe on-device. Note: the `AsrManager`
    /// may still need a one-time warm load on the first `transcribe` — that's
    /// handled lazily (and `warmUpIfDownloaded()` hides it off the first turn).
    var isReady: Bool { state == .ready }

    /// Warm, cached manager. `nil` until the first load this process.
    private var manager: AsrManager?
    /// De-dupes concurrent loads (e.g. a background warm-up racing the first
    /// transcribe) so we don't kick off two `downloadAndLoad`s.
    private var loadTask: Task<AsrManager, Error>?

    private init() {
        // Reflect a prior download so the user isn't asked to fetch again. We
        // persist our own flag rather than probing FluidAudio's on-disk layout;
        // `downloadAndLoad` is idempotent, so a stale flag self-heals on load.
        if UserDefaults.standard.bool(forKey: Self.downloadedKey) {
            state = .ready
        }
    }

    // MARK: - Model lifecycle

    /// Download (if needed) and load the model into memory. Idempotent; safe to
    /// tap repeatedly. Drives `state` for the Settings UI.
    func prepare() async {
        if case .downloading = state { return }
        state = .downloading
        do {
            _ = try await ensureManager()
            UserDefaults.standard.set(true, forKey: Self.downloadedKey)
            state = .ready
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    /// If the model is already downloaded, warm the manager in the background so
    /// the first mic turn doesn't pay the load cost. No-op otherwise.
    func warmUpIfDownloaded() {
        guard isReady, manager == nil, loadTask == nil else { return }
        Task { [weak self] in _ = try? await self?.ensureManager() }
    }

    /// Delete the cached model and forget the manager — reverts to the
    /// audio-upload path. Exposed for the Settings "Remove" affordance.
    func deleteModel() {
        manager = nil
        loadTask?.cancel()
        loadTask = nil
        try? FileManager.default.removeItem(at: Self.cacheURL)
        UserDefaults.standard.set(false, forKey: Self.downloadedKey)
        state = .notDownloaded
    }

    // MARK: - Transcription

    /// Transcribe an audio file (the recorder's m4a) entirely on-device.
    /// Decodes to 16 kHz mono float32, then runs Parakeet. Throws if the model
    /// can't load or inference fails — the caller falls back to audio upload.
    func transcribe(audioFileURL url: URL) async throws -> String {
        let manager = try await ensureManager()
        let samples = try Self.readSamples(at: url)
        guard !samples.isEmpty else { return "" }
        // Size the decoder state to the *loaded* model. parakeet v2 uses 2 LSTM
        // layers; a bare `TdtDecoderState()` hardcodes 2 and throws a CoreML
        // shape mismatch if the model disagrees. Mirrors FluidAudio's own
        // callers, which always build from `decoderLayerCount`.
        let decoderLayers = await manager.decoderLayerCount
        var decoderState = TdtDecoderState.make(decoderLayers: decoderLayers)
        let result = try await manager.transcribe(samples, decoderState: &decoderState)
        return result.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Helpers

    private func ensureManager() async throws -> AsrManager {
        if let manager { return manager }
        if let loadTask { return try await loadTask.value }
        let task = Task { () throws -> AsrManager in
            let models = try await AsrModels.downloadAndLoad(to: Self.cacheURL, version: .v2)
            let m = AsrManager(config: .default)
            try await m.loadModels(models)
            return m
        }
        loadTask = task
        do {
            let m = try await task.value
            manager = m
            loadTask = nil
            return m
        } catch {
            loadTask = nil
            throw error
        }
    }

    private static let downloadedKey = "hv.parakeetV2Downloaded"

    /// Persistent cache dir for the model set. Application Support survives
    /// launches and isn't purged like the temp dir.
    private static var cacheURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("HermesTranscription/parakeet-v2", isDirectory: true)
    }

    /// Decode any AVFoundation-readable file (our recorder writes m4a/AAC at
    /// 16 kHz mono) into 16 kHz mono float32 samples for Parakeet. Mirrors
    /// tesela's `readWavSamples` — `AVAudioConverter` handles resample + channel
    /// collapse if the source ever differs.
    private static func readSamples(at url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        guard let pcmFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        ) else {
            throw NSError(domain: "HermesVoice.Transcription", code: -2,
                          userInfo: [NSLocalizedDescriptionKey: "Couldn't create target PCM format"])
        }
        guard let converter = AVAudioConverter(from: file.processingFormat, to: pcmFormat) else {
            throw NSError(domain: "HermesVoice.Transcription", code: -3,
                          userInfo: [NSLocalizedDescriptionKey: "Couldn't build audio converter"])
        }
        let frameCount = AVAudioFrameCount(file.length)
        guard let inputBuffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frameCount) else {
            throw NSError(domain: "HermesVoice.Transcription", code: -4,
                          userInfo: [NSLocalizedDescriptionKey: "Couldn't allocate input buffer"])
        }
        try file.read(into: inputBuffer)
        let ratio = pcmFormat.sampleRate / file.processingFormat.sampleRate
        let outFrames = AVAudioFrameCount(Double(frameCount) * ratio) + 1024
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: pcmFormat, frameCapacity: outFrames) else {
            throw NSError(domain: "HermesVoice.Transcription", code: -5,
                          userInfo: [NSLocalizedDescriptionKey: "Couldn't allocate output buffer"])
        }
        var error: NSError?
        var supplied = false
        converter.convert(to: outputBuffer, error: &error) { _, statusOut in
            if supplied {
                statusOut.pointee = .endOfStream
                return nil
            }
            supplied = true
            statusOut.pointee = .haveData
            return inputBuffer
        }
        if let error { throw error }
        guard let ptr = outputBuffer.floatChannelData?.pointee else {
            throw NSError(domain: "HermesVoice.Transcription", code: -6,
                          userInfo: [NSLocalizedDescriptionKey: "Output buffer has no float channel data"])
        }
        return Array(UnsafeBufferPointer(start: ptr, count: Int(outputBuffer.frameLength)))
    }
}
