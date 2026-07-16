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

    // Injected from HermesVoiceApp so Watch turns read the SAME live settings
    // the app uses — not a stale launch-time snapshot. Weak: the app's
    // @StateObject owns it (mirrors NotificationManager).
    private weak var settings: AppSettings?
    private let wcSession: WCSession?

    /// The active-profile id the Watch's current known `sessionId` was
    /// created under (nil = no relayed session yet). Set only after a relay
    /// actually hands the Watch a session id (mirrors the condition under
    /// which `WatchSession.handleResponse` updates its own `sessionId`), so
    /// a turn that fails mid-switch doesn't wrongly "clear" the mismatch.
    /// Compared against the currently active profile on each incoming turn
    /// so a post-switch turn drops a stale session id from the wrong
    /// backend instead of sending laptop A's session to laptop B.
    /// Persisted: WCSession can relaunch the phone app in the background
    /// while the Watch app (and its in-memory session id) stays resident,
    /// so an in-memory marker would wrongly drop Watch continuity on every
    /// phone-process relaunch.
    private var relayedSessionProfileId: UUID? {
        get {
            UserDefaults.standard
                .string(forKey: Self.relayedSessionProfileKey)
                .flatMap(UUID.init(uuidString:))
        }
        set {
            UserDefaults.standard.set(newValue?.uuidString, forKey: Self.relayedSessionProfileKey)
        }
    }
    private static let relayedSessionProfileKey = "hv.watch.sessionProfileID"

    /// True for the duration of a Watch-relayed turn (upload → reply →
    /// optional audio relay). Drives the header picker's enabled condition
    /// so a profile switch can't land mid-relay.
    @Published private(set) var isRelaying = false

    override init() {
        if WCSession.isSupported() {
            self.wcSession = WCSession.default
        } else {
            self.wcSession = nil
        }
        super.init()
        wcSession?.delegate = self
        wcSession?.activate()
    }

    /// Call once from HermesVoiceApp.init() with the app's shared settings, so
    /// the session is activated and Watch turns see live setting changes.
    func start(settings: AppSettings) {
        self.settings = settings
        _ = wcSession?.activationState
    }

    // MARK: - Inbound from Watch

    fileprivate func handleAudioTransfer(_ file: WCSessionFile) async {
        isRelaying = true
        defer { isRelaying = false }
        guard let settings else {
            await replyError("App not ready — open Harness Voice on your phone.")
            return
        }
        let metadata = file.metadata ?? [:]
        var sessionId = (metadata["session_id"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        // A session id relayed under a DIFFERENT backend than the one
        // active now belongs to the wrong laptop — drop it and treat this
        // as a fresh conversation instead of sending laptop A's session id
        // to laptop B.
        if sessionId != nil, relayedSessionProfileId != settings.activeBackendProfile.id {
            sessionId = nil
        }

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
            // Only associate the session with this profile once the Watch
            // actually has a session id to compare against next time (empty
            // sessionId means WatchSession.handleResponse leaves its stored
            // id untouched too).
            if !response.sessionId.isEmpty {
                relayedSessionProfileId = settings.activeBackendProfile.id
            }
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
