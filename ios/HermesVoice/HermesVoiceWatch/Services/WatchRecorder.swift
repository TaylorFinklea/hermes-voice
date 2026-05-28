import AVFoundation

/// Records microphone audio on Apple Watch to an m4a (AAC) file, matching
/// the iPhone recorder's format so the same backend STT path works.
@MainActor
final class WatchRecorder: NSObject, AVAudioRecorderDelegate {
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

    func requestPermission() async -> Bool {
        await AVAudioApplication.requestRecordPermission()
    }

    func start() async throws {
        let granted = await requestPermission()
        guard granted else { throw RecorderError.permissionDenied }

        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playAndRecord, mode: .spokenAudio, options: [.duckOthers])
            try session.setActive(true, options: [])
        } catch {
            throw RecorderError.sessionFailure(error)
        }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("hv-watch-\(UUID().uuidString).m4a")
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 16_000,        // Whisper-friendly
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue,
        ]

        do {
            let recorder = try AVAudioRecorder(url: url, settings: settings)
            recorder.delegate = self
            guard recorder.record() else {
                throw RecorderError.startFailure(NSError(domain: "WatchRecorder", code: -1))
            }
            self.recorder = recorder
        } catch {
            throw RecorderError.startFailure(error)
        }
    }

    func stop() -> URL? {
        guard let recorder else { return nil }
        let url = recorder.url
        recorder.stop()
        self.recorder = nil
        try? AVAudioSession.sharedInstance().setActive(
            false, options: [.notifyOthersOnDeactivation]
        )
        return url
    }
}
