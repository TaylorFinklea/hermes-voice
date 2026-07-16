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
    /// The token each backend ACTUALLY holds, keyed by backend URL — distinct
    /// from `settings.lastApnsToken`, which is the single last token RECEIVED
    /// from APNs. A registration succeeds against ONE backend, so the record is
    /// per-backend: a single global "last registered token" cannot describe two
    /// backends mid-switch (a trailing re-register for A and a DELETE for A both
    /// need A's own token even after the active backend has flipped to B). Used
    /// to (a) unregister the token a backend actually holds on a switch and
    /// (b) decide whether a coalescing tail is still targeting the active
    /// backend. In-memory only — registration re-runs at every launch, so this
    /// never needs persisting.
    private var registeredTokens: [String: String] = [:]

    /// Immutable snapshot of the backend a single registration flow targets,
    /// bound at the START of that flow. The registration POST and its coalescing
    /// tail both go to this snapshot — never to live `settings` — so a switch
    /// that flips the active backend mid-flight can't redirect an in-flight
    /// registration to the wrong server.
    private struct RegistrationTarget {
        let url: String
        let authToken: String
    }
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
        // Bind the target to the active backend the instant we claim the
        // in-flight slot — both are read synchronously on the MainActor, so the
        // snapshot and the slot are taken atomically.
        let target = RegistrationTarget(url: settings.backendURL, authToken: settings.authToken)
        Task { @MainActor in
            defer { self.registrationInFlight = false }
            await self.performRegistrationCoalescing(token: token, target: target, settings: settings)
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
            // Snapshot the target AFTER the wait: this is the post-switch
            // re-register, so it must bind whichever backend is active once any
            // in-flight registration has drained (a switch that completed while
            // we waited).
            let target = RegistrationTarget(url: settings.backendURL, authToken: settings.authToken)
            await self.performRegistrationCoalescing(token: token, target: target, settings: settings)
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
            // Unregister the token `previous` ACTUALLY holds. Read it from the
            // per-backend record keyed by `previous.url`, which tracks exactly
            // what was registered with that backend even after a mid-switch APNs
            // rotation (the single global `lastApnsToken` would be the last
            // RECEIVED token, possibly newer than what `previous` holds). Fall
            // back to the cached received token only when nothing has registered
            // for `previous` yet. Captured AFTER the wait so it reflects any
            // registration that just completed (and its coalescing tail).
            let token = self.registeredTokens[previous.url] ?? settings.lastApnsToken
            if !token.isEmpty {
                let oldAPI = HermesVoiceAPI(baseURL: previous.url, authToken: previous.authToken)
                do {
                    try await oldAPI.unregisterDevice(token: token)
                    // `previous` no longer holds THIS token — but only drop the
                    // record if it still describes the token we just deleted. A
                    // delayed DELETE response must not erase a NEWER registration's
                    // record: a rapid switch back can re-register this URL while
                    // our request was in flight, and that newer token is what a
                    // later switch away must DELETE.
                    if self.registeredTokens[previous.url] == token {
                        self.registeredTokens.removeValue(forKey: previous.url)
                    }
                } catch {
                    print("device-token unregister from previous backend failed: \(error)")
                }
            }
            self.registerSavedDeviceWithActiveBackendIfNeeded()
        }
    }

    /// Runs one registration against `target`, then coalesces a mid-registration
    /// token rotation: if APNs delivered a newer token while we were registering
    /// `token` (the cached received token now differs from what we just
    /// attempted), register that newer token against the SAME `target` exactly
    /// ONCE more. A burst of rotations collapses to a single trailing
    /// re-register; a rotation during the follow-up coalesces the same way.
    /// Comparing against the just-attempted `token` (not the last
    /// successfully-registered token) means a failed registration with no newer
    /// token stops here instead of retrying in a loop.
    ///
    /// The trailing re-register is SKIPPED when `target` is no longer the active
    /// backend: that means a switch is/was in progress, and re-reading the
    /// rotated token onto `target` would either post to a server we just left or
    /// (worse, if we followed live settings) leak the old backend's rotation to
    /// the new one. The switch's DELETE cleans `target` up using its per-backend
    /// record instead.
    private func performRegistrationCoalescing(
        token: String, target: RegistrationTarget, settings: AppSettings
    ) async {
        await performRegistration(token: token, target: target)
        let received = settings.lastApnsToken
        guard !received.isEmpty, received != token else { return }
        guard target.url == settings.backendURL else { return }
        await performRegistrationCoalescing(token: received, target: target, settings: settings)
    }

    private func performRegistration(token: String, target: RegistrationTarget) async {
        let api = HermesVoiceAPI(
            baseURL: target.url, authToken: target.authToken
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
            // `handleAPNsToken`). Record which token THIS backend now actually
            // holds — keyed by its URL — so a switch DELETE unregisters the
            // token the backend really has rather than the last received one.
            self.registeredTokens[target.url] = token
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
