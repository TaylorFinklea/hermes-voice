import Foundation
import AVFoundation
import FluidAudio

/// On-device text-to-speech via Kokoro (Neural Engine) through FluidAudio —
/// the reply is spoken on the phone, so there's no ElevenLabs network leg.
/// Mirrors `LocalTranscriber`: download/cache the model set once, keep a warm
/// `KokoroAneManager`, and synthesize on demand.
///
/// Playback is **sentence-chunked**: we synthesize the next sentence while the
/// current one plays, so the first words start within a beat even on a long
/// reply. Kokoro runs faster-than-realtime on the ANE, so synthesis stays ahead
/// of playback.
///
/// `@MainActor` for the same reasons as `LocalTranscriber`: serial access to the
/// player/continuation state and `@Published state` driving the Settings UI.
@MainActor
final class LocalSpeaker: ObservableObject {
    static let shared = LocalSpeaker()

    enum ModelState: Equatable {
        case notDownloaded
        case downloading
        case ready
        case failed(String)
    }

    @Published private(set) var state: ModelState = .notDownloaded

    var isReady: Bool { state == .ready }

    /// One curated voice per accent/gender. `af_heart` is Kokoro's default and
    /// is guaranteed present; the others are standard Kokoro voices. If a
    /// selected voice ever fails to synthesize we fall back to `af_heart`, so a
    /// missing pack degrades gracefully rather than breaking a turn.
    struct Voice: Identifiable, Hashable {
        let id: String      // Kokoro voice name, e.g. "af_heart"
        let label: String
    }
    static let defaultVoice = "af_heart"
    static let voices: [Voice] = [
        Voice(id: "af_heart", label: "Heart · US ♀"),
        Voice(id: "am_michael", label: "Michael · US ♂"),
        Voice(id: "bf_emma", label: "Emma · UK ♀"),
        Voice(id: "bm_george", label: "George · UK ♂"),
    ]

    private var manager: KokoroAneManager?
    private var loadTask: Task<KokoroAneManager, Error>?

    private var speakTask: Task<Void, Never>?
    private var currentPlayer: AVAudioPlayer?
    private var playContinuation: CheckedContinuation<Void, Error>?
    private var finishDelegate: PlayerFinishDelegate?

    private init() {
        if UserDefaults.standard.bool(forKey: Self.downloadedKey) {
            state = .ready
        }
        finishDelegate = PlayerFinishDelegate { [weak self] in self?.finishPlay() }
    }

    // MARK: - Model lifecycle

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

    /// Warm the model in the background if it's already downloaded, so the first
    /// spoken reply doesn't pay the load cost. No-op otherwise.
    func warmUpIfDownloaded() {
        guard isReady, manager == nil, loadTask == nil else { return }
        Task { [weak self] in _ = try? await self?.ensureManager() }
    }

    // MARK: - Speaking

    /// Speak `text` on-device, sentence by sentence. Cancellable via `stop()`
    /// (barge-in). Returns when playback finishes or is cancelled. Failures are
    /// swallowed — the reply text is already on screen.
    func speak(_ text: String, voice: String) async {
        stop()
        // Strip markdown/code so on-device TTS (the tts=none path, where the
        // backend never sees the text) doesn't read "##", asterisks, or code
        // fences aloud. Mirror of backend app/speakable.py make_speakable;
        // shared corpus: backend/tests/fixtures/speakable_cases.json.
        let sentences = Self.splitIntoSentences(Self.makeSpeakable(text))
        guard !sentences.isEmpty else { return }

        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            AudioSessionCoordinator.shared.acquire(.playback)
            defer { AudioSessionCoordinator.shared.release() }
            do {
                let manager = try await self.ensureManager()
                var useVoice = voice
                // Prefetch the next sentence while the current one plays.
                var nextSynth = self.synth(manager, sentences[0], voice: useVoice)
                for i in sentences.indices {
                    var wav: Data
                    do {
                        wav = try await nextSynth.value
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        // Selected voice failed (e.g. not in the pack) — fall
                        // back to the default and retry this sentence once.
                        guard useVoice != Self.defaultVoice else { throw error }
                        useVoice = Self.defaultVoice
                        wav = try await self.synth(manager, sentences[i], voice: useVoice).value
                    }
                    try Task.checkCancellation()
                    if i + 1 < sentences.count {
                        nextSynth = self.synth(manager, sentences[i + 1], voice: useVoice)
                    }
                    try await self.play(wav)
                    try Task.checkCancellation()
                }
            } catch is CancellationError {
                // barge-in / stop — expected
            } catch {
                // synthesis or playback failed; nothing to play
            }
        }
        speakTask = task
        await task.value
    }

    /// Stop any in-flight speech immediately (barge-in / cancel).
    func stop() {
        speakTask?.cancel()
        speakTask = nil
        currentPlayer?.stop()
        currentPlayer = nil
        if let cont = playContinuation {
            playContinuation = nil
            cont.resume(throwing: CancellationError())
        }
    }

    // MARK: - Helpers

    private func synth(_ manager: KokoroAneManager, _ text: String, voice: String) -> Task<Data, Error> {
        Task { try await manager.synthesize(text: text, voice: voice, speed: 1.0) }
    }

    /// Play one WAV blob and resume when it finishes. `stop()` resumes the
    /// continuation with `CancellationError`. Resolution is single-owner: both
    /// `finishPlay()` and `stop()` read-and-nil `playContinuation`, and both run
    /// on the main actor, so exactly one resumes it.
    private func play(_ wav: Data) async throws {
        let player = try AVAudioPlayer(data: wav)
        player.delegate = finishDelegate
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            if Task.isCancelled {
                cont.resume(throwing: CancellationError())
                return
            }
            currentPlayer = player
            playContinuation = cont
            if !player.play() {
                playContinuation = nil
                cont.resume(throwing: SpeakerError.playbackFailed)
            }
        }
    }

    private func finishPlay() {
        currentPlayer = nil
        guard let cont = playContinuation else { return }
        playContinuation = nil
        cont.resume()
    }

    private func ensureManager() async throws -> KokoroAneManager {
        if let manager { return manager }
        if let loadTask { return try await loadTask.value }
        let task = Task { () throws -> KokoroAneManager in
            let m = KokoroAneManager(variant: .english, defaultVoice: Self.defaultVoice)
            try await m.initialize()
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

    /// Pragmatic sentence splitter: break on `.?!`/newline, but only when the
    /// chunk is long enough that we're not fragmenting on "e.g." / "1.". The
    /// trailing remainder is its own chunk. Tunable; good enough for v1.
    static func splitIntoSentences(_ text: String) -> [String] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        var sentences: [String] = []
        var current = ""
        var sinceBreak = 0
        for ch in trimmed {
            current.append(ch)
            sinceBreak += 1
            if ch == "." || ch == "!" || ch == "?" || ch == "\n" {
                if sinceBreak >= 12 {
                    let s = current.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !s.isEmpty { sentences.append(s) }
                    current = ""
                    sinceBreak = 0
                }
            }
        }
        let tail = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !tail.isEmpty {
            if tail.count < 12, let last = sentences.popLast() {
                sentences.append(last + " " + tail)   // merge a tiny trailing fragment
            } else {
                sentences.append(tail)
            }
        }
        return sentences
    }

    enum SpeakerError: Error { case playbackFailed }

    private static let downloadedKey = "hv.kokoroDownloaded"

    // MARK: - Speakable text (markdown -> spoken prose)

    /// Spoken in place of a fenced code block. Mirrors `CODE_PLACEHOLDER` in
    /// backend/app/speakable.py.
    static let speakableCodePlaceholder = "(code shown on screen)"

    /// Strip markdown/code formatting so TTS reads natural prose. Deterministic
    /// mirror of backend `make_speakable` (same ordered rules + the shared
    /// fixture corpus in backend/tests/fixtures/speakable_cases.json). Idempotent.
    static func makeSpeakable(_ text: String) -> String {
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return text }
        let lines = dropCodeFences(text.components(separatedBy: "\n"))
        var cleaned: [String] = []
        for rawLine in lines {
            var line = rawLine
            // Horizontal rule / table separator rows -> dropped.
            if reMatches(#"^\s*([-*_])(?:\s*\1){2,}\s*$"#, line) { continue }
            if reMatches(#"^\s*\|?\s*:?-{1,}:?\s*(\|\s*:?-{1,}:?\s*)+\|?\s*$"#, line) { continue }
            line = reReplace(#"^\s*#{1,6}\s+"#, "", line)   // heading marker
            line = reReplace(#"^\s*>\s?"#, "", line)        // blockquote
            line = reReplace(#"^\s*[-*+]\s+"#, "", line)    // bullet marker
            line = reReplace(#"^\s*\d+[.)]\s+"#, "", line)  // numbered marker
            // Table data row -> comma-separated clause.
            if line.filter({ $0 == "|" }).count >= 2 {
                // .whitespacesAndNewlines (not .whitespaces) so a CRLF row's
                // trailing \r is stripped like Python str.strip() — otherwise a
                // phantom trailing cell + stray CR diverge from make_speakable.
                let body = line.trimmingCharacters(in: .whitespacesAndNewlines)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "|"))
                let cells = body.components(separatedBy: "|")
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                line = cells.joined(separator: ", ")
            }
            cleaned.append(stripInlineMarkdown(line))
        }
        var out = cleaned.joined(separator: "\n")
        out = reReplace(#"\n{3,}"#, "\n\n", out)
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Replace each *closed* fenced code block with a placeholder. An unclosed
    /// fence is treated as ordinary text (marker dropped) so a malformed reply
    /// never loses its tail.
    private static func dropCodeFences(_ lines: [String]) -> [String] {
        let fence = #"^\s*(?:`{3,}|~{3,})"#
        var out: [String] = []
        var i = 0
        let n = lines.count
        while i < n {
            if !reMatches(fence, lines[i]) {
                out.append(lines[i]); i += 1; continue
            }
            var j = i + 1
            while j < n, !reMatches(fence, lines[j]) { j += 1 }
            if j < n {
                out.append(speakableCodePlaceholder)
                i = j + 1
            } else {
                i += 1
            }
        }
        return out
    }

    private static func stripInlineMarkdown(_ s: String) -> String {
        var line = s
        line = reReplace(#"!\[([^\]]*)\]\([^)]*\)"#, "$1", line)          // image
        line = reReplace(#"\[([^\]]+)\]\([^)]*\)"#, "$1", line)           // link
        line = reReplace(#"<((?:https?://|mailto:)[^>]+)>"#, "$1", line)  // autolink
        line = reReplace(#"`+([^`]+)`+"#, "$1", line)                     // inline code
        line = reReplace(#"\*\*([^*]+)\*\*"#, "$1", line)                 // bold *
        line = reReplace(#"__([^_]+)__"#, "$1", line)                     // bold _
        line = reReplace(#"~~([^~]+)~~"#, "$1", line)                     // strikethrough
        line = reReplace(#"(?<![\w*])\*([^*\n]+)\*(?![\w*])"#, "$1", line)  // italic *
        line = reReplace(#"(?<![\w_])_([^_\n]+)_(?![\w_])"#, "$1", line)    // italic _
        return line
    }

    private static func reReplace(_ pattern: String, _ template: String, _ s: String) -> String {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return s }
        let range = NSRange(s.startIndex..., in: s)
        return re.stringByReplacingMatches(in: s, options: [], range: range, withTemplate: template)
    }

    private static func reMatches(_ pattern: String, _ s: String) -> Bool {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return false }
        return re.firstMatch(in: s, options: [], range: NSRange(s.startIndex..., in: s)) != nil
    }
}

/// Bridges `AVAudioPlayer`'s delegate callback onto the main actor.
private final class PlayerFinishDelegate: NSObject, AVAudioPlayerDelegate {
    private let onFinish: @MainActor () -> Void
    init(onFinish: @escaping @MainActor () -> Void) { self.onFinish = onFinish }
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in onFinish() }
    }
    func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        Task { @MainActor in onFinish() }
    }
}
