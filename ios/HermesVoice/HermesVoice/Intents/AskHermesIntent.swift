import AppIntents
import Foundation

/// Lightweight UserDefaults reader for use from AppIntent contexts where
/// the app isn't foregrounded and ObservableObject machinery isn't running.
struct SiriBackendConfig {
    let backendURL: String
    let authToken: String

    static func load() -> SiriBackendConfig {
        let d = UserDefaults.standard
        return SiriBackendConfig(
            backendURL: d.string(forKey: "hv.backendURL") ?? "",
            authToken: d.string(forKey: "hv.authToken") ?? ""
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
    private static let stalenessSeconds: TimeInterval = 600

    static func load() -> SiriSession? {
        let d = UserDefaults.standard
        guard let id = d.string(forKey: idKey),
              !id.isEmpty,
              let ts = d.object(forKey: tsKey) as? Date,
              Date().timeIntervalSince(ts) <= stalenessSeconds
        else { return nil }
        return SiriSession(id: id, lastUsed: ts)
    }

    static func save(_ id: String) {
        guard !id.isEmpty else { return }
        let d = UserDefaults.standard
        d.set(id, forKey: idKey)
        d.set(Date(), forKey: tsKey)
    }
}

/// The Siri-invocable intent. Users say "Hey Siri, ask Hermes <question>".
/// Returns the assistant's text as a spoken dialog (system TTS).
struct AskHermesIntent: AppIntent {
    static var title: LocalizedStringResource = "Ask Hermes"
    // NOTE: Apple rejects App Intent descriptions that reference Apple
    // product/OS names ("Mac", "iPhone", etc.) — ITMS-90626. Keep this
    // platform-name-free.
    static var description = IntentDescription(
        "Ask Hermes anything. Sends your question to your self-hosted Hermes agent and speaks the reply.",
        categoryName: "Voice"
    )

    /// `openAppWhenRun = false` keeps the interaction in Siri/Shortcuts UI;
    /// the app does not foreground. That's the hands-free behavior we want
    /// from CarPlay, watch, or a locked phone.
    static var openAppWhenRun: Bool = false

    @Parameter(
        title: "Question",
        description: "What to ask Hermes.",
        requestValueDialog: "What should I ask Hermes?"
    )
    var prompt: String

    static var parameterSummary: some ParameterSummary {
        Summary("Ask Hermes \(\.$prompt)")
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let config = SiriBackendConfig.load()
        guard !config.backendURL.isEmpty else {
            return .result(dialog: "Hermes Voice isn't configured yet. Open the Hermes app and set your backend URL first.")
        }

        let api = HermesVoiceAPI(baseURL: config.backendURL, authToken: config.authToken)
        let session = SiriSession.load()

        do {
            let response = try await api.sendText(prompt, sessionId: session?.id)
            SiriSession.save(response.sessionId)
            let spoken = response.assistantText.isEmpty
                ? "Hermes didn't have anything to say."
                : response.assistantText
            return .result(dialog: IntentDialog(stringLiteral: spoken))
        } catch let HermesVoiceAPI.APIError.httpStatus(code, _) where code == 401 {
            return .result(dialog: "Hermes is rejecting my auth token. Check the app's settings.")
        } catch {
            return .result(dialog: "Sorry, I couldn't reach Hermes. \(error.localizedDescription)")
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
///   You: "Hey Siri, ask Hermes"
///   Siri: "What should I ask Hermes?"
///   You: "What time is sunset tonight?"
///   Siri: (speaks Hermes' reply)
///
/// The `\(.applicationName)` token resolves to CFBundleDisplayName, which
/// is "Hermes" (see project.yml).
struct HermesVoiceShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: AskHermesIntent(),
            phrases: [
                "Ask \(.applicationName)",
                "Tell \(.applicationName)",
                "Talk to \(.applicationName)",
            ],
            shortTitle: "Ask Hermes",
            systemImageName: "mic.fill"
        )
    }
}
