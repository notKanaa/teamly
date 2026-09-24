import TeamTasksCore
import UIKit
import UserNotifications

/// UIKit entry points SwiftUI has no modifier for: the local notification delegate (banner while the app is in
/// the foreground, tap → deep link through the `Router`, docs/CONTRACTS.md §7).
@MainActor
final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        // Must be set before launch finishes to receive the tap that launched the app.
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    // The system calls these on a background queue: they must not be main-actor isolated.

    /// Shows reminders and « nouvelle tâche » notifications as banners even when the app is open.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    /// A tap opens the task (or the group, or « Mes tâches » for a summary). While no session is active (launch,
    /// signed out) the `Router` keeps the link until one starts.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        guard response.actionIdentifier == UNNotificationDefaultActionIdentifier else { return }
        let link = DeepLink(notificationUserInfo: response.notification.request.content.userInfo)
        await MainActor.run {
            AppContainer.shared.appModel?.router.open(link)
        }
    }
}
