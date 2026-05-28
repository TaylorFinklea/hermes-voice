import AVFoundation

/// Plays a single audio file on Apple Watch. Uses AVAudioPlayer because the
/// audio is fully buffered by the time it lands on the Watch (iPhone
/// downloads and ships the complete file via WCSession.transferFile).
@MainActor
final class WatchPlayer {
    private var player: AVAudioPlayer?

    func play(url: URL) {
        stop()
        do {
            // .playback (vs .playAndRecord) avoids holding the mic open;
            // Watch speakers route through the system mixer regardless.
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
            try AVAudioSession.sharedInstance().setActive(true, options: [])
            let p = try AVAudioPlayer(contentsOf: url)
            p.prepareToPlay()
            p.play()
            self.player = p
        } catch {
            // Best-effort — silent failure is acceptable since text is
            // already on-screen as the primary signal.
        }
    }

    func stop() {
        player?.stop()
        player = nil
        try? AVAudioSession.sharedInstance().setActive(
            false, options: [.notifyOthersOnDeactivation]
        )
    }
}
