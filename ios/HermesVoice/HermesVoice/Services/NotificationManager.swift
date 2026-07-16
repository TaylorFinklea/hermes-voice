import Foundation
import UIKit
import UserNotifications

/// Coordinates iOS push-notification permission, APNs device-token
/// registration, and foreground arrival handling.
///
/// Wired from `HermesVoiceApp.init` so token registration happens at launch
/// regardless of which screen the user opens first. Token registration
/// requires APNs delivery (real device or simulator with Apple Silicon Mac);
/// it silently fails on plain simulator runs.
@MainActor
final class NotificationManager: NSObject, ObservableObject {
    static let shared = NotificationManager()

    private weak var settings: AppSettings?
    private weak var conversation: ConversationViewModel?
    private var registrationInFlight = false
    /// The token most recently REGISTERED with a backend — distinct from
    /// `settings.lastApnsToken`, which is the last token RECEIVED from APNs.
    /// Nil until a registration succeeds. Used to (a) coalesce a token that
    /// rotated in mid-registration into a single trailing re-register and
    /// (b) unregister the token a backend actually holds on a switch.
    private var lastRegisteredToken: String?
    // A single owned player + guard for foreground scheduled-fire auto-play, so
    // we don't spawn a throwaway AVPlayer per arrival that fights the
    // conversation's player over the shared audio session.
    private var arrivalPlayer: AudioPlayer?
    private var arrivalInFlight = false
    private var arrivalTask: Task<Void, Never>?

    /// Most-recently-received scheduled-fire notification, if any. The hero
    /// pane reads this to render a small badge / route to the right session.
    @Published private(set) var lastScheduledArrival: ScheduledArrival?

    struct ScheduledArrival: Equatable {
        let scheduleId: String
        let sessionId: String
        let body: String
        let receivedAt: Date
        let wasForeground: Bool
    }

    private override init() {
        super.init()
        UNUserNotificationCenter.current().delegate = self
    }

    /// Called once from HermesVoiceApp.init. Stores a weak ref to settings
    /// so we can read backend URL / auth token + which features are on.
    func configure(settings: AppSettings) {
        self.settings = settings
    }

    /// Wire the conversation VM so foreground auto-play can defer to a live
    /// turn (don't fight an in-progress recording/playback).
    func attach(conversation: ConversationViewModel) {
        self.conversation = conversation
    }

    /// Clear the pending scheduled-arrival badge (after the user taps it to
    /// route into the session, or otherwise dismisses it).
    func clearArrival() {
        lastScheduledArrival = nil
    }

    /// Best-effort stop of an in-flight scheduled-fire auto-play (chime and/or
    /// TTS replay) — called when the user switches backend profiles mid-arrival
    /// so playback tied to the server they just left doesn't keep going.
    /// Cancelling `arrivalTask` unwinds it if still in the chime/network
    /// phase; `arrivalPlayer.stop()` (idempotent) covers the case where audio
    /// is already playing, since `AudioPlayer.play()` awaits a continuation
    /// that plain task cancellation doesn't resume. No-op when nothing is
    /// in flight.
    func stopForegroundPlayback() {
        guard arrivalInFlight else { return }
        print("scheduled-fire foreground auto-play stopped (backend switch)")
        arrivalTask?.cancel()
        arrivalPlayer?.stop()
    }

    /// Request authorization from the user. Safe to call repeatedly;
    /// iOS shows the system prompt only once and remembers the answer.
    func requestAuthorization() async -> Bool {
        do {
            return try await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound, .badge])
        } catch {
            return false
        }
    }

    /// Trigger APNs token registration. Apple Silicon Macs + real devices
    /// will eventually call `didRegisterForRemoteNotifications(deviceToken:)`
    /// in the app delegate; plain simulator silently does nothing.
    func registerForRemoteNotifications() {
        // SwiftUI lifecycle doesn't expose UIApplicationDelegate directly —
        // we use UIApplication.shared to nudge APNs registration.
        UIApplication.shared.registerForRemoteNotifications()
    }

    /// Called by AppDelegate when APNs hands us a device token.
    func handleAPNsToken(_ deviceToken: Data) {
        let hex = deviceToken.map { String(format: "%02hhx", $0) }.joined()
        guard let settings else { return }
        // Cache the token at RECEIPT — not only after a successful
        // registration. Otherwise a failed first registration would leave
        // `lastApnsToken` empty, and a later profile switch (which reads that
        // cached token via `registerSavedDeviceWithActiveBackendIfNeeded`)
        // couldn't register the device with the new backend at all.
        settings.lastApnsToken = hex
        registerToken(hex, settings: settings)
    }

    /// Called when iOS reports APNs registration failed. We log so it's
    /// visible in the Settings diagnostics view; production users don't see it.
    func handleAPNsRegistrationFailure(_ error: Error) {
        print("APNs registration failed: \(error.localizedDescription)")
    }

    private func registerToken(_ token: String, settings: AppSettings) {
        // An in-flight registration isn't dropped by this early return:
        // `handleAPNsToken` has already cached this token as
        // `settings.lastApnsToken`, and the in-flight registration's coalescing
        // tail re-registers the newest received token once it finishes.
        guard !registrationInFlight else { return }
        registrationInFlight = true
        Task { @MainActor in
            defer { self.registrationInFlight = false }
            await self.performRegistrationCoalescing(token: token, settings: settings)
        }
    }

    /// Re-registers the already-captured APNs token with whichever backend
    /// is currently active. APNs v1 is active-only (no per-profile
    /// registration) — only the backend you're currently pointed at should
    /// hold your device token, so this is what a profile switch calls to
    /// pick the new backend up. No-op when notifications are off or no
    /// token has ever been captured. Unlike `registerToken`'s early return,
    /// a registration still in flight is waited out and retried once
    /// (rather than silently dropping the switch-triggered registration) —
    /// still a single attempt, not a queue.
    func registerSavedDeviceWithActiveBackendIfNeeded() {
        guard let settings else { return }
        guard settings.notificationsEnabled, !settings.lastApnsToken.isEmpty else { return }
        let token = settings.lastApnsToken
        Task { @MainActor in
            while self.registrationInFlight {
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            self.registrationInFlight = true
            defer { self.registrationInFlight = false }
            await self.performRegistrationCoalescing(token: token, settings: settings)
        }
    }

    /// Called after the active backend profile changes. Best-effort
    /// UNregisters the saved device token from `previous`'s backend — a
    /// failure is logged and never blocks the new registration (design
    /// rule: v1 has no retry queue for unregister) — then re-registers with
    /// the now-active backend via `registerSavedDeviceWithActiveBackendIfNeeded()`.
    func handleBackendSwitch(previous: BackendProfile) {
        guard let settings else { return }
        Task { @MainActor in
            // Wait out any in-flight registration BEFORE the DELETE. Otherwise
            // a stale in-flight POST to the PREVIOUS backend could complete
            // AFTER our unregister and silently re-register the old backend.
            // Same single-attempt wait `registerSavedDeviceWithActiveBackendIfNeeded`
            // performs before its POST — no queue, just don't race the DELETE.
            while self.registrationInFlight {
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            // Unregister the token `previous` ACTUALLY holds. A mid-switch APNs
            // rotation can leave `settings.lastApnsToken` (last RECEIVED) newer
            // than what was registered, so prefer the last-registered token and
            // fall back to the cached one only when nothing has registered yet.
            // Captured AFTER the wait so it reflects any registration that just
            // completed (and its coalescing tail).
            let token = self.lastRegisteredToken ?? settings.lastApnsToken
            if !token.isEmpty {
                let oldAPI = HermesVoiceAPI(baseURL: previous.url, authToken: previous.authToken)
                do {
                    try await oldAPI.unregisterDevice(token: token)
                } catch {
                    print("device-token unregister from previous backend failed: \(error)")
                }
            }
            self.registerSavedDeviceWithActiveBackendIfNeeded()
        }
    }

    /// Runs one registration, then coalesces a mid-registration token rotation:
    /// if APNs delivered a newer token while we were registering `token` (the
    /// cached received token now differs from what we just attempted), register
    /// that newer token exactly ONCE more. A burst of rotations collapses to a
    /// single trailing re-register; a rotation during the follow-up coalesces
    /// the same way. Comparing against the just-attempted `token` (not the last
    /// successfully-registered token) means a failed registration with no newer
    /// token stops here instead of retrying in a loop.
    private func performRegistrationCoalescing(token: String, settings: AppSettings) async {
        await performRegistration(token: token, settings: settings)
        let received = settings.lastApnsToken
        guard !received.isEmpty, received != token else { return }
        await performRegistrationCoalescing(token: received, settings: settings)
    }

    private func performRegistration(token: String, settings: AppSettings) async {
        let api = HermesVoiceAPI(
            baseURL: settings.backendURL, authToken: settings.authToken
        )
        let bundleId = Bundle.main.bundleIdentifier ?? "dev.finklea.harnessvoice"
        // iOS apps built with debug provisioning use the APNs sandbox env;
        // TestFlight + App Store use production. The TARGET_OS_SIMULATOR
        // and debug-vs-release split is the standard signal.
        #if DEBUG
        let env = "sandbox"
        #else
        let env = "production"
        #endif
        do {
            _ = try await api.registerDevice(
                token: token,
                platform: "ios",
                bundleId: bundleId,
                environment: env
            )
            // `settings.lastApnsToken` is already cached at receipt (see
            // `handleAPNsToken`). Record which token this backend now actually
            // holds so a switch DELETE and the coalescing check use the
            // registered token rather than the last received one.
            self.lastRegisteredToken = token
        } catch {
            // Backend down or token rejected. Token cached locally so
            // we retry next launch; no error UI here (this is silent).
            print("device-token registration failed: \(error)")
        }
    }
}

// MARK: - Notification delivery

extension NotificationManager: UNUserNotificationCenterDelegate {
    /// Foreground arrival. Suppresses the system banner and routes into
    /// the in-app chime + auto-play flow.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler:
            @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        let arrival = parseArrival(from: notification, wasForeground: true)
        if let arrival {
            lastScheduledArrival = arrival
            // Only auto-play when the user isn't mid-conversation (don't fight
            // the live turn's player/session) and no other arrival is playing;
            // otherwise fall through to the banner.
            let idle = (conversation?.state ?? .idle) == .idle
            if (settings?.autoPlayScheduledFires ?? true) && idle && !arrivalInFlight {
                arrivalTask = Task { await handleForegroundArrival(arrival) }
                // Suppress the system banner — we play the chime + audio
                // through our in-app path instead.
                completionHandler([])
                return
            }
        }
        // Non-schedule notifications, auto-play disabled, or busy: show the banner.
        completionHandler([.banner, .sound, .list])
    }

    /// Tap from a backgrounded / locked notification. We open the app
    /// and route to the matching session so the user can replay it.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        if let arrival = parseArrival(from: response.notification, wasForeground: false) {
            lastScheduledArrival = arrival
        }
        completionHandler()
    }

    private func parseArrival(
        from notification: UNNotification, wasForeground: Bool
    ) -> ScheduledArrival? {
        let info = notification.request.content.userInfo
        guard let scheduleId = info["schedule_id"] as? String,
              let sessionId = info["session_id"] as? String else {
            return nil
        }
        return ScheduledArrival(
            scheduleId: scheduleId,
            sessionId: sessionId,
            body: notification.request.content.body,
            receivedAt: Date(),
            wasForeground: wasForeground,
        )
    }

    private func handleForegroundArrival(_ arrival: ScheduledArrival) async {
        // Play the chime (if enabled), then re-synthesize TTS for the reply and
        // play it. Gated to idle in willPresent, so we own the audio session +
        // Live Activity here without fighting the conversation player.
        guard let settings else { return }
        arrivalInFlight = true
        // Hold the session across chime → reply so they don't churn it between
        // them; the leaf players nest their own (ref-counted) holds.
        AudioSessionCoordinator.shared.acquire(.playback)
        // Surface the reply on the lock screen / Dynamic Island for the
        // duration of playback — this is exactly when the phone is likely
        // locked or pocketed.
        LiveActivityController.shared.showSpeaking(detail: arrival.body)
        defer {
            LiveActivityController.shared.finish()
            AudioSessionCoordinator.shared.release()
            arrivalPlayer = nil
            arrivalInFlight = false
            arrivalTask = nil
        }

        if settings.foregroundChimeEnabled {
            await ChimePlayer.shared.play()
        }

        // Replay via the existing /api/replay endpoint — this re-synthesizes
        // the reply text fresh (push body is text, not the original audio).
        let api = HermesVoiceAPI(baseURL: settings.backendURL, authToken: settings.authToken)
        do {
            let path = try await api.replayAudio(text: arrival.body, voiceId: settings.selectedVoiceId)
            guard let url = api.makeURL(path: path) else { return }
            let player = AudioPlayer()
            arrivalPlayer = player
            await player.play(url: url, authToken: settings.authToken)
        } catch {
            print("scheduled-fire auto-play failed: \(error)")
        }
    }
}
