import Foundation
import Combine
import SwiftUI

/// How chatty the on-device spoken filler is while a turn works. Gates the
/// existing filler behavior (instant ack + per-tool narration + heartbeat) — the
/// backend keeps emitting `narrate` events regardless; the app decides what to
/// SPEAK. Ordered off < quiet < normal < chatty; default `.normal` = today's
/// behavior (ack + per-tool narration).
enum FillerVerbosity: String, CaseIterable, Codable, Comparable, Identifiable {
    case off
    case quiet
    case normal
    case chatty

    var id: String { rawValue }

    /// Sort order, used by `Comparable` and the `>= .normal` gates.
    private var rank: Int {
        switch self {
        case .off: return 0
        case .quiet: return 1
        case .normal: return 2
        case .chatty: return 3
        }
    }

    static func < (lhs: FillerVerbosity, rhs: FillerVerbosity) -> Bool {
        lhs.rank < rhs.rank
    }

    /// User-facing label for the Settings picker.
    var label: String {
        switch self {
        case .off: return "Off"
        case .quiet: return "Quiet"
        case .normal: return "Normal"
        case .chatty: return "Chatty"
        }
    }
}

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

    /// True when the chosen voice is an on-device (Apple) voice. These are stored
    /// in `selectedVoiceId` with a `local:` prefix (e.g. `local:en-US-female`) so
    /// one picker covers both server (ElevenLabs) and on-device voices. When true,
    /// the turn tells the backend `tts=none` and the phone speaks the reply.
    var isLocalVoiceSelected: Bool { selectedVoiceId.hasPrefix("local:") }

    /// The on-device voice id when a local voice is selected (else the default).
    var localVoiceName: String {
        guard isLocalVoiceSelected else { return LocalSpeaker.defaultVoice }
        return String(selectedVoiceId.dropFirst("local:".count))
    }

    /// The `voice_id` to send to the backend: a local voice must NOT be sent as
    /// `voice_id` (it isn't an ElevenLabs id, and the colon fails server
    /// validation), so it resolves to empty → server uses its default / no TTS.
    var serverVoiceId: String { isLocalVoiceSelected ? "" : selectedVoiceId }

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

    // ───── Onboarding ─────

    /// Set true once the user completes first-launch onboarding (a backend URL
    /// was entered or discovered and a connection test passed). Gates the app:
    /// false → OnboardingView, true → MainView.
    @Published var hasCompletedOnboarding: Bool {
        didSet { UserDefaults.standard.set(hasCompletedOnboarding, forKey: Keys.hasCompletedOnboarding) }
    }

    // ───── Voice ─────

    /// Selected ElevenLabs voice id. Empty → use the backend's configured
    /// default voice. Sent with each turn/replay request.
    @Published var selectedVoiceId: String {
        didSet { UserDefaults.standard.set(selectedVoiceId, forKey: Keys.selectedVoiceId) }
    }

    /// Transcribe mic turns on-device (parakeet via FluidAudio) instead of
    /// uploading audio for server STT. Defaults ON, but it's a no-op until the
    /// model is downloaded in Settings — until then (and if local transcription
    /// ever fails) the turn falls back to the audio-upload path, so there's no
    /// regression. See `LocalTranscriber`.
    @Published var useOnDeviceSTT: Bool {
        didSet { UserDefaults.standard.set(useOnDeviceSTT, forKey: Keys.useOnDeviceSTT) }
    }

    /// How much Harness talks while it works (on-device voice only). Gates the
    /// spoken filler: off → silent; quiet → instant ack only; normal → ack +
    /// per-tool narration (default / today's behavior); chatty → adds a periodic
    /// "still working" heartbeat during long silent gaps.
    @Published var fillerVerbosity: FillerVerbosity {
        didSet { UserDefaults.standard.set(fillerVerbosity.rawValue, forKey: Keys.fillerVerbosity) }
    }

    // ───── Harness (which agent backs a turn) ─────

    /// The agent backend a turn is routed to: "hermes" (default), "claude",
    /// "codex", or "opencode". Sent as the `harness` field on each turn; the
    /// backend dispatches to the matching adapter. Options come from
    /// `/api/harnesses`. Empty would mean the backend default, but we persist a
    /// concrete id so the picker reflects the active choice.
    @Published var selectedHarness: String {
        didSet { UserDefaults.standard.set(selectedHarness, forKey: Keys.selectedHarness) }
    }

    /// Short uppercase label for the active agent, for the state chips
    /// ("CLAUDE IDLE", "HERMES THINKS").
    var activeAgentLabel: String {
        switch selectedHarness {
        case "claude": return "CLAUDE"
        case "codex": return "CODEX"
        case "opencode": return "OPENCODE"
        case "hermes": return "HERMES"
        default: return selectedHarness.uppercased()
        }
    }

    /// Title-bar text: the active agent + "VOICE" (HERMES VOICE / CLAUDE VOICE
    /// / …). Hermes is just another harness, so it gets the same treatment. The
    /// product brand ("Harness") lives on the home-screen icon + onboarding.
    var activeAgentTitle: String {
        "\(activeAgentLabel) VOICE"
    }

    /// A subtle per-agent accent for the header (title + toolbar tint). The rest
    /// of the palette stays the base amber so it doesn't get loud. Easy to tweak
    /// here, or later swap for a user-selectable picker.
    var agentAccent: Color {
        switch selectedHarness {
        case "claude": return Color(hex: 0xE8825A)    // warm coral / red-orange
        case "codex": return Color(hex: 0xE6E6E6)     // near-white (mono)
        case "opencode": return Color(hex: 0x9B8CFF)  // violet
        default: return HVColor.amber                 // hermes + fallback
        }
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
        self.selectedVoiceId = d.string(forKey: Keys.selectedVoiceId) ?? ""
        // Default ON: we want on-device transcription to be the out-of-box
        // behavior once the model is present. Harmless before download (falls
        // back to upload).
        self.useOnDeviceSTT = d.object(forKey: Keys.useOnDeviceSTT) as? Bool ?? true
        let fillerRaw = d.string(forKey: Keys.fillerVerbosity) ?? FillerVerbosity.normal.rawValue
        self.fillerVerbosity = FillerVerbosity(rawValue: fillerRaw) ?? .normal
        self.selectedHarness = d.string(forKey: Keys.selectedHarness) ?? "hermes"
        // Onboarding shows on a fresh install (default URL + flag unset). Treat
        // an already-configured non-default backend as onboarded so upgraders
        // aren't bounced back through onboarding.
        let savedURL = d.string(forKey: Keys.backendURL) ?? "http://127.0.0.1:8765"
        let configured = savedURL != "http://127.0.0.1:8765" && !savedURL.isEmpty
        self.hasCompletedOnboarding = d.bool(forKey: Keys.hasCompletedOnboarding) || configured
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
        static let hasCompletedOnboarding = "hv.hasCompletedOnboarding"
        static let selectedVoiceId = "hv.selectedVoiceId"
        static let useOnDeviceSTT = "hv.useOnDeviceSTT"
        static let fillerVerbosity = "hv.fillerVerbosity"
        static let selectedHarness = "hv.selectedHarness"
    }
}
