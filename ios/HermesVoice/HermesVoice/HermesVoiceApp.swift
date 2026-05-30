import SwiftUI

@main
struct HermesVoiceApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var settings = AppSettings()
    @StateObject private var conversation: ConversationViewModel

    init() {
        let settings = AppSettings()
        _settings = StateObject(wrappedValue: settings)
        let conversation = ConversationViewModel(settings: settings)
        _conversation = StateObject(wrappedValue: conversation)
        // Activate the WatchConnectivity bridge at app startup so audio
        // transfers from a paired Watch are handled even before any view
        // holds a reference. Singleton — safe to call repeatedly.
        PhoneWatchBridge.shared.start()
        // Wire push notifications. Permission prompt is deferred until the
        // user toggles it in Settings; this just hands the settings ref
        // to the manager and (if previously authorized) primes registration.
        NotificationManager.shared.configure(settings: settings)
        NotificationManager.shared.attach(conversation: conversation)
        if settings.notificationsEnabled {
            NotificationManager.shared.registerForRemoteNotifications()
        }
    }

    var body: some Scene {
        WindowGroup {
            if settings.hasCompletedOnboarding {
                MainView()
                    .environmentObject(settings)
                    .environmentObject(conversation)
                    // If the on-device STT / TTS models are already downloaded,
                    // warm them into memory now so the first mic turn + first
                    // spoken reply don't pay the load cost. No-ops when absent.
                    .task {
                        LocalTranscriber.shared.warmUpIfDownloaded()
                        LocalSpeaker.shared.warmUpIfDownloaded()
                    }
            } else {
                OnboardingView()
                    .environmentObject(settings)
            }
        }
    }
}
