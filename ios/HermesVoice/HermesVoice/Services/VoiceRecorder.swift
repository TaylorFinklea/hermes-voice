import AVFoundation

/// Records microphone audio to an m4a (AAC) file. AAC was chosen over WAV/PCM
/// to keep upload sizes small — the OpenAI/Groq Whisper APIs accept it directly.
///
/// `@MainActor` so its session acquire/release go through `AudioSessionCoordinator`
/// (also `@MainActor`) as plain synchronous calls.
@MainActor
final class VoiceRecorder: NSObject, AVAudioRecorderDelegate {
    enum RecorderError: LocalizedError {
        case permissionDenied
        case sessionFailure(Error)
        case startFailure(Error)
        var errorDescription: String? {
            switch self {
            case .permissionDenied: return "Microphone access not granted."
            case .sessionFailure(let e): return "Audio session error: \(e.localizedDescription)"
            case .startFailure(let e): return "Could not start recording: \(e.localizedDescription)"
            }
        }
    }

    private(set) var recorder: AVAudioRecorder?
    private(set) var startedAt: Date?
    private(set) var lastClipDuration: TimeInterval?

    var currentURL: URL? { recorder?.url }

    /// Seconds since the current recording began, or nil if not recording.
    var elapsed: TimeInterval? {
        guard let startedAt else { return nil }
        return Date().timeIntervalSince(startedAt)
    }

    /// Asks for mic permission if needed. Safe to call repeatedly.
    func requestPermission() async -> Bool {
        if #available(iOS 17.0, *) {
            return await AVAudioApplication.requestRecordPermission()
        } else {
            return await withCheckedContinuation { cont in
                AVAudioSession.sharedInstance().requestRecordPermission { granted in
                    cont.resume(returning: granted)
                }
            }
        }
    }

    func start() async throws {
        let granted = await requestPermission()
        guard granted else { throw RecorderError.permissionDenied }

        // The coordinator owns category + activation so a barge-in or a
        // scheduled-fire player can't deactivate the session mid-record.
        AudioSessionCoordinator.shared.acquire(.record)

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("hv-rec-\(UUID().uuidString).m4a")
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 16_000,                         // Whisper-friendly
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue,
        ]

        do {
            let recorder = try AVAudioRecorder(url: url, settings: settings)
            recorder.delegate = self
            recorder.isMeteringEnabled = true
            guard recorder.record() else {
                throw RecorderError.startFailure(NSError(domain: "VoiceRecorder", code: -1))
            }
            self.recorder = recorder
            self.startedAt = Date()
        } catch {
            // Balance the acquire above before bailing.
            AudioSessionCoordinator.shared.release()
            throw RecorderError.startFailure(error)
        }
    }

    /// Stops recording and returns the file URL with audio.
    func stop() -> URL? {
        guard let recorder else { return nil }
        let url = recorder.url
        recorder.stop()
        if let startedAt {
            lastClipDuration = Date().timeIntervalSince(startedAt)
        }
        self.recorder = nil
        self.startedAt = nil
        AudioSessionCoordinator.shared.release()
        return url
    }

    /// Convenience for cleanup after a successful upload.
    static func discard(_ url: URL?) {
        guard let url else { return }
        try? FileManager.default.removeItem(at: url)
    }
}
