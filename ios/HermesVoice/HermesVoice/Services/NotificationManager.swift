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
    private var registrationInFlight = false

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

    /// Clear the pending scheduled-arrival badge (after the user taps it to
    /// route into the session, or otherwise dismisses it).
    func clearArrival() {
        lastScheduledArrival = nil
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
        registerToken(hex, settings: settings)
    }

    /// Called when iOS reports APNs registration failed. We log so it's
    /// visible in the Settings diagnostics view; production users don't see it.
    func handleAPNsRegistrationFailure(_ error: Error) {
        print("APNs registration failed: \(error.localizedDescription)")
    }

    private func registerToken(_ token: String, settings: AppSettings) {
        guard !registrationInFlight else { return }
        registrationInFlight = true

        let api = HermesVoiceAPI(
            baseURL: settings.backendURL, authToken: settings.authToken
        )
        let bundleId = Bundle.main.bundleIdentifier ?? "dev.finklea.hermesvoice"
        // iOS apps built with debug provisioning use the APNs sandbox env;
        // TestFlight + App Store use production. The TARGET_OS_SIMULATOR
        // and debug-vs-release split is the standard signal.
        #if DEBUG
        let env = "sandbox"
        #else
        let env = "production"
        #endif

        Task { @MainActor in
            defer { self.registrationInFlight = false }
            do {
                _ = try await api.registerDevice(
                    token: token,
                    platform: "ios",
                    bundleId: bundleId,
                    environment: env
                )
                settings.lastApnsToken = token
            } catch {
                // Backend down or token rejected. Token cached locally so
                // we retry next launch; no error UI here (this is silent).
                print("device-token registration failed: \(error)")
            }
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
            if settings?.autoPlayScheduledFires ?? true {
                Task { await handleForegroundArrival(arrival) }
                // Suppress the system banner — we play the chime + audio
                // through our in-app path instead.
                completionHandler([])
                return
            }
        }
        // Non-schedule notifications or auto-play disabled: show the banner.
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
        // Play the chime (if enabled), then re-synthesize TTS for the reply
        // text and play it through the same AudioPlayer the conversation uses.
        guard let settings else { return }
        if settings.foregroundChimeEnabled {
            await ChimePlayer.shared.play()
        }
        // Surface the reply on the lock screen / Dynamic Island for the
        // duration of playback — this is exactly when the phone is likely
        // locked or pocketed.
        LiveActivityController.shared.showSpeaking(detail: arrival.body)
        defer { LiveActivityController.shared.finish() }

        // Replay via the existing /api/replay endpoint — this re-synthesizes
        // the reply text fresh (push body is text, not the original audio).
        let api = HermesVoiceAPI(baseURL: settings.backendURL, authToken: settings.authToken)
        do {
            let path = try await api.replayAudio(text: arrival.body)
            guard let url = api.makeURL(path: path) else { return }
            await AudioPlayer().play(url: url, authToken: settings.authToken)
        } catch {
            print("scheduled-fire auto-play failed: \(error)")
        }
    }
}
