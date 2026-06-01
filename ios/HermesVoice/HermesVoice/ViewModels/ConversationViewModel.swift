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
            case .thinking: return "Hermes is thinking…"
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

    init(settings: AppSettings) {
        self.settings = settings
    }

    private var api: HermesVoiceAPI {
        HermesVoiceAPI(baseURL: settings.backendURL, authToken: settings.authToken)
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
            LocalSpeaker.shared.stop()   // also cut on-device Kokoro playback
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
        state = .sending

        let api = self.api
        let currentSession = sessionId
        let voiceId = settings.serverVoiceId
        let ttsMode: String? = settings.isLocalVoiceSelected ? "none" : nil
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
                    await self.streamTextTurnBody(trimmed, sessionId: currentSession, voiceId: voiceId, tts: ttsMode)
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
                        sessionId: currentSession, voiceId: voiceId, tts: ttsMode
                    ),
                    appendUserFromTranscribed: true
                )
                VoiceRecorder.discard(url)
            } catch is CancellationError {
                VoiceRecorder.discard(url)  // user interrupted; drop their audio
            } catch let HermesVoiceAPI.APIError.httpStatus(code, _) where code != 0 {
                // Streaming endpoint unavailable (older backend) → single-shot.
                await self.sendAudioFallback(url: url, sessionId: currentSession, voiceId: voiceId, tts: ttsMode)
            } catch {
                VoiceRecorder.discard(url)
                if !Task.isCancelled { self.failTurn(error) }
            }
        }
        currentTurn = task
        await task.value
    }

    func sendText(_ text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        messages.append(Message(role: .user, text: trimmed))
        state = .thinking

        let currentSession = sessionId
        let voiceId = settings.serverVoiceId
        let ttsMode: String? = settings.isLocalVoiceSelected ? "none" : nil
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.streamTextTurnBody(trimmed, sessionId: currentSession, voiceId: voiceId, tts: ttsMode)
        }
        currentTurn = task
        await task.value
    }

    /// Streams a text turn and commits it to the transcript. Shared by typed
    /// text (`sendText`) and on-device-transcribed audio (`stopRecordingAndSend`).
    /// Does NOT create its own Task — the caller owns `currentTurn` so barge-in
    /// cancels the right thing. Falls back to a single-shot text POST if the
    /// streaming endpoint is unavailable; swallows cancellation.
    private func streamTextTurnBody(_ trimmed: String, sessionId: String?, voiceId: String, tts: String?) async {
        do {
            try await consumeTurn(
                api.streamText(trimmed, sessionId: sessionId, voiceId: voiceId, tts: tts),
                appendUserFromTranscribed: false
            )
        } catch is CancellationError {
            // user barged in; userPressedMic already moved us to recording
        } catch let HermesVoiceAPI.APIError.httpStatus(code, _) where code != 0 {
            await sendTextFallback(trimmed, sessionId: sessionId, voiceId: voiceId, tts: tts)
        } catch {
            if !Task.isCancelled {
                let recovered = await recoverMissingAssistantFromHistory(
                    sessionId: sessionId,
                    turnUserText: trimmed
                )
                if !recovered { failTurn(error) }
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
        let turnUserText = lastUserText
        for try await ev in stream {
            try Task.checkCancellation()
            switch ev {
            case .transcribed(let t):
                if appendUserFromTranscribed {
                    messages.append(Message(role: .user, text: t))
                }
                // STT done; Hermes is working — move to the thinking pane so the
                // live tool chips show (audio turns start in .sending).
                if state == .sending { state = .thinking }
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
                state = .error(detail)
                return
            }
        }
        if !sawAssistant,
           let sid = finalSessionId,
           await recoverMissingAssistantFromHistory(sessionId: sid, turnUserText: turnUserText) {
            return
        }
        // Stream ended cleanly with no audio leg (e.g. TTS disabled).
        if state == .thinking || state == .sending { state = .idle }
    }

    /// Defensive recovery for a real-world stream edge case: Hermes can finish
    /// the turn and persist the assistant reply, while the phone misses the
    /// final `assistant` event. Pull the just-finished turn from History so the
    /// user sees the answer in the live pane instead of only after opening
    /// History.
    private func recoverMissingAssistantFromHistory(
        sessionId: String?,
        turnUserText: String?
    ) async -> Bool {
        guard let sessionId, !sessionId.isEmpty else { return false }
        do {
            let detail = try await api.getSession(id: sessionId)
            guard let assistantText = latestAssistantText(
                in: detail.messages,
                afterUserText: turnUserText
            ) else {
                return false
            }
            if !messages.contains(where: { $0.role == .assistant && $0.text == assistantText }) {
                messages.append(Message(role: .assistant, text: assistantText))
            }
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
    private func sendTextFallback(_ text: String, sessionId: String?, voiceId: String, tts: String?) async {
        do {
            let response = try await api.sendText(text, sessionId: sessionId, voiceId: voiceId, tts: tts)
            try Task.checkCancellation()
            await handle(response: response)
        } catch is CancellationError {
        } catch {
            if !Task.isCancelled { failTurn(error) }
        }
    }

    private func sendAudioFallback(url: URL, sessionId: String?, voiceId: String, tts: String?) async {
        do {
            let response = try await api.sendAudio(
                fileURL: url, mimeType: "audio/m4a", sessionId: sessionId, voiceId: voiceId, tts: tts
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
        state = .error(error.localizedDescription)
    }

    func clearError() {
        if case .error = state { state = .idle }
    }

    /// Cancels whatever phase of the current turn is in flight without
    /// starting a new one. Used by the close button in the bottom dock.
    /// Recording → discards the captured audio. Sending/thinking → cancels
    /// the URL session. Speaking → stops playback.
    func cancelCurrentTurn() {
        switch state {
        case .recording:
            if let url = recorder.stop() {
                VoiceRecorder.discard(url)
            }
            state = .idle
        case .sending, .thinking:
            currentTurn?.cancel()
            currentTurn = nil
            state = .idle
        case .speaking:
            player.stop()
            LocalSpeaker.shared.stop()
            state = .idle
        case .idle, .error:
            break
        }
    }

    func reset() {
        messages.removeAll()
        sessionId = nil
        state = .idle
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
