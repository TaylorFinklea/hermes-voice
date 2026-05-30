import Foundation
import AVFoundation
import FluidAudio

/// A rolling window of recent mic RMS levels (0…1) driving the hands-free
/// "listening" waveform. Its own object so only the small waveform view
/// re-renders at audio-buffer rate. (Mirrors tesela's AudioLevelMonitor.)
@MainActor
final class AudioLevelMonitor: ObservableObject {
    @Published private(set) var levels: [Float]
    private let windowSize = 32
    init() { levels = Array(repeating: 0, count: windowSize) }
    func push(_ level: Float) {
        var next = levels
        next.removeFirst()
        next.append(min(1, max(0, level)))
        levels = next
    }
    func reset() { levels = Array(repeating: 0, count: windowSize) }
}

/// Continuous mic capture + on-device VAD endpointing for hands-free mode.
/// Built on `AVAudioEngine` (a *sample tap*, unlike the file-based
/// `VoiceRecorder`) so VAD can watch the audio live. Mirrors tesela's
/// `StreamingVoiceRecorder` for the engine/tap/converter mechanics — including
/// the `.noDataNow` converter-reuse gotcha — and adds VAD on top.
///
/// `listen()` returns a single endpointed utterance, then tears the engine down
/// and releases the session. The conversation controller calls it in a loop —
/// one utterance per turn, mic off in between (half-duplex).
@MainActor
final class ConversationCaptureEngine: ObservableObject {
    enum Phase: Equatable { case idle, listening, speech, failed(String) }
    @Published private(set) var phase: Phase = .idle

    let levelMonitor = AudioLevelMonitor()

    enum CaptureError: Error { case converterUnavailable }

    private let engine = AVAudioEngine()
    private var streamContinuation: AsyncStream<[Float]>.Continuation?

    private let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!

    private static let vadChunk = 4096            // VadManager.chunkSize (256 ms @ 16 kHz)
    private static let preRollMax = 8_000         // ~0.5 s lookback so onsets aren't clipped
    private static let minUtteranceSamples = 4_800 // parakeet's 300 ms floor

    /// Listen until the user finishes one utterance; return its 16 kHz mono
    /// float samples. Throws `CancellationError` if the caller cancels (End /
    /// barge-in) before an utterance lands. Always tears down the engine +
    /// releases the audio session on exit (half-duplex: mic off after the turn).
    func listen() async throws -> [Float] {
        let vad = try await LocalVad.shared.ensureManager()

        AudioSessionCoordinator.shared.acquire(.record)
        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
            AudioSessionCoordinator.shared.release()
            phase = .failed("audio converter unavailable")
            throw CaptureError.converterUnavailable
        }
        let target = targetFormat

        let (stream, cont) = AsyncStream<[Float]>.makeStream()
        streamContinuation = cont
        input.installTap(onBus: 0, bufferSize: AVAudioFrameCount(Self.vadChunk), format: inputFormat) { buffer, _ in
            if let out = Self.convert(buffer, using: converter, to: target), !out.isEmpty {
                cont.yield(out)
            }
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            teardown()
            phase = .failed(error.localizedDescription)
            throw error
        }
        levelMonitor.reset()
        phase = .listening

        do {
            let utterance = try await withTaskCancellationHandler {
                try await runVadLoop(stream, vad: vad)
            } onCancel: {
                cont.finish()   // end the for-await promptly even during silence
            }
            teardown()
            phase = .idle
            return utterance
        } catch {
            teardown()
            phase = .idle
            throw error
        }
    }

    /// Tear down without waiting on a `listen()` to return — used by the
    /// controller's End/barge-in path when it isn't the one awaiting.
    func stop() {
        streamContinuation?.finish()
        teardown()
        phase = .idle
    }

    // MARK: - VAD loop

    private func runVadLoop(_ stream: AsyncStream<[Float]>, vad: VadManager) async throws -> [Float] {
        var vadState = await vad.makeStreamState()
        let config = VadSegmentationConfig(minSilenceDuration: 1.0)  // calmer turn boundary than 0.75 default
        var acc: [Float] = []
        var preRoll: [Float] = []
        var utterance: [Float] = []
        var collecting = false

        for await converted in stream {
            try Task.checkCancellation()
            levelMonitor.push(Self.rms(converted))
            acc.append(contentsOf: converted)
            while acc.count >= Self.vadChunk {
                let chunk = Array(acc.prefix(Self.vadChunk))
                acc.removeFirst(Self.vadChunk)
                let result = try await vad.processStreamingChunk(chunk, state: vadState, config: config)
                vadState = result.state
                if let event = result.event {
                    switch event.kind {
                    case .speechStart:
                        collecting = true
                        utterance = preRoll + chunk
                        preRoll = []
                        phase = .speech
                    case .speechEnd:
                        utterance.append(contentsOf: chunk)
                        if utterance.count >= Self.minUtteranceSamples {
                            return utterance
                        }
                        // Too short to be speech — drop it and keep listening.
                        collecting = false
                        utterance = []
                        phase = .listening
                    }
                } else if collecting {
                    utterance.append(contentsOf: chunk)
                } else {
                    preRoll.append(contentsOf: chunk)
                    if preRoll.count > Self.preRollMax {
                        preRoll.removeFirst(preRoll.count - Self.preRollMax)
                    }
                }
            }
        }
        throw CancellationError()  // stream finished without an utterance (cancelled)
    }

    // MARK: - Helpers

    private func teardown() {
        if engine.isRunning {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        streamContinuation = nil
        AudioSessionCoordinator.shared.release()
        levelMonitor.reset()
    }

    /// Convert one tap buffer to 16 kHz mono float32. The converter is reused
    /// across buffers, so the input block returns `.noDataNow` (NOT
    /// `.endOfStream`, which permanently finishes the converter).
    private static func convert(_ buffer: AVAudioPCMBuffer, using converter: AVAudioConverter, to target: AVAudioFormat) -> [Float]? {
        let ratio = target.sampleRate / buffer.format.sampleRate
        let cap = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 256
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: cap) else { return nil }
        var err: NSError?
        var supplied = false
        converter.convert(to: out, error: &err) { _, status in
            if supplied { status.pointee = .noDataNow; return nil }
            supplied = true
            status.pointee = .haveData
            return buffer
        }
        guard err == nil, let ptr = out.floatChannelData?.pointee else { return nil }
        return Array(UnsafeBufferPointer(start: ptr, count: Int(out.frameLength)))
    }

    private static func rms(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        var sum: Float = 0
        for v in samples { sum += v * v }
        return min(1, (sum / Float(samples.count)).squareRoot() * 6)  // boosted so speech fills the meter
    }
}
