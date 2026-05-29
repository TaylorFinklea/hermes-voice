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

    /// Sub-state of `.sending` exposed for the pipeline-step UI. We don't
    /// have a streaming backend, so the phases reflect what we honestly
    /// know on the client: the request is uploading until the response
    /// header arrives, then we count anything else as "processing".
    enum SendingPhase: Equatable { case uploading, processing }

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
        sendingPhase = .uploading
        state = .sending

        let api = self.api
        let currentSession = sessionId
        let voiceId = settings.selectedVoiceId
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
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
                        sessionId: currentSession, voiceId: voiceId
                    ),
                    appendUserFromTranscribed: true
                )
                VoiceRecorder.discard(url)
            } catch is CancellationError {
                VoiceRecorder.discard(url)  // user interrupted; drop their audio
            } catch let HermesVoiceAPI.APIError.httpStatus(code, _) where code != 0 {
                // Streaming endpoint unavailable (older backend) → single-shot.
                await self.sendAudioFallback(url: url, sessionId: currentSession, voiceId: voiceId)
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

        let api = self.api
        let currentSession = sessionId
        let voiceId = settings.selectedVoiceId
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await self.consumeTurn(
                    api.streamText(trimmed, sessionId: currentSession, voiceId: voiceId),
                    appendUserFromTranscribed: false
                )
            } catch is CancellationError {
                // user barged in; userPressedMic already moved us to recording
            } catch let HermesVoiceAPI.APIError.httpStatus(code, _) where code != 0 {
                await self.sendTextFallback(trimmed, sessionId: currentSession, voiceId: voiceId)
            } catch {
                if !Task.isCancelled { self.failTurn(error) }
            }
        }
        currentTurn = task
        await task.value
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
                if !sid.isEmpty { sessionId = sid }
                messages.append(Message(role: .assistant, text: txt))
                settings.markReachable()
            case .audio(let path):
                guard let audioURL = api.makeURL(path: path) else { break }
                state = .speaking
                await player.play(url: audioURL, authToken: settings.authToken)
                state = .idle
            case .done:
                if state != .speaking { state = .idle }
            case .failed(let detail):
                state = .error(detail)
                return
            }
        }
        // Stream ended cleanly with no audio leg (e.g. TTS disabled).
        if state == .thinking || state == .sending { state = .idle }
    }

    /// Single-shot fallback used when the streaming endpoint is unavailable
    /// (e.g. an older backend that 404s on /api/*/stream).
    private func sendTextFallback(_ text: String, sessionId: String?, voiceId: String) async {
        do {
            let response = try await api.sendText(text, sessionId: sessionId, voiceId: voiceId)
            try Task.checkCancellation()
            await handle(response: response)
        } catch is CancellationError {
        } catch {
            if !Task.isCancelled { failTurn(error) }
        }
    }

    private func sendAudioFallback(url: URL, sessionId: String?, voiceId: String) async {
        do {
            let response = try await api.sendAudio(
                fileURL: url, mimeType: "audio/m4a", sessionId: sessionId, voiceId: voiceId
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
