import Foundation
import Combine

/// User-facing settings. Persisted in UserDefaults so they survive launches.
final class AppSettings: ObservableObject {
    enum Mode: String, CaseIterable, Identifiable {
        case audio
        case textTest
        var id: String { rawValue }
        var label: String {
            switch self {
            case .audio: return "Audio (mic)"
            case .textTest: return "Text test"
            }
        }
    }

    @Published var backendURL: String {
        didSet { UserDefaults.standard.set(backendURL, forKey: Keys.backendURL) }
    }

    @Published var authToken: String {
        didSet { UserDefaults.standard.set(authToken, forKey: Keys.authToken) }
    }

    @Published var mode: Mode {
        didSet { UserDefaults.standard.set(mode.rawValue, forKey: Keys.mode) }
    }

    /// When true, Watch turns get their audio reply too: iPhone downloads
    /// the audio from the backend then transfers the file to Watch via
    /// WCSession.transferFile. When false (default), Watch shows text and
    /// haptic only.
    @Published var playReplyOnWatch: Bool {
        didSet { UserDefaults.standard.set(playReplyOnWatch, forKey: Keys.playReplyOnWatch) }
    }

    /// Last time we successfully reached the backend's /health endpoint.
    /// Updated by any successful API call; displayed in Settings → Diagnostics
    /// so you can spot the moment your backend went unreachable.
    @Published var lastReachable: Date? {
        didSet { UserDefaults.standard.set(lastReachable, forKey: Keys.lastReachable) }
    }

    func markReachable() { lastReachable = Date() }

    // ───── Phase B: schedules push notifications ─────

    /// Has the user opted into receiving notifications for scheduled fires?
    /// Separate from iOS permission — this is the in-app on/off switch.
    @Published var notificationsEnabled: Bool {
        didSet { UserDefaults.standard.set(notificationsEnabled, forKey: Keys.notificationsEnabled) }
    }

    /// When a scheduled fire arrives and the app is open, automatically
    /// play the reply audio (with a chime preamble). Off → just show the
    /// banner like a normal notification.
    @Published var autoPlayScheduledFires: Bool {
        didSet { UserDefaults.standard.set(autoPlayScheduledFires, forKey: Keys.autoPlayScheduledFires) }
    }

    /// Play the chime before TTS during foreground auto-play. Off →
    /// audio starts cold (not recommended; "freak out" risk).
    @Published var foregroundChimeEnabled: Bool {
        didSet { UserDefaults.standard.set(foregroundChimeEnabled, forKey: Keys.foregroundChimeEnabled) }
    }

    /// Last APNs device token we registered with the backend. Stored so
    /// the diagnostics view can show what's registered; not used to skip
    /// re-registration (NotificationManager handles that).
    @Published var lastApnsToken: String {
        didSet { UserDefaults.standard.set(lastApnsToken, forKey: Keys.lastApnsToken) }
    }

    init() {
        let d = UserDefaults.standard
        self.backendURL = d.string(forKey: Keys.backendURL) ?? "http://127.0.0.1:8765"
        self.authToken = d.string(forKey: Keys.authToken) ?? ""
        let raw = d.string(forKey: Keys.mode) ?? Mode.audio.rawValue
        self.mode = Mode(rawValue: raw) ?? .audio
        self.lastReachable = d.object(forKey: Keys.lastReachable) as? Date
        self.playReplyOnWatch = d.bool(forKey: Keys.playReplyOnWatch)
        self.notificationsEnabled = d.bool(forKey: Keys.notificationsEnabled)
        // Defaults: ON for both. We want chime + auto-play to be the
        // out-of-box behavior so "freak out" risk stays mitigated.
        self.autoPlayScheduledFires = d.object(forKey: Keys.autoPlayScheduledFires)
            as? Bool ?? true
        self.foregroundChimeEnabled = d.object(forKey: Keys.foregroundChimeEnabled)
            as? Bool ?? true
        self.lastApnsToken = d.string(forKey: Keys.lastApnsToken) ?? ""
    }

    private enum Keys {
        static let backendURL = "hv.backendURL"
        static let authToken = "hv.authToken"
        static let mode = "hv.mode"
        static let lastReachable = "hv.lastReachable"
        static let playReplyOnWatch = "hv.playReplyOnWatch"
        static let notificationsEnabled = "hv.notificationsEnabled"
        static let autoPlayScheduledFires = "hv.autoPlayScheduledFires"
        static let foregroundChimeEnabled = "hv.foregroundChimeEnabled"
        static let lastApnsToken = "hv.lastApnsToken"
    }
}
