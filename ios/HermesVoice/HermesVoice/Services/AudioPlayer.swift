import AVFoundation

/// Streams audio from a URL — plays as bytes arrive instead of waiting for
/// the full file to download. Powers the perceived-speed win from
/// ElevenLabs' streaming TTS endpoint.
///
/// Why AVPlayer not AVAudioPlayer: AVAudioPlayer requires a complete file
/// or in-memory buffer. AVPlayer (via AVURLAsset) supports progressive HTTP
/// download with chunked transfer encoding, which is what our backend serves.
@MainActor
final class AudioPlayer: NSObject {
    private var player: AVPlayer?
    private var endObserver: NSObjectProtocol?
    private var statusObserver: NSKeyValueObservation?
    private var continuation: CheckedContinuation<Void, Never>?

    /// Plays the given URL until completion or stop().
    /// Returns when playback ends (naturally or via stop()).
    func play(url: URL, authToken: String) async {
        stop()

        do {
            try AVAudioSession.sharedInstance().setCategory(
                .playback, mode: .spokenAudio, options: [.duckOthers]
            )
            try AVAudioSession.sharedInstance().setActive(true, options: [])
        } catch {
            return
        }

        // Auth token rides as an HTTP header so the backend's token gate
        // applies to streaming audio fetches too.
        var headers: [String: String] = [:]
        if !authToken.isEmpty { headers["X-Hermes-Voice-Token"] = authToken }
        let asset = AVURLAsset(
            url: url,
            options: ["AVURLAssetHTTPHeaderFieldsKey": headers]
        )
        let item = AVPlayerItem(asset: asset)
        let player = AVPlayer(playerItem: item)
        player.automaticallyWaitsToMinimizeStalling = true
        self.player = player

        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            self.continuation = cont

            endObserver = NotificationCenter.default.addObserver(
                forName: .AVPlayerItemDidPlayToEndTime,
                object: item,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.finish() }
            }

            // Also watch for failures — playback errors should release the
            // continuation, not hang the UI in 'speaking' state forever.
            statusObserver = item.observe(\.status, options: [.new]) { [weak self] item, _ in
                if item.status == .failed {
                    Task { @MainActor in self?.finish() }
                }
            }

            player.play()
        }
    }

    func stop() {
        player?.pause()
        player = nil
        if let obs = endObserver {
            NotificationCenter.default.removeObserver(obs)
            endObserver = nil
        }
        statusObserver?.invalidate()
        statusObserver = nil
        finish()
        try? AVAudioSession.sharedInstance().setActive(
            false, options: [.notifyOthersOnDeactivation]
        )
    }

    private func finish() {
        if let cont = continuation {
            continuation = nil
            cont.resume()
        }
    }
}
