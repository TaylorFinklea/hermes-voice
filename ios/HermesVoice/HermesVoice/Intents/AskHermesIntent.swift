import AppIntents
import Foundation

/// Lightweight UserDefaults reader for use from AppIntent contexts where
/// the app isn't foregrounded and ObservableObject machinery isn't running.
struct SiriBackendConfig {
    let backendURL: String
    let authToken: String
    let selectedHarness: String
    /// The active profile's id (uuidString), or "" when read via the
    /// legacy-keys fallback (no profile payload exists yet). Used to guard
    /// `SiriSession` continuity against a switch to a different backend.
    let profileID: String

    static func load(defaults: UserDefaults = .standard) -> SiriBackendConfig {
        if let profile = AppSettings.readActiveProfile(defaults: defaults) {
            return SiriBackendConfig(
                backendURL: profile.url,
                authToken: profile.authToken,
                selectedHarness: profile.selectedHarness,
                profileID: profile.id.uuidString
            )
        }
        // No profile payload yet (pre-migration / never-launched app) —
        // fall back to the legacy raw keys.
        return SiriBackendConfig(
            backendURL: defaults.string(forKey: "hv.backendURL") ?? "",
            authToken: defaults.string(forKey: "hv.authToken") ?? "",
            selectedHarness: defaults.string(forKey: "hv.selectedHarness") ?? "hermes",
            profileID: ""
        )
    }
}

/// Continuity across Siri turns. We persist the last session_id and expire
/// it after 10 minutes idle, so "what time is sunset" → "and tomorrow?"
/// works inside a short window, but never accumulates stale context.
struct SiriSession {
    let id: String
    let lastUsed: Date

    private static let idKey = "hv.siri.session.id"
    private static let tsKey = "hv.siri.session.ts"
    private static let profileKey = "hv.siri.session.profileID"
    private static let stalenessSeconds: TimeInterval = 600

    /// Returns the saved session only when it's fresh AND was created under
    /// `profileID` — otherwise nil, so a backend switch never sends laptop
    /// A's session id to laptop B.
    static func load(profileID: String, defaults: UserDefaults = .standard) -> SiriSession? {
        guard let id = defaults.string(forKey: idKey),
              !id.isEmpty,
              let ts = defaults.object(forKey: tsKey) as? Date,
              Date().timeIntervalSince(ts) <= stalenessSeconds,
              defaults.string(forKey: profileKey) == profileID
        else { return nil }
        return SiriSession(id: id, lastUsed: ts)
    }

    static func save(_ id: String, profileID: String, defaults: UserDefaults = .standard) {
        guard !id.isEmpty else { return }
        defaults.set(id, forKey: idKey)
        defaults.set(Date(), forKey: tsKey)
        defaults.set(profileID, forKey: profileKey)
    }

    /// Drops the persisted Siri session so the next Siri turn starts fresh.
    /// Called by the unified backend-apply path on any routing change: the
    /// active profile's UUID can be unchanged while its endpoint/agent changed,
    /// so the profile-id guard in `load` isn't enough to invalidate continuity.
    static func clear(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: idKey)
        defaults.removeObject(forKey: tsKey)
        defaults.removeObject(forKey: profileKey)
    }
}

/// The Siri-invocable intent. Users say "Hey Siri, ask Harness <question>".
/// Returns the assistant's text as a spoken dialog (system TTS).
struct AskHermesIntent: AppIntent {
    static var title: LocalizedStringResource = "Ask Harness"
    // NOTE: Apple rejects App Intent descriptions that reference Apple
    // product/OS names ("Mac", "iPhone", etc.) — ITMS-90626. Keep this
    // platform-name-free.
    static var description = IntentDescription(
        "Ask your agent anything. Sends your question to your self-hosted agent and speaks the reply.",
        categoryName: "Voice"
    )

    /// `openAppWhenRun = false` keeps the interaction in Siri/Shortcuts UI;
    /// the app does not foreground. That's the hands-free behavior we want
    /// from CarPlay, watch, or a locked phone.
    static var openAppWhenRun: Bool = false

    @Parameter(
        title: "Question",
        description: "What to ask your agent.",
        requestValueDialog: "What should I ask?"
    )
    var prompt: String

    static var parameterSummary: some ParameterSummary {
        Summary("Ask \(\.$prompt)")
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let config = SiriBackendConfig.load()
        // A fresh install's migrated profile can carry the loopback default
        // URL without the user ever having configured a real backend — Siri
        // must treat that the same as "not configured" rather than actually
        // attempting a doomed localhost request.
        guard !config.backendURL.isEmpty, config.backendURL != AppSettings.defaultBackendURL else {
            return .result(dialog: "Harness Voice isn't configured yet. Open the Harness app and set your backend URL first.")
        }

        let api = HermesVoiceAPI(baseURL: config.backendURL, authToken: config.authToken)
        let session = SiriSession.load(profileID: config.profileID)

        do {
            let response = try await api.sendText(prompt, sessionId: session?.id, harness: config.selectedHarness)
            SiriSession.save(response.sessionId, profileID: config.profileID)
            let spoken = response.assistantText.isEmpty
                ? "The agent didn't have anything to say."
                : response.assistantText
            return .result(dialog: IntentDialog(stringLiteral: spoken))
        } catch let HermesVoiceAPI.APIError.httpStatus(code, _) where code == 401 {
            return .result(dialog: "The backend is rejecting my auth token. Check the app's settings.")
        } catch {
            return .result(dialog: "Sorry, I couldn't reach the backend. \(error.localizedDescription)")
        }
    }
}

/// Registers the intent's voice phrases. Siri auto-discovers these on app
/// install; users can also manually add custom phrases in the Shortcuts app.
///
/// IMPORTANT: AppShortcut phrases cannot embed free-form String parameters
/// inline — Apple only allows AppEntity/AppEnum parameters in spoken
/// phrases. So the activation phrase is just the verb + app name, and Siri
/// then prompts "What should I ask Hermes?" via the parameter's
/// `requestValueDialog`. Two-step interaction:
///
///   You: "Hey Siri, ask Harness"
///   Siri: "What should I ask?"
///   You: "What time is sunset tonight?"
///   Siri: (speaks the agent's reply)
///
/// The `\(.applicationName)` token resolves to CFBundleDisplayName, which
/// is "Harness" (see project.yml).
struct HermesVoiceShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: AskHermesIntent(),
            phrases: [
                "Ask \(.applicationName)",
                "Tell \(.applicationName)",
                "Talk to \(.applicationName)",
            ],
            shortTitle: "Ask Harness",
            systemImageName: "mic.fill"
        )
    }
}
