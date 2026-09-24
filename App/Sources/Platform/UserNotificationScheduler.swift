import Foundation
import TeamTasksCore
import UserNotifications

/// `NotificationScheduler` backed by `UNUserNotificationCenter` (local notifications, docs/CONTRACTS.md §7).
///
/// Stateless: every call goes to `UNUserNotificationCenter.current()`, which is thread-safe.
/// Foreground presentation (banner) and taps are handled by `AppDelegate`.
struct UserNotificationScheduler: NotificationScheduler {
    private var center: UNUserNotificationCenter { UNUserNotificationCenter.current() }

    func authorizationStatus() async -> NotificationAuthorization {
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            return .authorized
        case .notDetermined:
            return .notDetermined
        case .denied:
            return .denied
        @unknown default:
            return .denied
        }
    }

    func requestAuthorization() async -> Bool {
        do {
            return try await center.requestAuthorization(options: [.alert, .sound, .badge])
        } catch {
            return false
        }
    }

    func pendingIdentifiers(prefix: String) async -> [String] {
        let requests = await center.pendingNotificationRequests()
        return requests.map(\.identifier).filter { $0.hasPrefix(prefix) }
    }

    func add(_ notification: LocalNotification) async throws {
        let trigger: UNNotificationTrigger?
        if let fireDate = notification.fireDate {
            // The fire date may have passed between planning and now: skip it (a time-interval trigger ≤ 0 s
            // throws, and a reminder in the past is useless).
            let interval = fireDate.timeIntervalSinceNow
            guard interval > 0 else { return }
            trigger = UNTimeIntervalNotificationTrigger(timeInterval: interval, repeats: false)
        } else {
            // Deliver now.
            trigger = nil
        }

        let content = UNMutableNotificationContent()
        content.title = notification.title
        content.body = notification.body
        content.sound = .default
        var userInfo: [AnyHashable: Any] = [:]
        for (key, value) in notification.userInfo {
            userInfo[key] = value
        }
        content.userInfo = userInfo
        if let threadId = notification.threadId {
            content.threadIdentifier = threadId
        }

        let request = UNNotificationRequest(identifier: notification.id, content: content, trigger: trigger)
        try await center.add(request)
    }

    func removePending(ids: [String]) async {
        guard !ids.isEmpty else { return }
        center.removePendingNotificationRequests(withIdentifiers: ids)
    }

    func setBadge(_ count: Int) async {
        try? await center.setBadgeCount(max(0, count))
    }
}
