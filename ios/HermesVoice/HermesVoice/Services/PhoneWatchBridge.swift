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

    /// The UserDefaults suite the relay marker persists to. Injected (default
    /// `.standard`) so tests can round-trip the pair against an isolated suite
    /// without touching the shared domain. Production uses `.standard`.
    private let defaults: UserDefaults

    /// The (sessionId, profileId, harness) triple the Watch's current known
    /// session was last relayed under (nil = no relayed session yet). Stores
    /// the session id we handed the Watch, the profile it was created under,
    /// AND the harness that created it. Set only after a relay actually hands
    /// the Watch a session id (mirrors the condition under which
    /// `WatchSession.handleResponse` updates its own `sessionId`), so a turn
    /// that fails mid-switch doesn't wrongly "clear" the mismatch. On each
    /// incoming turn the relay guard forwards the Watch's session id only when
    /// it matches ALL THREE fields — same session id, same active profile, AND
    /// same active harness — so a post-switch turn (wrong laptop), a harness
    /// change under the same profile (`attach()` adopting a different harness),
    /// or a delivery that was never confirmed drops the stale id and starts
    /// fresh. Because the marker holds the id we last SENT the Watch, a failed
    /// `sendMessage` delivery is self-correcting: the Watch's stale id simply
    /// won't match the stored triple next turn.
    /// Persisted: WCSession can relaunch the phone app in the background
    /// while the Watch app (and its in-memory session id) stays resident,
    /// so an in-memory marker would wrongly drop Watch continuity on every
    /// phone-process relaunch.
    private struct RelayMarker: Equatable {
        let sessionId: String
        let profileId: UUID
        let harness: String
    }

    /// Immutable snapshot of the route a single Watch relay targets, bound at
    /// the START of that relay (mirrors `NotificationManager.RegistrationTarget`).
    /// Every route-dependent read in the relay — the session-resolve guard, the
    /// upload's harness, and the marker tag written after the response returns —
    /// goes to THIS snapshot, never live `settings`, so a switch that flips the
    /// active profile/harness mid-upload can't misattribute the stale in-flight
    /// response to the new route. (url/token are already effectively snapshotted
    /// by the `HermesVoiceAPI` construction below.)
    private struct RelayRoute {
        let profileId: UUID
        let harness: String
    }

    private var relayMarker: RelayMarker? {
        get {
            Self.loadRelayMarker(from: defaults)
                .map { RelayMarker(sessionId: $0.sessionId, profileId: $0.profileId, harness: $0.harness) }
        }
        set {
            Self.saveRelayMarker(
                newValue.map { (sessionId: $0.sessionId, profileId: $0.profileId, harness: $0.harness) },
                to: defaults
            )
        }
    }
    private static let relayedSessionIdKey = "hv.watch.sessionID"
    private static let relayedSessionProfileKey = "hv.watch.sessionProfileID"
    private static let relayedSessionHarnessKey = "hv.watch.sessionHarness"

    /// Loads the persisted (sessionId, profileId, harness) relay marker from
    /// `defaults`, or nil when any key is absent/blank/unparseable. Pure over
    /// `defaults` so tests round-trip it against an isolated suite; the instance
    /// property and `clearRelayMarker()` both route through here. A pre-upgrade
    /// marker missing the harness key reads as nil — a one-time safe drop.
    static func loadRelayMarker(
        from defaults: UserDefaults
    ) -> (sessionId: String, profileId: UUID, harness: String)? {
        guard let sid = defaults.string(forKey: relayedSessionIdKey), !sid.isEmpty,
              let pidString = defaults.string(forKey: relayedSessionProfileKey),
              let pid = UUID(uuidString: pidString),
              let harness = defaults.string(forKey: relayedSessionHarnessKey)
        else { return nil }
        return (sessionId: sid, profileId: pid, harness: harness)
    }

    /// Persists (or, with nil, clears) the relay marker triple to `defaults`.
    static func saveRelayMarker(
        _ marker: (sessionId: String, profileId: UUID, harness: String)?, to defaults: UserDefaults
    ) {
        defaults.set(marker?.sessionId, forKey: relayedSessionIdKey)
        defaults.set(marker?.profileId.uuidString, forKey: relayedSessionProfileKey)
        defaults.set(marker?.harness, forKey: relayedSessionHarnessKey)
    }

    /// Pure relay-session decision, lifted out of the WCSession-coupled path so
    /// it's unit-testable. Returns the Watch's `incoming` session id to forward
    /// ONLY when it's non-empty AND the stored marker matches it on ALL THREE
    /// fields — same session id we last handed the Watch, the profile active
    /// now, AND the harness active now. nil means "drop the stale id, start a
    /// fresh conversation" (a blank incoming id, a session from a different
    /// laptop, a session created under a different harness, or a delivery that
    /// was never confirmed). Mirrors the original inline guard exactly.
    static func resolveRelaySession(
        incoming: String?,
        stored: (sessionId: String, profileId: UUID, harness: String)?,
        activeProfileId: UUID,
        activeHarness: String
    ) -> String? {
        guard let sid = incoming, !sid.isEmpty else { return nil }
        guard let stored, stored.sessionId == sid, stored.profileId == activeProfileId,
              stored.harness == activeHarness
        else { return nil }
        return sid
    }

    /// Pure marker-tagging decision, lifted out of the WCSession-coupled path so
    /// it's unit-testable. Given the route SNAPSHOT bound at relay start and the
    /// session id the backend returned, produces the (sessionId, profileId,
    /// harness) triple to persist — tagged with the SNAPSHOT route, NEVER live
    /// settings — so a switch that flips the active profile/harness mid-flight
    /// can't misattribute a stale in-flight response to the new route. Returns
    /// nil when the response carries no session id (empty), signalling "leave the
    /// stored marker untouched" (mirrors WatchSession.handleResponse leaving its
    /// id untouched on an empty response). Chained with `resolveRelaySession`
    /// under the post-switch route, the two functions reproduce the relay
    /// interleaving end-to-end: this tags the stale response with the OLD route,
    /// and the next turn's resolve drops it on the triple mismatch.
    static func nextRelayMarker(
        routeProfileId: UUID,
        routeHarness: String,
        responseSessionId: String
    ) -> (sessionId: String, profileId: UUID, harness: String)? {
        guard !responseSessionId.isEmpty else { return nil }
        return (sessionId: responseSessionId, profileId: routeProfileId, harness: routeHarness)
    }

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

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
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
        // Bind the route snapshot ONCE at relay start — every route-dependent
        // read below (resolve, upload harness, marker tag) goes to this, never
        // live `settings`, so a mid-flight switch can't redirect or misattribute
        // this in-flight relay. See RelayRoute's doc comment.
        let route = RelayRoute(
            profileId: settings.activeBackendProfile.id,
            harness: settings.selectedHarness
        )
        let metadata = file.metadata ?? [:]
        // Forward the Watch's session id ONLY when it matches the stored triple:
        // the same session id we last handed the Watch AND the profile AND the
        // harness active now. Any mismatch — a session id from a different
        // laptop, one created under a different harness, or one whose delivery
        // to the Watch was never confirmed — is dropped, starting a fresh
        // conversation instead of forwarding a stale session to the wrong target.
        let sessionId = Self.resolveRelaySession(
            incoming: metadata["session_id"] as? String,
            stored: relayMarker.map { (sessionId: $0.sessionId, profileId: $0.profileId, harness: $0.harness) },
            activeProfileId: route.profileId,
            activeHarness: route.harness
        )

        let api = HermesVoiceAPI(
            baseURL: settings.backendURL, authToken: settings.authToken
        )
        do {
            let response = try await api.sendAudio(
                fileURL: file.fileURL,
                mimeType: "audio/m4a",
                sessionId: sessionId,
                harness: route.harness
            )
            // Advance the marker to the (sessionId, profileId, harness) we're
            // about to hand the Watch — tagged with the route SNAPSHOT bound at
            // relay start, NEVER live settings, so a switch that flipped the
            // active profile/harness during the upload can't misattribute this
            // stale response to the new route. nil (empty response sessionId)
            // leaves the stored marker untouched, mirroring
            // WatchSession.handleResponse leaving its id untouched.
            if let next = Self.nextRelayMarker(
                routeProfileId: route.profileId,
                routeHarness: route.harness,
                responseSessionId: response.sessionId
            ) {
                relayMarker = RelayMarker(
                    sessionId: next.sessionId, profileId: next.profileId, harness: next.harness
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
