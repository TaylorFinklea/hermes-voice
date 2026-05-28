import AVFoundation

/// One-shot AVAudioPlayer for the hermes-chime preamble.
///
/// Synchronous-feeling API for the caller: `await play()` returns when the
/// chime is done. Used before auto-playing a scheduled-fire reply so audio
/// doesn't start mid-conversation without warning.
final class ChimePlayer {
    static let shared = ChimePlayer()

    private var player: AVAudioPlayer?

    private init() {}

    /// Play the bundled chime and await completion. Falls back gracefully
    /// if the asset is missing or the audio session is in use.
    func play() async {
        guard let url = Bundle.main.url(
            forResource: "hermes-chime", withExtension: "caf"
        ) ?? Bundle.main.url(forResource: "hermes-chime", withExtension: "wav") else {
            return
        }

        // Activate playback. Don't switch to playAndRecord — that interferes
        // with any active recording on the conversation flow.
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
        try? AVAudioSession.sharedInstance().setActive(true, options: [])

        do {
            let p = try AVAudioPlayer(contentsOf: url)
            p.prepareToPlay()
            self.player = p
            p.play()
            // Wait for natural end (small buffer beyond duration in case
            // duration reports slightly short).
            let duration = p.duration + 0.05
            try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
            self.player = nil
        } catch {
            // Audio is best-effort — never throw up to the caller.
        }
    }
}
