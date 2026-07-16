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

    /// The (sessionId, profileId) pair the Watch's current known session was
    /// last relayed under (nil = no relayed session yet). Stores BOTH the
    /// session id we handed the Watch AND the profile it was created under.
    /// Set only after a relay actually hands the Watch a session id (mirrors
    /// the condition under which `WatchSession.handleResponse` updates its own
    /// `sessionId`), so a turn that fails mid-switch doesn't wrongly "clear"
    /// the mismatch. On each incoming turn the relay guard forwards the
    /// Watch's session id only when it matches BOTH fields — same session id
    /// AND same active profile — so a post-switch turn (wrong laptop) or a
    /// delivery that was never confirmed drops the stale id and starts fresh.
    /// Because the marker holds the id we last SENT the Watch, a failed
    /// `sendMessage` delivery is self-correcting: the Watch's stale id simply
    /// won't match the stored pair next turn.
    /// Persisted: WCSession can relaunch the phone app in the background
    /// while the Watch app (and its in-memory session id) stays resident,
    /// so an in-memory marker would wrongly drop Watch continuity on every
    /// phone-process relaunch.
    private struct RelayMarker: Equatable {
        let sessionId: String
        let profileId: UUID
    }

    private var relayMarker: RelayMarker? {
        get {
            let d = UserDefaults.standard
            guard let sid = d.string(forKey: Self.relayedSessionIdKey), !sid.isEmpty,
                  let pidString = d.string(forKey: Self.relayedSessionProfileKey),
                  let pid = UUID(uuidString: pidString)
            else { return nil }
            return RelayMarker(sessionId: sid, profileId: pid)
        }
        set {
            let d = UserDefaults.standard
            d.set(newValue?.sessionId, forKey: Self.relayedSessionIdKey)
            d.set(newValue?.profileId.uuidString, forKey: Self.relayedSessionProfileKey)
        }
    }
    private static let relayedSessionIdKey = "hv.watch.sessionID"
    private static let relayedSessionProfileKey = "hv.watch.sessionProfileID"

    /// Clears the relayed-session marker so the next Watch turn starts a fresh
    /// conversation. Called by the unified backend-apply path when routing
    /// changes (the profile UUID may be unchanged while the endpoint/agent
    /// changed, so the marker can't self-invalidate on id alone).
    func clearRelayMarker() {
        relayMarker = nil
    }

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
        // Forward the Watch's session id ONLY when it matches the stored pair:
        // the same session id we last handed the Watch AND the profile active
        // now. Any mismatch — a session id from a different laptop, or one whose
        // delivery to the Watch was never confirmed — is dropped, starting a
        // fresh conversation instead of sending laptop A's session id to laptop B.
        if let sid = sessionId {
            let marker = relayMarker
            if marker?.sessionId != sid || marker?.profileId != settings.activeBackendProfile.id {
                sessionId = nil
            }
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
            // Advance the marker to the (sessionId, profileId) we're about to
            // hand the Watch — but only once there's actually a session id to
            // compare against next time (empty sessionId means
            // WatchSession.handleResponse leaves its stored id untouched too).
            if !response.sessionId.isEmpty {
                relayMarker = RelayMarker(
                    sessionId: response.sessionId,
                    profileId: settings.activeBackendProfile.id
                )
            }
            await replyToWatch(response: response)

            // If the user opted in, also relay the audio reply to Watch. This
            // is awaited inline — deliberately, inside the `isRelaying` window —
            // so the relay finishes before the turn is marked done. The text
            // reply above has already reached the Watch; the audio follows here.
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
