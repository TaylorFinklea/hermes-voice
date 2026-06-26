import Foundation
import AVFoundation

/// On-device text-to-speech via Apple's `AVSpeechSynthesizer` — the reply is
/// spoken on the phone, so there's no ElevenLabs network leg. Apple's synthesizer
/// ships with the OS (no model download) and runs its own mature text normalizer,
/// so numbers, dates, currency, and homographs are verbalized correctly — unlike
/// the previous on-device engine (FluidAudio/Kokoro), whose context-free per-word
/// G2P mispronounced homographs ("is" → "eyes") and dropped digits ("72" → "x").
///
/// We still run `makeSpeakable` first to strip markdown markers (AVSpeech would
/// otherwise read "##" / asterisks / code fences aloud) — that keeps on-device
/// and server TTS reading the same clean prose.
///
/// `@MainActor` for serial access to the synthesizer/continuation state and so
/// `@Published`-free `ObservableObject` conformance drives the Settings UI safely.
@MainActor
final class LocalSpeaker: ObservableObject {
    static let shared = LocalSpeaker()

    /// Apple's on-device voices ship with the OS, so the speaker is always ready
    /// — no download step. Kept as a property because `ConversationModeController`
    /// gates on-device playback on it.
    var isReady: Bool { true }

    /// One curated voice per accent/gender. Ids are *logical* (`<lang>-<gender>`),
    /// resolved at synth time to the best-quality installed `AVSpeechSynthesisVoice`
    /// for that language + gender. Resolution degrades gracefully (gender → any
    /// voice in the language → system default), so a device missing a particular
    /// voice never breaks a turn.
    struct Voice: Identifiable, Hashable {
        let id: String      // logical id, e.g. "en-US-female"
        let label: String
    }
    nonisolated static let defaultVoice = "en-US-female"
    nonisolated static let voices: [Voice] = [
        Voice(id: "en-US-female", label: "US ♀"),
        Voice(id: "en-US-male", label: "US ♂"),
        Voice(id: "en-GB-female", label: "UK ♀"),
        Voice(id: "en-GB-male", label: "UK ♂"),
    ]

    /// Legacy Kokoro voice ids (stored in older installs as `local:af_heart` etc.)
    /// mapped to their logical AVSpeech equivalent, so a saved selection keeps its
    /// intended accent/gender after the engine swap.
    private static let legacyVoiceMap: [String: String] = [
        "af_heart": "en-US-female",
        "am_michael": "en-US-male",
        "bf_emma": "en-GB-female",
        "bm_george": "en-GB-male",
    ]

    private var synthesizer: AVSpeechSynthesizer?
    private var speechDelegate: SpeechDelegate?

    private var speakTask: Task<Void, Never>?
    private var speakContinuation: CheckedContinuation<Void, Error>?

    /// Fire-and-forget narration task (spoken filler). Tracked separately from
    /// `speakTask` so the real reply's `speak()`/`stop()` can hard-cut it, and so
    /// a second `narrate()` can coalesce onto the in-flight one rather than
    /// truncating it mid-word.
    private var narrateTask: Task<Void, Never>?
    /// At most one pending narration. A second `narrate()` while one is still
    /// speaking parks its (cleaned text, resolved voice) here; the in-flight task
    /// plays it when the current utterance finishes. A third overwrites it, so we
    /// keep only the latest — 1-deep coalescing.
    private var pendingNarration: (text: String, voice: AVSpeechSynthesisVoice?)?
    /// The utterance the active continuation is waiting on. The delegate resolves
    /// the continuation only for this exact utterance — `stopSpeaking(.immediate)`
    /// fires `didCancel` asynchronously, and disowning the utterance here prevents
    /// a stale cancel from tearing down the *next* turn's continuation.
    private var currentUtterance: AVSpeechUtterance?

    private init() {
        speechDelegate = SpeechDelegate(
            onFinish: { [weak self] u in self?.resolveSpeak(u, error: nil) },
            onCancel: { [weak self] u in self?.resolveSpeak(u, error: CancellationError()) }
        )
    }

    /// Pre-instantiate the synthesizer so the first spoken reply doesn't pay the
    /// allocation cost. Named for its historical caller; AVSpeech needs no model
    /// download, so this just warms the object.
    func warmUpIfDownloaded() {
        _ = ensureSynthesizer()
    }

    // MARK: - Speaking

    /// Speak `text` on-device. Cancellable via `stop()` (barge-in). Returns when
    /// playback finishes or is cancelled. Failures are swallowed — the reply text
    /// is already on screen.
    func speak(_ text: String, voice: String) async {
        stop()
        // Strip markdown/code so on-device TTS doesn't read "##", asterisks, or
        // code fences aloud. Mirror of backend app/speakable.py make_speakable;
        // shared corpus: backend/tests/fixtures/speakable_cases.json.
        let cleaned = Self.makeSpeakable(text)
        guard !cleaned.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let resolvedVoice = Self.resolveVoice(voice)

        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            AudioSessionCoordinator.shared.acquire(.playback)
            defer { AudioSessionCoordinator.shared.release() }
            do {
                try await self.speakUtterance(cleaned, voice: resolvedVoice)
            } catch is CancellationError {
                // barge-in / stop — expected
            } catch {
                // Reply text is already on screen, so this is non-fatal — but
                // leave a breadcrumb so a "went silent" report has a trail.
                print("[HermesVoice] LocalSpeaker: speech synthesis failed: \(error)")
            }
        }
        speakTask = task
        await task.value
    }

    /// Speak a short spoken filler phrase NON-BLOCKING (fire-and-forget). Mirrors
    /// `speak()`'s session/continuation/voice handling but does NOT await — the
    /// caller dispatches a turn and the filler plays alongside it. The real
    /// reply's `speak()` (and `stop()`) hard-cut any in-flight or queued
    /// narration, so the reply always wins.
    ///
    /// 1-deep coalescing: if a narration is already speaking, the new text is
    /// QUEUED and played when the current one finishes (no mid-word truncation);
    /// a further narration overwrites the queued one, keeping only the latest.
    func narrate(_ text: String, voice: String) {
        // The real reply always wins — never narrate over (or interleave a
        // continuation with) an in-flight `speak()`.
        guard speakTask == nil else { return }
        let cleaned = Self.makeSpeakable(text)
        guard !cleaned.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let resolvedVoice = Self.resolveVoice(voice)

        // Already narrating → queue (1-deep, latest wins) and let the running
        // task pick it up when the current utterance finishes.
        if narrateTask != nil {
            pendingNarration = (cleaned, resolvedVoice)
            return
        }

        startNarration(text: cleaned, voice: resolvedVoice)
    }

    /// Run one narration task that drains the 1-deep queue: speak the given text,
    /// then keep speaking whatever `pendingNarration` holds when each finishes.
    private func startNarration(text: String, voice: AVSpeechSynthesisVoice?) {
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            AudioSessionCoordinator.shared.acquire(.playback)
            defer { AudioSessionCoordinator.shared.release() }
            var next: (text: String, voice: AVSpeechSynthesisVoice?)? = (text, voice)
            while let current = next {
                next = nil
                if Task.isCancelled { break }
                do {
                    try await self.speakUtterance(current.text, voice: current.voice)
                } catch is CancellationError {
                    break  // barge-in / reply took over
                } catch {
                    print("[HermesVoice] LocalSpeaker: narration synthesis failed: \(error)")
                }
                if Task.isCancelled { break }
                // Pick up a phrase queued while this one was speaking (latest wins).
                next = self.pendingNarration
                self.pendingNarration = nil
            }
            self.narrateTask = nil
        }
        narrateTask = task
    }

    /// Stop any in-flight speech immediately (barge-in / cancel). Hard-cuts the
    /// real reply AND any in-flight/queued narration — the reply always wins, so
    /// the narration queue is flushed here too.
    func stop() {
        // Flush narration first so a cancelled utterance can't drain the queue.
        pendingNarration = nil
        narrateTask?.cancel()
        narrateTask = nil
        speakTask?.cancel()
        speakTask = nil
        // Disown before stopping so the resulting didCancel is ignored.
        currentUtterance = nil
        synthesizer?.stopSpeaking(at: .immediate)
        if let cont = speakContinuation {
            speakContinuation = nil
            cont.resume(throwing: CancellationError())
        }
    }

    // MARK: - Helpers

    private func ensureSynthesizer() -> AVSpeechSynthesizer {
        if let synthesizer { return synthesizer }
        let s = AVSpeechSynthesizer()
        s.delegate = speechDelegate
        synthesizer = s
        return s
    }

    /// Speak one utterance and resume when the synthesizer reports finish/cancel.
    /// Resolution is single-owner: both `resolveSpeak(...)` and `stop()` read-and-nil
    /// `speakContinuation` on the main actor, so exactly one resumes it.
    private func speakUtterance(_ text: String, voice: AVSpeechSynthesisVoice?) async throws {
        let synth = ensureSynthesizer()
        let utterance = AVSpeechUtterance(string: text)
        if let voice { utterance.voice = voice }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            if Task.isCancelled {
                cont.resume(throwing: CancellationError())
                return
            }
            speakContinuation = cont
            currentUtterance = utterance
            synth.speak(utterance)
        }
    }

    /// Resolve the active continuation for `utterance` (finish → success, cancel →
    /// CancellationError). Ignores callbacks for a disowned/superseded utterance.
    private func resolveSpeak(_ utterance: AVSpeechUtterance, error: Error?) {
        guard utterance === currentUtterance else { return }
        currentUtterance = nil
        guard let cont = speakContinuation else { return }
        speakContinuation = nil
        if let error { cont.resume(throwing: error) } else { cont.resume() }
    }

    /// Map a stored voice id (logical `<lang>-<gender>` or a legacy Kokoro id) to
    /// the best-quality installed voice. Never crashes — degrades to a
    /// language-only match, then the system default.
    static func resolveVoice(_ id: String) -> AVSpeechSynthesisVoice? {
        let logical = legacyVoiceMap[id] ?? id
        let (language, gender) = parseLogical(logical)
        let installed = AVSpeechSynthesisVoice.speechVoices().filter { $0.language == language }
        func best(_ voices: [AVSpeechSynthesisVoice]) -> AVSpeechSynthesisVoice? {
            voices.max(by: { $0.quality.rawValue < $1.quality.rawValue })
        }
        if let gender {
            // Prefer an exact gender match, then an untagged (.unspecified) voice
            // — which may well be the requested gender — before settling for the
            // other gender. Many system voices report .unspecified, so filtering
            // strictly on gender would silently downgrade e.g. "US ♂" to female.
            if let match = best(installed.filter { $0.gender == gender }) { return match }
            if let match = best(installed.filter { $0.gender == .unspecified }) { return match }
            if let match = best(installed) {
                print("[HermesVoice] LocalSpeaker: no \(gender == .male ? "male" : "female") "
                    + "\(language) voice installed; using \(match.name)")
                return match
            }
        } else if let match = best(installed) {
            return match
        }
        return AVSpeechSynthesisVoice(language: language)
            ?? AVSpeechSynthesisVoice(language: "en-US")
    }

    /// Split a logical id like "en-US-female" into ("en-US", .female). A non-logical
    /// id (no recognizable gender suffix) yields (id, nil) — language-only resolution.
    private static func parseLogical(_ logical: String) -> (String, AVSpeechSynthesisVoiceGender?) {
        let parts = logical.split(separator: "-").map(String.init)
        guard parts.count >= 3 else { return (logical, nil) }
        let language = parts[0] + "-" + parts[1]
        let gender: AVSpeechSynthesisVoiceGender?
        switch parts[2].lowercased() {
        case "female": gender = .female
        case "male": gender = .male
        default: gender = nil
        }
        return (language, gender)
    }

    /// A user-facing note for Settings when the selected on-device voice's
    /// requested gender isn't installed for its accent and resolution will fall
    /// to the opposite gender. Returns nil when the gender is honored, when an
    /// untagged (.unspecified) voice could serve it, or when no gender was
    /// requested — so it fires only on a confirmed opposite-gender downgrade.
    static func unavailableGenderNote(for id: String) -> String? {
        let logical = legacyVoiceMap[id] ?? id
        let (language, gender) = parseLogical(logical)
        guard let gender else { return nil }
        let installed = AVSpeechSynthesisVoice.speechVoices().filter { $0.language == language }
        if installed.contains(where: { $0.gender == gender }) { return nil }
        if installed.contains(where: { $0.gender == .unspecified }) { return nil }
        guard installed.contains(where: { $0.gender != gender }) else { return nil }
        let requested = voices.first(where: { $0.id == logical })?.label ?? logical
        let siblingId = logical.replacingOccurrences(
            of: gender == .male ? "-male" : "-female",
            with: gender == .male ? "-female" : "-male")
        let usingClause = voices.first(where: { $0.id == siblingId }).map { " — using \($0.label)" } ?? ""
        return "\(requested) isn't installed on this device\(usingClause). "
            + "Add it in iOS Settings › Accessibility › Spoken Content › Voices."
    }

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

/// Bridges `AVSpeechSynthesizer`'s delegate callbacks onto the main actor.
private final class SpeechDelegate: NSObject, AVSpeechSynthesizerDelegate {
    private let onFinish: @MainActor (AVSpeechUtterance) -> Void
    private let onCancel: @MainActor (AVSpeechUtterance) -> Void
    init(onFinish: @escaping @MainActor (AVSpeechUtterance) -> Void,
         onCancel: @escaping @MainActor (AVSpeechUtterance) -> Void) {
        self.onFinish = onFinish
        self.onCancel = onCancel
    }
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in onFinish(utterance) }
    }
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in onCancel(utterance) }
    }
}
