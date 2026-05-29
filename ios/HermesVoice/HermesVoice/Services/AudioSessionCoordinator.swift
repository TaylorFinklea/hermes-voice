import AVFoundation

/// Single owner of the process-global `AVAudioSession`.
///
/// Before this, `VoiceRecorder`, `AudioPlayer` (instantiated in several places),
/// and `ChimePlayer` each independently called `setCategory` + `setActive(true)`
/// and, worse, `setActive(false)` — so one component could deactivate the
/// session out from under another (barge-in stopping the recorder while a
/// player was mid-flight; a scheduled-fire chime fighting the conversation
/// player). Routing them all through this ref-counted coordinator means the
/// session is deactivated only when the *last* holder releases.
///
/// Usage: balance every `acquire(_:)` with exactly one `release()`.
@MainActor
final class AudioSessionCoordinator {
    static let shared = AudioSessionCoordinator()
    private init() {}

    enum Mode {
        case record    // .playAndRecord — mic capture
        case playback  // .playback — TTS / chime

        fileprivate func apply(to session: AVAudioSession) throws {
            switch self {
            case .record:
                try session.setCategory(.playAndRecord, mode: .spokenAudio,
                                        options: [.defaultToSpeaker, .allowBluetooth])
            case .playback:
                try session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
            }
        }
    }

    private var holders = 0

    /// Configure the session for `mode` and activate it. Best-effort: a session
    /// error is swallowed (audio is non-critical) but the hold still counts so
    /// the acquire/release balance — and thus deactivation timing — stays correct.
    func acquire(_ mode: Mode) {
        let session = AVAudioSession.sharedInstance()
        do {
            try mode.apply(to: session)
            try session.setActive(true, options: [])
        } catch {
            // best-effort — leave the session in whatever state it reached
        }
        holders += 1
    }

    /// Release one hold. When the last holder releases, deactivate the session
    /// (notifying others so e.g. paused music can resume).
    func release() {
        holders = max(0, holders - 1)
        guard holders == 0 else { return }
        try? AVAudioSession.sharedInstance().setActive(
            false, options: [.notifyOthersOnDeactivation]
        )
    }
}
