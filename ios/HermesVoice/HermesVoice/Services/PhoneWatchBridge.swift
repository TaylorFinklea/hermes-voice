import Foundation
import WatchConnectivity

/// iPhone-side WatchConnectivity handler. The Watch sends audio files via
/// transferFile; we upload to the backend and reply with the response text.
///
/// Why an explicit bridge: WCSession is a singleton that needs a long-lived
/// delegate. The view-model-scoped ConversationViewModel isn't right for
/// this because Watch messages can arrive when the iOS app is backgrounded.
@MainActor
final class PhoneWatchBridge: NSObject, ObservableObject {
    static let shared = PhoneWatchBridge()

    private let settings: AppSettings
    private let wcSession: WCSession?

    override init() {
        // Read settings fresh — Watch messages can fire before any view is up.
        self.settings = AppSettings()
        if WCSession.isSupported() {
            self.wcSession = WCSession.default
        } else {
            self.wcSession = nil
        }
        super.init()
        wcSession?.delegate = self
        wcSession?.activate()
    }

    /// Call once from HermesVoiceApp.init() so the session is activated and
    /// ready to receive Watch transfers from app launch.
    func start() {
        // No-op — activation happens in init. This method exists so the
        // singleton is reified at app startup; otherwise WCSession would
        // only activate when the first view holds a reference.
        _ = wcSession?.activationState
    }

    // MARK: - Inbound from Watch

    fileprivate func handleAudioTransfer(_ file: WCSessionFile) async {
        let metadata = file.metadata ?? [:]
        let sessionId = (metadata["session_id"] as? String).flatMap { $0.isEmpty ? nil : $0 }

        let api = HermesVoiceAPI(
            baseURL: settings.backendURL, authToken: settings.authToken
        )
        do {
            let response = try await api.sendAudio(
                fileURL: file.fileURL,
                mimeType: "audio/m4a",
                sessionId: sessionId,
                harness: settings.selectedHarness
            )
            await replyToWatch(response: response)

            // If the user opted in, also relay the audio reply to Watch.
            // This is a separate fire-and-forget step so the text response
            // reaches the watch immediately and audio follows when ready.
            if settings.playReplyOnWatch, let audioPath = response.audioUrl {
                await relayAudioToWatch(audioPath: audioPath, api: api)
            }
        } catch {
            await replyError(error.localizedDescription)
        }
    }

    private func relayAudioToWatch(audioPath: String, api: HermesVoiceAPI) async {
        guard let wcSession, wcSession.activationState == .activated else { return }
        do {
            // downloadAudio fully buffers the streamed MP3, then writes to a
            // temp file. transferFile reads from there. Both are best-effort
            // for v1 — if download fails, Watch just shows text (no error
            // shown to user since text already arrived).
            let localURL = try await api.downloadAudio(path: audioPath)
            wcSession.transferFile(localURL, metadata: ["kind": "reply_audio"])
            // Note: WC takes ownership of the file via the transfer queue
            // and removes it when the transfer completes. Do not delete it
            // here or you'll race the upload.
        } catch {
            // Silently swallow — text already delivered.
        }
    }

    private func replyToWatch(response: HermesVoiceAPI.TurnResponse) async {
        guard let wcSession, wcSession.activationState == .activated else { return }
        let message: [String: Any] = [
            "kind": "turn_response",
            "session_id": response.sessionId,
            "user_text": response.userText,
            "assistant_text": response.assistantText,
        ]
        wcSession.sendMessage(message, replyHandler: nil, errorHandler: nil)
    }

    private func replyError(_ msg: String) async {
        guard let wcSession, wcSession.activationState == .activated else { return }
        let message: [String: Any] = [
            "kind": "turn_error",
            "error": msg,
        ]
        wcSession.sendMessage(message, replyHandler: nil, errorHandler: nil)
    }
}

extension PhoneWatchBridge: WCSessionDelegate {
    nonisolated func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {}

    // WCSession on iOS requires these even though we don't switch users.
    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}
    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        // Re-activate so a second paired Watch could connect.
        WCSession.default.activate()
    }

    nonisolated func session(_ session: WCSession, didReceive file: WCSessionFile) {
        Task { @MainActor in
            await self.handleAudioTransfer(file)
        }
    }
}
