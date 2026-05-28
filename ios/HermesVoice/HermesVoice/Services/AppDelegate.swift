import SwiftUI
import UIKit

/// Bridge UIApplicationDelegate hooks into our SwiftUI lifecycle so we can
/// receive APNs token data. SwiftUI alone doesn't surface
/// `didRegisterForRemoteNotificationsWithDeviceToken:`.
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions:
            [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        return true
    }

    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        Task { @MainActor in
            NotificationManager.shared.handleAPNsToken(deviceToken)
        }
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        Task { @MainActor in
            NotificationManager.shared.handleAPNsRegistrationFailure(error)
        }
    }
}
