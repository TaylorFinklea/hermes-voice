import SwiftUI

@main
struct HermesVoiceWatchApp: App {
    @StateObject private var session = WatchSession.shared

    var body: some Scene {
        WindowGroup {
            WatchMainView()
                .environmentObject(session)
        }
    }
}
