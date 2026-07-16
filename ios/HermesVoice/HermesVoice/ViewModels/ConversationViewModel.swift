import Foundation
import SwiftUI

/// Drives the whole turn lifecycle: record → upload → display → play.
@MainActor
final class ConversationViewModel: ObservableObject {
    enum State: Equatable {
        case idle
        case recording
        case sending          // STT upload or text POST
        case thinking         // waiting for hermes
        case speaking
        case error(String)

        var label: String {
            switch self {
            case .idle: return "Ready"
            case .recording: return "Recording…"
            case .sending: return "Sending…"
            case .thinking: return "Thinking…"
            case .speaking: return "Speaking…"
            case .error(let msg): return "Error: \(msg)"
            }
        }
    }

    /// Sub-state of `.sending` exposed for the pipeline-step UI.
    /// `.transcribing` = on-device STT is running (nothing uploaded); `.uploading`
    /// / `.processing` = the audio-upload path (request in flight, then waiting
    /// on the server). The on-device path jumps straight to `.thinking` the
    /// instant the local transcript lands.
    enum SendingPhase: Equatable { case transcribing, uploading, processing }

    @Published private(set) var state: State = .idle {
        didSet {
            guard state != oldValue else { return }
            syncLiveActivity()
        }
    }
    @Published private(set) var messages: [Message] = []
    @Published private(set) var sessionId: String? = nil

    /// When attached to an existing coding-agent session, the repo we're driving
    /// and whether it's read-only. Drives the header affordance so you always
    /// know what voice is pointed at. Cleared by `reset()`.
    @Published private(set) var attachedRepo: String? = nil
    @Published private(set) var attachedReadOnly: Bool = false

    // Phase B: a pending voice-approval ("Claude wants to edit X — yes/no") or a
    // structured question the agent asked. The turn is paused until answered.
    struct PendingApproval: Equatable {
        let turnId: String
        let requestId: String
        let title: String
        let preview: String
    }
    struct PendingQuestion: Equatable {
        let turnId: String
        let requestId: String
        let prompt: String
        let options: [String]
        let multi: Bool
    }
    @Published private(set) var pendingApproval: PendingApproval?
    @Published private(set) var pendingQuestion: PendingQuestion?
    private var currentTurnId: String?

    /// "write" only for an attached coding session put in write mode — routes the
    /// turn through the SDK approval path (writes pause for a voice yes/no).
    /// Otherwise nil (read-only attach / normal turns).
    private var currentMode: String? {
        (attachedRepo != nil && !attachedReadOnly) ? "write" : nil
    }
    @Published private(set) var sendingPhase: SendingPhase = .uploading
    @Published private(set) var lastClipDuration: TimeInterval? = nil

    /// Live elapsed seconds while recording. The recorder is the source of
    /// truth; views poll this on a timer.
    var elapsedRecordingTime: TimeInterval { recorder.elapsed ?? 0 }

    /// Live normalized mic level (0…1) while recording, for the push-to-talk
    /// waveform. Views poll this on a timer.
    var currentInputLevel: Float { recorder.currentLevel() }

    /// Most recent user-side text in the transcript (or nil).
    var lastUserText: String? {
        messages.last(where: { $0.role == .user })?.text
    }

    /// Most recent assistant-side text in the transcript (or nil).
    var lastAssistantText: String? {
        messages.last(where: { $0.role == .assistant })?.text
    }

    /// Tool-call messages emitted by the most recent turn — i.e. all
    /// tool-call rows that appear AFTER the latest user message.
    var toolCalls: [Message] {
        guard let lastUserIdx = messages.lastIndex(where: { $0.role == .user }) else {
            return []
        }
        return messages[lastUserIdx...].filter { $0.role == .toolCall }
    }

    private let settings: AppSettings
    private let recorder = VoiceRecorder()
    private let player = AudioPlayer()
    private var currentTurn: Task<Void, Never>? = nil

    /// One instant on-device ack per turn. Set when the turn is dispatched (the
    /// .thinking flip) so `sendText` flowing into `consumeTurn`'s `.transcribed`
    /// arm can't double-fire. Reset whenever a fresh turn begins.
    private var didAckThisTurn = false

    /// `chatty` verbosity only: a periodic "still working on it" heartbeat spoken
    /// during long silent gaps in a turn. Started at turn dispatch (alongside the
    /// ack) and cancelled at EVERY turn-end path (completion, error, cancel,
    /// barge-in, and before the hands-free loop re-arms) so it never speaks after
    /// the real reply begins or leaks into the next turn. Reuses
    /// `LocalSpeaker.narrate()`, so the reply's `speak()`/`stop()` hard-cuts it.
    private var heartbeatTask: Task<Void, Never>? = nil

    /// When ANY filler (ack / narrate / heartbeat) was last spoken, so the
    /// heartbeat fires only after a real silent gap — not right after a tool
    /// narration. Updated by `noteFillerSpoken()`.
    private var lastFillerSpokenAt: Date = .distantPast

    /// Idle gap before the chatty heartbeat speaks again.
    private static let heartbeatGap: TimeInterval = 9

    // Phase B: voice answers. A dedicated capture engine (separate from the
    // push-to-talk recorder + the mic button, which stays barge-in/cancel) auto-
    // listens for a spoken yes/no/option while an approval/question card is up.
    private let answerCapture = ConversationCaptureEngine()
    private var answerTask: Task<Void, Never>? = nil
    /// True while listening for a spoken answer — drives the card's mic affordance.
    @Published private(set) var listeningForAnswer = false

    /// Injected backend seam. `nil` in production → `api` builds a concrete
    /// `HermesVoiceAPI` from live settings (unchanged behavior); tests pass a
    /// fake `TurnTransport` to drive the turn state machine deterministically.
    private let transport: TurnTransport?

    init(settings: AppSettings, transport: TurnTransport? = nil) {
        self.settings = settings
        self.transport = transport
    }

    private var api: TurnTransport {
        transport ?? HermesVoiceAPI(baseURL: settings.backendURL, authToken: settings.authToken)
    }

    // MARK: - Public actions

    func startRecording() async {
        guard state == .idle || isError(state) else { return }
        do {
            try await recorder.start()
            state = .recording
        } catch {
            state = .error(error.localizedDescription)
        }
    }

    /// Barge-in entry point. Cuts off whatever Hermes is doing (speaking,
    /// thinking, or sending) and starts a fresh recording. NO-OPs while
    /// we're already recording — release-and-send is handled separately.
    func userPressedMic() async {
        switch state {
        case .recording:
            return  // already recording; ignore press, gesture handles release
        case .speaking:
            player.stop()
            stopHeartbeat()
            LocalSpeaker.shared.stop()   // also cut on-device TTS playback
            // Brief yield so the audio session deactivates before we
            // re-activate it for recording. Without this, .playAndRecord
            // can sometimes inherit dirty state from the prior .playback session.
            try? await Task.sleep(nanoseconds: 50_000_000)
            await startRecording()
        case .thinking, .sending:
            // Cancel the in-flight turn and drop to .idle BEFORE startRecording()
            // — its guard only proceeds from .idle/.error, so without this the
            // barge-in was silently swallowed and the UI stuck on Sending/Thinking
            // (the .speaking arm gets to .idle implicitly via player.stop()→handle).
            // The cancelled turn's task unwinds via CancellationError without
            // touching state, so it can't clobber the new recording.
            currentTurn?.cancel()
            currentTurn = nil
            // Cut any spoken filler (instant ack / tool narration / heartbeat) so
            // Hermes isn't still talking over the user's new recording.
            stopHeartbeat()
            LocalSpeaker.shared.stop()
            state = .idle
            await startRecording()
        case .idle, .error:
            await startRecording()
        }
    }

    func stopRecordingAndSend() async {
        guard state == .recording else { return }
        guard let url = recorder.stop() else {
            state = .error("No audio captured.")
            return
        }
        lastClipDuration = recorder.lastClipDuration

        // On-device transcription turns an audio turn into a text turn: if the
        // parakeet model is ready, we transcribe locally (audio never leaves the
        // phone) and run the normal text-stream path. Anything that goes wrong —
        // disabled, model not ready, or transcription throws — falls back to the
        // audio-upload path with the same clip, so there's no regression.
        let useLocal = settings.useOnDeviceSTT && LocalTranscriber.shared.isReady
        sendingPhase = useLocal ? .transcribing : .uploading
        didAckThisTurn = false
        state = .sending

        let api = self.api
        let currentSession = sessionId
        let voiceId = settings.serverVoiceId
        let ttsMode: String? = settings.isLocalVoiceSelected ? "none" : nil
        let harnessId = settings.selectedHarness
        let modeId = currentMode
        let task = Task { @MainActor [weak self] in
            guard let self else { return }

            if useLocal {
                do {
                    let text = try await LocalTranscriber.shared.transcribe(audioFileURL: url)
                    VoiceRecorder.discard(url)
                    try Task.checkCancellation()
                    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { self.state = .idle; return }  // heard nothing
                    self.messages.append(Message(role: .user, text: trimmed))
                    self.state = .thinking
                    self.fireInstantAckIfNeeded()
                    await self.streamTextTurnBody(trimmed, sessionId: currentSession, voiceId: voiceId, tts: ttsMode, harness: harnessId, mode: modeId)
                    return
                } catch is CancellationError {
                    VoiceRecorder.discard(url)
                    return
                } catch {
                    // Local transcription failed → fall through to upload using
                    // the same clip (still on disk). If we were cancelled, bail.
                    if Task.isCancelled { VoiceRecorder.discard(url); return }
                    self.sendingPhase = .uploading
                }
            }

            // Audio-upload path (default, and the on-device fallback).
            // Bump to "processing" after a short upload window so the pipeline
            // UI doesn't sit on "uploading" the whole time.
            let phaseFlip = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 500_000_000)
                if let self, self.state == .sending { self.sendingPhase = .processing }
            }
            defer { phaseFlip.cancel() }
            do {
                try await self.consumeTurn(
                    api.streamAudio(
                        fileURL: url, mimeType: "audio/m4a",
                        sessionId: currentSession, voiceId: voiceId, tts: ttsMode, harness: harnessId, mode: modeId
                    ),
                    appendUserFromTranscribed: true
                )
                VoiceRecorder.discard(url)
            } catch is CancellationError {
                VoiceRecorder.discard(url)  // user interrupted; drop their audio
            } catch let HermesVoiceAPI.APIError.httpStatus(code, _) where code == 404 || code == 405 {
                // Streaming endpoint genuinely MISSING (older backend) — the turn
                // never ran, so re-running it single-shot is safe. Any other status
                // (502/503/422/401…) means the turn may have already executed; fall
                // through to a loud failure rather than silently re-firing a write.
                print("[HermesVoice] /api/audio/stream \(code) → single-shot fallback")
                // A cancelled/switched-away turn must not re-POST the old audio:
                // `api` resolves from the CURRENT active profile, so without this
                // guard a turn cancelled by switchBackend could fire the fallback
                // against the NEW backend.
                guard !Task.isCancelled else { VoiceRecorder.discard(url); return }
                await self.sendAudioFallback(url: url, sessionId: currentSession, voiceId: voiceId, tts: ttsMode, harness: harnessId)
            } catch {
                VoiceRecorder.discard(url)
                if !Task.isCancelled {
                    // Don't downgrade a turn whose reply already arrived (a late
                    // transport drop after the assistant text) into an error.
                    if self.currentTurnHasAssistantReply() {
                        if self.state == .thinking || self.state == .sending { self.state = .idle }
                    } else {
                        self.failTurn(error)
                    }
                }
            }
        }
        currentTurn = task
        await task.value
    }

    func sendText(_ text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        messages.append(Message(role: .user, text: trimmed))
        didAckThisTurn = false
        state = .thinking
        fireInstantAckIfNeeded()

        let currentSession = sessionId
        let voiceId = settings.serverVoiceId
        let ttsMode: String? = settings.isLocalVoiceSelected ? "none" : nil
        let harnessId = settings.selectedHarness
        let modeId = currentMode
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.streamTextTurnBody(trimmed, sessionId: currentSession, voiceId: voiceId, tts: ttsMode, harness: harnessId, mode: modeId)
        }
        currentTurn = task
        await task.value
    }

    /// Streams a text turn and commits it to the transcript. Shared by typed
    /// text (`sendText`) and on-device-transcribed audio (`stopRecordingAndSend`).
    /// Does NOT create its own Task — the caller owns `currentTurn` so barge-in
    /// cancels the right thing. Falls back to a single-shot text POST if the
    /// streaming endpoint is unavailable; swallows cancellation.
    private func streamTextTurnBody(_ trimmed: String, sessionId: String?, voiceId: String, tts: String?, harness: String?, mode: String?) async {
        do {
            try await consumeTurn(
                api.streamText(trimmed, sessionId: sessionId, voiceId: voiceId, tts: tts, harness: harness, mode: mode),
                appendUserFromTranscribed: false
            )
        } catch is CancellationError {
            // user barged in; userPressedMic already moved us to recording
        } catch let HermesVoiceAPI.APIError.httpStatus(code, _) where code == 404 || code == 405 {
            // Streaming endpoint missing (older backend) — turn never ran, so a
            // single-shot retry is safe. Other statuses fall through to the
            // recover-or-fail path below (never silently re-fire a maybe-run turn).
            print("[HermesVoice] /api/text/stream \(code) → single-shot fallback")
            // A cancelled/switched-away turn must not re-POST the old prompt:
            // `api` resolves from the CURRENT active profile, so without this
            // guard a turn cancelled by switchBackend could fire the fallback
            // against the NEW backend.
            guard !Task.isCancelled else { return }
            await sendTextFallback(trimmed, sessionId: sessionId, voiceId: voiceId, tts: tts, harness: harness)
        } catch {
            if !Task.isCancelled {
                // A late transport drop AFTER the assistant reply was already
                // streamed in shouldn't surface as an error — the turn is
                // visibly complete. Otherwise try to backfill from History, and
                // only fail the turn if nothing was actually surfaced.
                if currentTurnHasAssistantReply() {
                    if state == .thinking || state == .sending { state = .idle }
                } else {
                    let recovered = await recoverMissingAssistantFromHistory(
                        sessionId: sessionId,
                        turnUserText: trimmed
                    )
                    // Re-check cancellation after the recovery await: a turn
                    // cancelled by switchBackend mid-recovery must not paint a
                    // NEW turn's state red via failTurn.
                    if !recovered, !Task.isCancelled { failTurn(error) }
                }
            }
        }
    }

    /// Consume an SSE turn stream, updating the transcript + state live.
    /// Tool chips appear as Hermes works; the `tools` event then replaces the
    /// live (best-effort) chips with the authoritative list, and `assistant` /
    /// `audio` commit the reply + start progressive playback.
    private func consumeTurn(
        _ stream: AsyncThrowingStream<HermesVoiceAPI.TurnEvent, Error>,
        appendUserFromTranscribed: Bool
    ) async throws {
        var turnToolIDs: [UUID] = []
        var sawAssistant = false
        var finalSessionId = sessionId
        var turnUserText = lastUserText
        for try await ev in stream {
            try Task.checkCancellation()
            switch ev {
            case .transcribed(let t):
                if appendUserFromTranscribed {
                    messages.append(Message(role: .user, text: t))
                    // Anchor any later History recovery on THIS turn's user
                    // text; `lastUserText` captured above is the prior turn for
                    // audio-upload turns (the user msg is appended here,
                    // mid-stream, not before consumeTurn).
                    turnUserText = t
                }
                // STT done; Hermes is working — move to the thinking pane so the
                // live tool chips show (audio turns start in .sending).
                if state == .sending {
                    state = .thinking
                    // Audio-upload path: the user text just landed, so this is
                    // the turn's dispatch moment — fire the instant ack here.
                    fireInstantAckIfNeeded()
                }
            case .narrate(let text):
                // Backend-authored spoken tool filler ("Checking the weather…").
                // On-device path only (tts=none) — speak it on the phone,
                // non-blocking; the real reply hard-cuts it. Gated by verbosity:
                // per-tool narration is `normal`+ only (`off`/`quiet` ignore it).
                if settings.isLocalVoiceSelected, settings.fillerVerbosity >= .normal {
                    LocalSpeaker.shared.narrate(text, voice: settings.localVoiceName)
                    noteFillerSpoken()
                }
            case .tool(let name, let preview, let ok):
                let m = Message(
                    role: .toolCall, text: "\(name): \(preview)",
                    toolCall: ToolCallDetail(name: name, preview: preview, ok: ok)
                )
                messages.append(m)
                turnToolIDs.append(m.id)
            case .tools(let items):
                // Authoritative list — swap out the live best-effort chips.
                messages.removeAll { turnToolIDs.contains($0.id) }
                turnToolIDs.removeAll()
                for tc in items {
                    let m = Message(
                        role: .toolCall, text: "\(tc.name): \(tc.preview)",
                        toolCall: ToolCallDetail(name: tc.name, preview: tc.preview, ok: tc.ok)
                    )
                    messages.append(m)
                    turnToolIDs.append(m.id)
                }
            case .assistant(let txt, let sid):
                sawAssistant = true
                if !sid.isEmpty { sessionId = sid }
                finalSessionId = sid.isEmpty ? finalSessionId : sid
                messages.append(Message(role: .assistant, text: txt))
                settings.markReachable()
                // Real reply is here — kill the chatty heartbeat before it can
                // speak over (or right after) the reply.
                stopHeartbeat()
                // On-device TTS: the backend was told tts=none and won't emit an
                // `audio` event, so synthesize + speak the reply here on the phone.
                if settings.isLocalVoiceSelected {
                    state = .speaking
                    await LocalSpeaker.shared.speak(txt, voice: settings.localVoiceName)
                    if state == .speaking { state = .idle }
                }
            case .audio(let path):
                // Ignore any server audio while a local voice is active (defensive —
                // tts=none means it normally won't arrive).
                if settings.isLocalVoiceSelected { break }
                guard let audioURL = api.makeURL(path: path) else { break }
                state = .speaking
                await player.play(url: audioURL, authToken: settings.authToken)
                state = .idle
            case .done(let sid):
                if !sid.isEmpty {
                    sessionId = sid
                    finalSessionId = sid
                }
                if state != .speaking { state = .idle }
            case .failed(let detail):
                // Don't paint a turn red if its reply already arrived — a server
                // error AFTER the assistant text is a downstream (TTS/audit)
                // failure, not a failed turn.
                stopHeartbeat()
                if sawAssistant {
                    if state == .thinking || state == .sending { state = .idle }
                } else {
                    state = .error(detail)
                }
                return
            case .turn(let id):
                currentTurnId = id.isEmpty ? nil : id
            case .approvalRequest(let reqId, _, let title, let preview):
                if let tid = currentTurnId {
                    pendingApproval = PendingApproval(
                        turnId: tid, requestId: reqId, title: title, preview: preview
                    )
                    presentPending(spoken: title)
                }
            case .question(let reqId, let prompt, let options, let multi):
                if let tid = currentTurnId {
                    pendingQuestion = PendingQuestion(
                        turnId: tid, requestId: reqId, prompt: prompt,
                        options: options, multi: multi
                    )
                    presentPending(spoken: prompt)
                }
            }
        }
        // Stream ended — no more filler is coming, so stop the chatty heartbeat
        // before the recovery / idle settle (it's also stopped on the `.assistant`
        // and `.failed` arms above, but a clean no-reply close exits here).
        stopHeartbeat()
        if !sawAssistant,
           let sid = finalSessionId,
           await recoverMissingAssistantFromHistory(sessionId: sid, turnUserText: turnUserText) {
            return
        }
        // Stream ended cleanly with no audio leg (e.g. TTS disabled).
        // Guard on cancellation: a turn cancelled mid-recovery (e.g.
        // switchBackend cancelled this task while the History await above was
        // in flight) must NOT settle a NEW turn's `.thinking` back to `.idle`.
        if !Task.isCancelled, state == .thinking || state == .sending { state = .idle }
    }

    /// Defensive recovery for a real-world stream edge case: Hermes can finish
    /// the turn and persist the assistant reply, while the phone misses the
    /// final `assistant` event. Pull the just-finished turn from History so the
    /// user sees the answer in the live pane instead of only after opening
    /// History.
    /// Returns true only when a reply was surfaced. Skips (returns false) only if
    /// THIS turn already shows an assistant reply — anchored on position, not
    /// global text equality, so identical short confirmations ("Done."/"Saved.")
    /// across turns still recover instead of being mistaken for duplicates.
    private func recoverMissingAssistantFromHistory(
        sessionId: String?,
        turnUserText: String?
    ) async -> Bool {
        // This recovery path can reach here via a thrown stream (consumeTurn's
        // tail stop was skipped), so kill the chatty heartbeat before it might
        // speak the recovered reply.
        stopHeartbeat()
        guard let sessionId, !sessionId.isEmpty, !Task.isCancelled else { return false }
        do {
            let detail = try await api.getSession(id: sessionId)
            guard !Task.isCancelled else { return false }
            guard let assistantText = latestAssistantText(
                in: detail.messages,
                afterUserText: turnUserText
            ) else {
                return false
            }
            // Anchor on POSITION, not global text: only skip if THIS turn already
            // surfaced a reply. Identical short confirmations ("Done." / "Saved.")
            // across turns are legitimate and must still recover.
            guard !currentTurnHasAssistantReply() else {
                return false
            }
            messages.append(Message(role: .assistant, text: assistantText))
            settings.markReachable()
            if settings.isLocalVoiceSelected {
                state = .speaking
                await LocalSpeaker.shared.speak(assistantText, voice: settings.localVoiceName)
                if state == .speaking { state = .idle }
            } else if state == .thinking || state == .sending {
                state = .idle
            }
            return true
        } catch {
            return false
        }
    }

    /// True when the in-flight turn has already shown an assistant reply (an
    /// assistant message after the latest user message). Lets the caller skip
    /// surfacing an error for a late stream drop that arrived after the reply
    /// was already streamed in.
    private func currentTurnHasAssistantReply() -> Bool {
        guard let lastUserIdx = messages.lastIndex(where: { $0.role == .user }) else {
            return false
        }
        return messages[messages.index(after: lastUserIdx)...]
            .contains(where: { $0.role == .assistant })
    }

    private func latestAssistantText(
        in messages: [HermesVoiceAPI.HistoryMessage],
        afterUserText userText: String?
    ) -> String? {
        let trimmedUserText = userText?.trimmingCharacters(in: .whitespacesAndNewlines)
        var startIndex = messages.startIndex
        if let trimmedUserText, !trimmedUserText.isEmpty {
            var foundUser = false
            for idx in messages.indices.reversed() where messages[idx].role == "user" {
                if messages[idx].text.trimmingCharacters(in: .whitespacesAndNewlines) == trimmedUserText {
                    startIndex = messages.index(after: idx)
                    foundUser = true
                    break
                }
            }
            if !foundUser { return nil }
        }
        return messages[startIndex...]
            .last(where: { $0.role == "assistant" && !$0.text.isEmpty })?
            .text
    }

    /// Single-shot fallback used when the streaming endpoint is unavailable
    /// (e.g. an older backend that 404s on /api/*/stream).
    private func sendTextFallback(_ text: String, sessionId: String?, voiceId: String, tts: String?, harness: String?) async {
        do {
            let response = try await api.sendText(text, sessionId: sessionId, voiceId: voiceId, tts: tts, harness: harness)
            try Task.checkCancellation()
            await handle(response: response)
        } catch is CancellationError {
        } catch {
            if !Task.isCancelled { failTurn(error) }
        }
    }

    private func sendAudioFallback(url: URL, sessionId: String?, voiceId: String, tts: String?, harness: String?) async {
        do {
            let response = try await api.sendAudio(
                fileURL: url, mimeType: "audio/m4a", sessionId: sessionId, voiceId: voiceId, tts: tts, harness: harness
            )
            VoiceRecorder.discard(url)
            try Task.checkCancellation()
            await handle(response: response)
        } catch is CancellationError {
            VoiceRecorder.discard(url)
        } catch {
            VoiceRecorder.discard(url)
            if !Task.isCancelled { failTurn(error) }
        }
    }

    private func failTurn(_ error: Error) {
        stopHeartbeat()
        state = .error(error.localizedDescription)
    }

    /// Speak a warm, casual on-device acknowledgment the instant a turn is
    /// dispatched (the .thinking flip) — only when an on-device voice is active
    /// (the tts=none path) and at most once per turn. Fire-and-forget; the real
    /// reply's `speak()` hard-cuts it. Backend `narrate` events own per-tool
    /// filler; this is the generic "I heard you" before any tool runs.
    private func fireInstantAckIfNeeded() {
        guard settings.isLocalVoiceSelected, !didAckThisTurn else { return }
        didAckThisTurn = true
        // `off` speaks nothing — not even the instant ack.
        if settings.fillerVerbosity != .off {
            LocalSpeaker.shared.narrate(FillerPhrases.ack(), voice: settings.localVoiceName)
            noteFillerSpoken()
        }
        // `chatty` runs a periodic "still working" heartbeat during silent gaps;
        // start it at dispatch (alongside the ack) so the first beat is one gap
        // out from the ack.
        startHeartbeatIfNeeded()
    }

    /// Record that some filler (ack / narrate / heartbeat) just spoke, so the
    /// chatty heartbeat waits a fresh gap before firing again.
    private func noteFillerSpoken() {
        lastFillerSpokenAt = Date()
    }

    /// Start the chatty heartbeat loop for this turn (no-op unless an on-device
    /// voice is active AND verbosity is `chatty`). Cancels any prior task first so
    /// a heartbeat can't leak across turns.
    private func startHeartbeatIfNeeded() {
        heartbeatTask?.cancel()
        heartbeatTask = nil
        guard settings.isLocalVoiceSelected, settings.fillerVerbosity == .chatty else { return }
        heartbeatTask = Task { @MainActor [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                let elapsed = Date().timeIntervalSince(self.lastFillerSpokenAt)
                let wait = Self.heartbeatGap - elapsed
                if wait > 0 {
                    try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
                }
                if Task.isCancelled { return }
                // Only speak while the turn is still working — never over a reply
                // that's already speaking, and not once we've fallen idle.
                guard self.state == .thinking || self.state == .sending else { return }
                // A filler spoke during our sleep → reset the gap, don't beat yet.
                guard Date().timeIntervalSince(self.lastFillerSpokenAt) >= Self.heartbeatGap else { continue }
                LocalSpeaker.shared.narrate(FillerPhrases.heartbeat(), voice: self.settings.localVoiceName)
                self.noteFillerSpoken()
            }
        }
    }

    /// Cancel the chatty heartbeat. Called at every turn-end path (completion,
    /// error, cancel, barge-in, and before the hands-free loop re-arms) so it
    /// never speaks after the real reply begins or leaks into the next turn.
    func stopHeartbeat() {
        heartbeatTask?.cancel()
        heartbeatTask = nil
    }

    func clearError() {
        if case .error = state { state = .idle }
    }

    /// Cancels whatever phase of the current turn is in flight without
    /// starting a new one. Used by the close button in the bottom dock.
    /// Recording → discards the captured audio. Sending/thinking → cancels
    /// the URL session. Speaking → stops playback.
    func cancelCurrentTurn() {
        clearPending()
        switch state {
        case .recording:
            if let url = recorder.stop() {
                VoiceRecorder.discard(url)
            }
            state = .idle
        case .sending, .thinking:
            currentTurn?.cancel()
            currentTurn = nil
            // Cut any spoken filler (instant ack / tool narration / heartbeat) too.
            stopHeartbeat()
            LocalSpeaker.shared.stop()
            state = .idle
        case .speaking:
            player.stop()
            stopHeartbeat()
            LocalSpeaker.shared.stop()
            state = .idle
        case .idle, .error:
            break
        }
    }

    func reset() {
        messages.removeAll()
        sessionId = nil
        attachedRepo = nil
        attachedReadOnly = false
        clearPending()
        state = .idle
    }

    /// Whether the active backend profile can be switched right now: never
    /// mid-turn (no reroute of live work) and never while a voice
    /// approval/question is paused waiting on the user.
    var canSwitchBackend: Bool {
        guard pendingApproval == nil, pendingQuestion == nil else { return false }
        switch state {
        case .idle, .error: return true
        case .recording, .sending, .thinking, .speaking: return false
        }
    }

    /// Switches the active backend profile and clears the in-memory
    /// conversation so the next turn starts fresh against the new backend.
    /// Returns false (no-op) when busy (`canSwitchBackend`) or `profileID`
    /// is unknown.
    @discardableResult
    func switchBackend(to profileID: UUID) -> Bool {
        // `activateProfile` precedes the `reset()` below deliberately — an
        // adjudicated deviation from the design doc's "clear before activate"
        // wording. A FAILED activation (unknown id) must not have already
        // destroyed conversation state, so we gate the whole switch on it
        // succeeding first. This method is fully synchronous on the MainActor,
        // so there is no interleaving window between activate and reset for
        // another turn to observe a half-switched state.
        guard canSwitchBackend, settings.activateProfile(id: profileID) else { return false }
        // A completed stream's task may still be unwinding when we get here
        // (`.done` flips state to `.idle` BEFORE the task itself finishes) —
        // cancel it so a late old-backend event can't touch the new context.
        // This is belt-and-braces teardown of an ALREADY-FINISHED turn's
        // task, not a cancel-and-reroute of live work (canSwitchBackend
        // already forbade that above).
        currentTurn?.cancel()
        currentTurn = nil
        reset()
        return true
    }

    /// Attach the live conversation to an existing coding-agent session (e.g. a
    /// Claude Code session you started in your terminal). Routes subsequent voice
    /// turns to that harness + session id; the backend resumes it in its own
    /// repo (read-only in this phase). Generalizes `resume(sessionId:)`.
    func attach(sessionId: String, harness: String, repo: String?, readOnly: Bool) {
        guard !sessionId.isEmpty else { return }
        settings.selectedHarness = harness
        self.sessionId = sessionId
        attachedRepo = repo
        attachedReadOnly = readOnly
        let place = repo.map { "in \($0)" } ?? "session"
        let modeLabel = readOnly ? " · read-only" : " · write · approval"
        messages.append(Message(
            role: .toolCall,
            text: "attached to \(harness) \(place)\(modeLabel)",
            toolCall: ToolCallDetail(name: "session", preview: "attached", ok: true)
        ))
        state = .idle
    }

    // MARK: - Phase B: voice approval / questions

    /// Approve or deny a pending write/command. Resolves the paused turn so the
    /// agent continues (or backs off).
    func answerApproval(allow: Bool) {
        guard let p = pendingApproval else { return }
        pendingApproval = nil
        stopVoiceAnswer()
        let api = self.api
        Task {
            try? await api.answerTurn(
                turnId: p.turnId, requestId: p.requestId, value: allow ? "allow" : "deny"
            )
        }
    }

    /// Answer the agent's structured question with the selected option(s).
    func answerQuestion(_ selected: [String]) {
        guard let q = pendingQuestion else { return }
        pendingQuestion = nil
        stopVoiceAnswer()
        let api = self.api
        Task {
            try? await api.answerTurn(turnId: q.turnId, requestId: q.requestId, value: selected)
        }
    }

    /// Speak the pending prompt aloud (when an on-device voice is active), then —
    /// if the listening model is ready — auto-listen for a spoken answer. The mic
    /// button is untouched (still barge-in/cancel); this is a separate listener,
    /// so saying "yes"/"no"/an option resolves the card hands-free. Tap still
    /// works; whichever lands first wins.
    private func presentPending(spoken text: String) {
        guard settings.isLocalVoiceSelected, !text.isEmpty else { return }
        answerTask?.cancel()
        answerTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await LocalSpeaker.shared.speak(text, voice: self.settings.localVoiceName)
            guard !Task.isCancelled, LocalVad.shared.isReady else { return }
            // Let the session settle between speaking (.playback) and listening
            // (.playAndRecord) — the same guard the conversation-mode loop uses.
            try? await Task.sleep(nanoseconds: 50_000_000)
            if Task.isCancelled { return }
            await self.listenForAnswerLoop()
        }
    }

    /// Listen → transcribe → parse → submit, retrying a couple times on an
    /// empty/ambiguous utterance before falling back to tap-only.
    private func listenForAnswerLoop() async {
        var attempts = 0
        while !Task.isCancelled, attempts < 3 {
            guard pendingApproval != nil || pendingQuestion != nil else { return }
            listeningForAnswer = true
            let samples: [Float]
            do { samples = try await answerCapture.listen() }
            catch { listeningForAnswer = false; return }
            listeningForAnswer = false
            if Task.isCancelled { return }

            let heard = (try? await LocalTranscriber.shared.transcribe(samples: samples)) ?? ""
            let trimmed = heard.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { attempts += 1; continue }

            if pendingApproval != nil, let allow = Self.parseYesNo(trimmed) {
                answerApproval(allow: allow)
                return
            }
            if let q = pendingQuestion,
               let picks = Self.parseSelection(trimmed, options: q.options, multi: q.multi) {
                answerQuestion(picks)
                return
            }
            attempts += 1  // heard speech but couldn't map it — try once more
        }
        listeningForAnswer = false
    }

    private func stopVoiceAnswer() {
        answerTask?.cancel()
        answerTask = nil
        answerCapture.stop()
        listeningForAnswer = false
    }

    /// Map a spoken utterance to approve (true) / deny (false), or nil if unclear.
    /// A "no" word wins over a "yes" word (deny is the safer default).
    static func parseYesNo(_ s: String) -> Bool? {
        let t = " \(s.lowercased()) "
        let no = ["no", "nope", "nah", "deny", "denied", "cancel", "stop",
                  "reject", "rejected", "don't", "do not", "negative", "skip",
                  "decline"]
        if no.contains(where: { t.contains(" \($0) ") || t.contains("\($0).") }) {
            return false
        }
        let yes = ["yes", "yeah", "yep", "yup", "approve", "approved", "sure",
                   "ok", "okay", "confirm", "confirmed", "go ahead", "do it",
                   "allow", "accept", "affirmative", "correct"]
        if yes.contains(where: { t.contains(" \($0) ") || t.contains("\($0).") }) {
            return true
        }
        return nil
    }

    /// Map an utterance to selected option(s): a label substring match, else an
    /// ordinal ("first"/"two"/"option 3"). Multi-select keeps every matched
    /// label; single-select takes the first. nil when nothing matches.
    static func parseSelection(_ s: String, options: [String], multi: Bool) -> [String]? {
        let t = s.lowercased()
        var matched = options.filter { !$0.isEmpty && t.contains($0.lowercased()) }
        if matched.isEmpty, let idx = ordinalIndex(in: t), idx < options.count {
            matched = [options[idx]]
        }
        guard !matched.isEmpty else { return nil }
        return multi ? matched : [matched[0]]
    }

    private static func ordinalIndex(in t: String) -> Int? {
        let words: [(String, Int)] = [
            ("first", 0), ("second", 1), ("third", 2), ("fourth", 3), ("fifth", 4),
            ("number one", 0), ("number two", 1), ("number three", 2),
            ("option one", 0), ("option two", 1), ("option three", 2),
            ("one", 0), ("two", 1), ("three", 2), ("four", 3), ("five", 4),
        ]
        for (w, i) in words where t.contains(w) { return i }
        for (d, i) in [("1", 0), ("2", 1), ("3", 2), ("4", 3), ("5", 4)]
        where t.contains(d) { return i }
        return nil
    }

    private func clearPending() {
        pendingApproval = nil
        pendingQuestion = nil
        currentTurnId = nil
        stopVoiceAnswer()
    }

    /// Resume a past conversation by its Hermes session id. The transcript
    /// in the app doesn't backfill — the History view is where you read past
    /// turns — but the next message you send extends that Hermes session
    /// (--resume <id>) so context is preserved.
    func resume(sessionId: String) {
        guard !sessionId.isEmpty else { return }
        self.sessionId = sessionId
        messages.append(Message(
            role: .toolCall,
            text: "resumed conversation \(sessionId)",
            toolCall: ToolCallDetail(name: "session", preview: "resumed", ok: true)
        ))
        state = .idle
    }

    // MARK: - Internals

    private func handle(response: HermesVoiceAPI.TurnResponse) async {
        // Single-shot fallback delivered the reply — kill any chatty heartbeat
        // before speaking it.
        stopHeartbeat()
        settings.markReachable()
        // For audio mode the user text comes from STT — append it now.
        if state == .sending {
            messages.append(Message(role: .user, text: response.userText))
        }
        // Tool calls render between user and assistant. They are NEVER spoken
        // by TTS — only `assistantText` is synthesized server-side.
        for tc in response.toolCalls {
            messages.append(Message(
                role: .toolCall,
                text: "\(tc.name): \(tc.preview)",
                toolCall: ToolCallDetail(name: tc.name, preview: tc.preview, ok: tc.ok)
            ))
        }
        messages.append(Message(role: .assistant, text: response.assistantText))
        if !response.sessionId.isEmpty { sessionId = response.sessionId }

        // On-device TTS path (single-shot fallback): backend sent no audio_url
        // (tts=none), so speak the reply locally.
        if settings.isLocalVoiceSelected {
            state = .speaking
            await LocalSpeaker.shared.speak(response.assistantText, voice: settings.localVoiceName)
            if state == .speaking { state = .idle }
            return
        }

        guard let audioPath = response.audioUrl else {
            state = .idle
            return
        }

        // Progressive streaming: hand AVPlayer the URL directly and let it
        // pull bytes from the backend as ElevenLabs produces them. This is
        // the 1.5-3s perceived-latency win — playback starts mid-synthesis.
        guard let audioURL = api.makeURL(path: audioPath) else {
            state = .error("Invalid audio URL")
            return
        }
        state = .speaking
        await player.play(url: audioURL, authToken: settings.authToken)
        state = .idle
    }

    private func isError(_ s: State) -> Bool {
        if case .error = s { return true } else { return false }
    }

    /// Drive the lock-screen Live Activity from the turn state machine.
    /// .sending/.thinking is the "waiting on Hermes" window; .speaking is
    /// playback. Recording is intentionally excluded (you're holding the
    /// phone then). Idle/error/recording tear the activity down.
    private func syncLiveActivity() {
        switch state {
        case .sending, .thinking:
            LiveActivityController.shared.showThinking(detail: lastUserText)
        case .speaking:
            LiveActivityController.shared.showSpeaking(detail: lastAssistantText ?? "")
        case .idle, .error, .recording:
            LiveActivityController.shared.finish()
        }
    }
}
