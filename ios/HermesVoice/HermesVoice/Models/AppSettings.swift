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

    /// The UserDefaults suite backing every persisted property. Injected so
    /// tests can use an isolated suite instead of `.standard`. Internal (not
    /// private) so other app-side helpers that need to touch the SAME suite
    /// (e.g. `SiriSession.clear` from a routing-affecting change) can read it
    /// instead of hard-coding `.standard`.
    let defaults: UserDefaults

    /// The fresh-install / never-configured backend URL. Used both to seed a
    /// brand-new profile and to detect "not really configured yet" (onboarding
    /// gate, Siri's pre-onboarding guard) — a persisted profile can carry this
    /// exact URL after migration without the user ever having set one.
    static let defaultBackendURL = "http://127.0.0.1:8765"

    /// The URL, auth token, and harness of the active backend profile. Kept
    /// as top-level published properties (rather than reading through
    /// `activeBackendProfile` everywhere) so existing `HermesVoiceAPI` call
    /// sites keep compiling unchanged. Setting one of these updates the
    /// active profile in `backendProfiles` and mirrors the legacy
    /// `hv.backendURL` / `hv.authToken` / `hv.selectedHarness` keys that
    /// `AskHermesIntent` reads directly.
    @Published var backendURL: String {
        didSet {
            defaults.set(backendURL, forKey: Keys.backendURL)
            updateActiveProfile { $0.url = backendURL }
        }
    }

    @Published var authToken: String {
        didSet {
            defaults.set(authToken, forKey: Keys.authToken)
            updateActiveProfile { $0.authToken = authToken }
        }
    }

    @Published var mode: Mode {
        didSet { defaults.set(mode.rawValue, forKey: Keys.mode) }
    }

    /// When true, Watch turns get their audio reply too: iPhone downloads
    /// the audio from the backend then transfers the file to Watch via
    /// WCSession.transferFile. When false (default), Watch shows text and
    /// haptic only.
    @Published var playReplyOnWatch: Bool {
        didSet { defaults.set(playReplyOnWatch, forKey: Keys.playReplyOnWatch) }
    }

    /// Last time we successfully reached the backend's /health endpoint.
    /// Updated by any successful API call; displayed in Settings → Diagnostics
    /// so you can spot the moment your backend went unreachable.
    @Published var lastReachable: Date? {
        didSet { defaults.set(lastReachable, forKey: Keys.lastReachable) }
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
        didSet { defaults.set(notificationsEnabled, forKey: Keys.notificationsEnabled) }
    }

    /// When a scheduled fire arrives and the app is open, automatically
    /// play the reply audio (with a chime preamble). Off → just show the
    /// banner like a normal notification.
    @Published var autoPlayScheduledFires: Bool {
        didSet { defaults.set(autoPlayScheduledFires, forKey: Keys.autoPlayScheduledFires) }
    }

    /// Play the chime before TTS during foreground auto-play. Off →
    /// audio starts cold (not recommended; "freak out" risk).
    @Published var foregroundChimeEnabled: Bool {
        didSet { defaults.set(foregroundChimeEnabled, forKey: Keys.foregroundChimeEnabled) }
    }

    /// Last APNs device token RECEIVED from APNs — not necessarily the one a
    /// backend currently holds (NotificationManager tracks the registered token
    /// separately). Stored so a later profile switch can register this device
    /// with the new backend, and diagnostics can show the token.
    @Published var lastApnsToken: String {
        didSet { defaults.set(lastApnsToken, forKey: Keys.lastApnsToken) }
    }

    // ───── Onboarding ─────

    /// Set true once the user completes first-launch onboarding (a backend URL
    /// was entered or discovered and a connection test passed). Gates the app:
    /// false → OnboardingView, true → MainView.
    @Published var hasCompletedOnboarding: Bool {
        didSet { defaults.set(hasCompletedOnboarding, forKey: Keys.hasCompletedOnboarding) }
    }

    // ───── Voice ─────

    /// Selected ElevenLabs voice id. Empty → use the backend's configured
    /// default voice. Sent with each turn/replay request.
    @Published var selectedVoiceId: String {
        didSet { defaults.set(selectedVoiceId, forKey: Keys.selectedVoiceId) }
    }

    /// Transcribe mic turns on-device (parakeet via FluidAudio) instead of
    /// uploading audio for server STT. Defaults ON, but it's a no-op until the
    /// model is downloaded in Settings — until then (and if local transcription
    /// ever fails) the turn falls back to the audio-upload path, so there's no
    /// regression. See `LocalTranscriber`.
    @Published var useOnDeviceSTT: Bool {
        didSet { defaults.set(useOnDeviceSTT, forKey: Keys.useOnDeviceSTT) }
    }

    /// How much Harness talks while it works (on-device voice only). Gates the
    /// spoken filler: off → silent; quiet → instant ack only; normal → ack +
    /// per-tool narration (default / today's behavior); chatty → adds a periodic
    /// "still working" heartbeat during long silent gaps.
    @Published var fillerVerbosity: FillerVerbosity {
        didSet { defaults.set(fillerVerbosity.rawValue, forKey: Keys.fillerVerbosity) }
    }

    // ───── Harness (which agent backs a turn) ─────

    /// The agent backend a turn is routed to: "hermes" (default), "claude",
    /// "codex", or "opencode". Sent as the `harness` field on each turn; the
    /// backend dispatches to the matching adapter. Options come from
    /// `/api/harnesses`. Empty would mean the backend default, but we persist a
    /// concrete id so the picker reflects the active choice.
    @Published var selectedHarness: String {
        didSet {
            defaults.set(selectedHarness, forKey: Keys.selectedHarness)
            updateActiveProfile { $0.selectedHarness = selectedHarness }
        }
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

    // ───── Backend profiles ─────

    /// Every saved backend connection, one per laptop/server. Always has at
    /// least one entry — the active one — so `activeBackendProfile` never
    /// needs to handle an empty collection.
    @Published private(set) var backendProfiles: [BackendProfile]

    /// The id of the profile currently backing `backendURL` / `authToken` /
    /// `selectedHarness`.
    @Published private(set) var activeProfileId: UUID

    /// The profile currently backing `backendURL` / `authToken` /
    /// `selectedHarness`.
    var activeBackendProfile: BackendProfile {
        backendProfiles.first(where: { $0.id == activeProfileId }) ?? backendProfiles[0]
    }

    /// Switches the active profile, restoring its URL/token/harness onto the
    /// top-level published properties (and, via their `didSet`s, the legacy
    /// mirror keys). Also clears `lastReachable`, since that diagnostic
    /// describes the previous server, not the one just switched to. Returns
    /// false for an unknown id, leaving state unchanged.
    @discardableResult
    func activateProfile(id: UUID) -> Bool {
        guard let profile = backendProfiles.first(where: { $0.id == id }) else { return false }
        activeProfileId = id
        backendURL = profile.url
        authToken = profile.authToken
        selectedHarness = profile.selectedHarness
        lastReachable = nil
        persistActiveProfileId()
        return true
    }

    /// Inserts a new profile or replaces the existing one with the same id.
    /// Falls back to `BackendProfile.suggestedName(for:)` rather than
    /// persisting a blank name. If the saved profile is the active one, the
    /// top-level URL/token/harness properties are refreshed to match.
    func saveProfile(_ profile: BackendProfile) {
        var toSave = profile
        if toSave.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            toSave.name = BackendProfile.suggestedName(for: toSave.url)
        }

        if let index = backendProfiles.firstIndex(where: { $0.id == toSave.id }) {
            backendProfiles[index] = toSave
        } else {
            backendProfiles.append(toSave)
        }
        persistProfiles()

        if toSave.id == activeProfileId {
            backendURL = toSave.url
            authToken = toSave.authToken
            selectedHarness = toSave.selectedHarness
        }
    }

    /// Deletes a profile. Returns false (no-op) when `id` is the active
    /// profile, the only remaining profile, or unknown — there must always
    /// be an active profile to fall back to.
    @discardableResult
    func removeProfile(id: UUID) -> Bool {
        guard backendProfiles.count > 1,
              id != activeProfileId,
              let index = backendProfiles.firstIndex(where: { $0.id == id })
        else { return false }
        backendProfiles.remove(at: index)
        persistProfiles()
        return true
    }

    /// Applies `mutate` to the active profile's record in `backendProfiles`
    /// and persists the collection. Backs the `didSet`s of `backendURL` /
    /// `authToken` / `selectedHarness` so those properties stay views onto
    /// the active profile.
    private func updateActiveProfile(_ mutate: (inout BackendProfile) -> Void) {
        guard let index = backendProfiles.firstIndex(where: { $0.id == activeProfileId }) else { return }
        mutate(&backendProfiles[index])
        persistProfiles()
    }

    private func persistProfiles() {
        guard let data = try? JSONEncoder().encode(backendProfiles) else { return }
        defaults.set(data, forKey: Keys.backendProfiles)
    }

    private func persistActiveProfileId() {
        defaults.set(activeProfileId.uuidString, forKey: Keys.activeBackendProfileId)
    }

    /// Non-observable read of the active backend profile, for contexts (App
    /// Intents) that run outside the app process and must not construct an
    /// observable `AppSettings` (no Combine machinery, no migration writes)
    /// just to read a URL/token. Reads the SAME persisted profile payload
    /// keys the instance init above decodes. Returns nil when no profile
    /// payload exists yet — callers fall back to the legacy raw keys.
    static func readActiveProfile(defaults: UserDefaults = .standard) -> BackendProfile? {
        guard let data = defaults.data(forKey: Keys.backendProfiles),
              let decoded = try? JSONDecoder().decode([BackendProfile].self, from: data),
              !decoded.isEmpty
        else { return nil }
        if let idString = defaults.string(forKey: Keys.activeBackendProfileId),
           let uuid = UUID(uuidString: idString),
           let match = decoded.first(where: { $0.id == uuid }) {
            return match
        }
        return decoded.first
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let d = defaults

        // Legacy single-backend values. Used as the migration source when no
        // profile payload exists yet, and (for backendURL, on that same
        // no-payload path) to preserve the existing fresh-install onboarding
        // gate below.
        let legacyURL = d.string(forKey: Keys.backendURL) ?? Self.defaultBackendURL
        let legacyToken = d.string(forKey: Keys.authToken) ?? ""
        let legacyHarness = d.string(forKey: Keys.selectedHarness) ?? "hermes"

        let decodedProfiles: [BackendProfile]? = {
            guard let data = d.data(forKey: Keys.backendProfiles),
                  let decoded = try? JSONDecoder().decode([BackendProfile].self, from: data),
                  !decoded.isEmpty
            else { return nil }
            return decoded
        }()

        let profiles: [BackendProfile]
        let activeId: UUID
        var needsMigrationPersist = false
        var needsActiveIdRepair = false
        if let decoded = decodedProfiles {
            profiles = decoded
            if let idString = d.string(forKey: Keys.activeBackendProfileId),
               let uuid = UUID(uuidString: idString),
               decoded.contains(where: { $0.id == uuid }) {
                activeId = uuid
            } else {
                // Persisted active id is missing or points at a profile that
                // no longer exists — fall back to the first profile and
                // repair the stored state below so later reads/writes agree.
                activeId = decoded[0].id
                needsActiveIdRepair = true
            }
        } else {
            // No profile payload yet — migrate the legacy single-backend
            // values (or fresh-install defaults) into exactly one profile.
            let migrated = BackendProfile(
                name: BackendProfile.suggestedName(for: legacyURL),
                url: legacyURL,
                authToken: legacyToken,
                selectedHarness: legacyHarness
            )
            profiles = [migrated]
            activeId = migrated.id
            needsMigrationPersist = true
        }

        self.backendProfiles = profiles
        self.activeProfileId = activeId

        let active = profiles.first(where: { $0.id == activeId }) ?? profiles[0]
        self.backendURL = active.url
        self.authToken = active.authToken
        self.selectedHarness = active.selectedHarness

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
        // Onboarding shows on a fresh install (default URL + flag unset). Treat
        // an already-configured non-default backend as onboarded so upgraders
        // aren't bounced back through onboarding. When a profile payload was
        // decoded, the inference must reflect the ACTIVE profile's URL (the
        // legacy key can be stale once profiles diverge), not the raw legacy
        // key; the no-payload migration path keeps using legacyURL as before.
        let onboardingURL = decodedProfiles != nil ? active.url : legacyURL
        let configured = onboardingURL != Self.defaultBackendURL && !onboardingURL.isEmpty
        self.hasCompletedOnboarding = d.bool(forKey: Keys.hasCompletedOnboarding) || configured

        if needsMigrationPersist {
            persistProfiles()
            persistActiveProfileId()
        } else if needsActiveIdRepair {
            persistActiveProfileId()
            d.set(active.url, forKey: Keys.backendURL)
            d.set(active.authToken, forKey: Keys.authToken)
            d.set(active.selectedHarness, forKey: Keys.selectedHarness)
        }
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
        static let backendProfiles = "hv.backendProfiles"
        static let activeBackendProfileId = "hv.activeBackendProfileId"
    }
}
