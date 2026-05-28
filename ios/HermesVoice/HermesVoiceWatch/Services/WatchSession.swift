import Foundation
import WatchConnectivity

/// State exposed to the Watch UI. Drives the button color, status text, and
/// the latest response shown under the button.
@MainActor
final class WatchSession: NSObject, ObservableObject {
    static let shared = WatchSession()

    enum State: Equatable {
        case idle
        case recording
        case sending          // file in flight to phone or onward to backend
        case thinking
        case error(String)

        var label: String {
            switch self {
            case .idle: return "Ready"
            case .recording: return "Recording…"
            case .sending: return "Sending…"
            case .thinking: return "Hermes…"
            case .error(let msg): return msg
            }
        }
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var lastResponseText: String = ""
    @Published private(set) var phoneReachable: Bool = false
    @Published private(set) var sessionId: String? = nil

    /// Called from the view to update state on recorder events.
    func setState(_ newState: State) { state = newState }

    private let wcSession: WCSession?
    private let player = WatchPlayer()

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

    // MARK: - Outbound (Watch → iPhone)

    /// Send a freshly recorded audio file to the iPhone for upload.
    func sendAudio(fileURL: URL, sessionId: String?) {
        guard let wcSession, wcSession.activationState == .activated else {
            state = .error("Phone not reachable")
            return
        }
        state = .sending
        let metadata: [String: Any] = [
            "kind": "audio",
            "session_id": sessionId ?? "",
        ]
        wcSession.transferFile(fileURL, metadata: metadata)
    }

    // MARK: - Inbound (iPhone → Watch)

    fileprivate func handleResponse(_ message: [String: Any]) {
        let kind = message["kind"] as? String ?? ""
        switch kind {
        case "turn_response":
            let text = message["assistant_text"] as? String ?? ""
            lastResponseText = text
            // Thread the new session_id so the next turn continues the
            // same Hermes session (--resume on the backend).
            if let sid = message["session_id"] as? String, !sid.isEmpty {
                sessionId = sid
            }
            state = .idle
        case "turn_error":
            let msg = message["error"] as? String ?? "Unknown error"
            state = .error(msg)
        default:
            break
        }
    }
}

extension WatchSession: WCSessionDelegate {
    nonisolated func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {
        Task { @MainActor in
            self.phoneReachable = session.isReachable
        }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        Task { @MainActor in
            self.phoneReachable = session.isReachable
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        Task { @MainActor in
            self.handleResponse(message)
        }
    }

    nonisolated func session(
        _ session: WCSession,
        didFinish fileTransfer: WCSessionFileTransfer,
        error: Error?
    ) {
        guard error != nil else { return }
        Task { @MainActor in
            self.state = .error("Couldn't reach phone")
        }
    }

    /// Inbound files from iPhone. Currently the only kind is "reply_audio" —
    /// a fully-buffered MP3 of Hermes' spoken reply, sent when the user has
    /// "Play replies on Watch" enabled in iPhone settings.
    nonisolated func session(_ session: WCSession, didReceive file: WCSessionFile) {
        let metadata = file.metadata ?? [:]
        let kind = metadata["kind"] as? String ?? ""
        // Copy the file out of WC's transient location before the system
        // reclaims it. WC docs are clear: the URL is valid only for the
        // duration of this delegate call.
        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent("hv-watch-reply-\(UUID().uuidString).mp3")
        do {
            try FileManager.default.copyItem(at: file.fileURL, to: dest)
        } catch {
            return
        }
        Task { @MainActor in
            if kind == "reply_audio" {
                self.player.play(url: dest)
            }
        }
    }
}
