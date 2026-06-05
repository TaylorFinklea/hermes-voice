import SwiftUI

@main
struct HermesVoiceApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var settings = AppSettings()
    @StateObject private var conversation: ConversationViewModel
    @StateObject private var conversationMode: ConversationModeController

    init() {
        let settings = AppSettings()
        _settings = StateObject(wrappedValue: settings)
        let conversation = ConversationViewModel(settings: settings)
        _conversation = StateObject(wrappedValue: conversation)
        _conversationMode = StateObject(wrappedValue: ConversationModeController(vm: conversation))
        // Activate the WatchConnectivity bridge at app startup so audio
        // transfers from a paired Watch are handled even before any view
        // holds a reference. Singleton — safe to call repeatedly.
        PhoneWatchBridge.shared.start(settings: settings)
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
                    .environmentObject(conversationMode)
                    // If the on-device STT / TTS / VAD models are already
                    // downloaded, warm them into memory now so the first mic
                    // turn, spoken reply, and hands-free listen don't pay the
                    // load cost. No-ops when absent.
                    .task {
                        LocalTranscriber.shared.warmUpIfDownloaded()
                        LocalSpeaker.shared.warmUpIfDownloaded()
                        LocalVad.shared.warmUpIfDownloaded()
                    }
            } else {
                OnboardingView()
                    .environmentObject(settings)
            }
        }
    }
}
