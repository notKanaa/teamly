import Foundation
import TeamTasksCore

/// In-memory `NotificationScheduler` used with the mock backend (UI tests): never shows the system permission
/// prompt and never posts a real notification, so nothing covers the screens being tested.
///
/// `requestAuthorization()` behaves like a user who accepts: `.notDetermined` becomes `.authorized`.
actor InAppNotificationScheduler: NotificationScheduler {
    private var status: NotificationAuthorization
    private var pending: [String: LocalNotification] = [:]
    private var badge = 0

    init(status: NotificationAuthorization = .notDetermined) {
        self.status = status
    }

    func authorizationStatus() async -> NotificationAuthorization {
        status
    }

    func requestAuthorization() async -> Bool {
        if status == .notDetermined {
            status = .authorized
        }
        return status == .authorized
    }

    func pendingIdentifiers(prefix: String) async -> [String] {
        pending.keys.filter { $0.hasPrefix(prefix) }.sorted()
    }

    func add(_ notification: LocalNotification) async throws {
        // Like the real scheduler: immediate notifications are "delivered", past fire dates are skipped.
        guard let fireDate = notification.fireDate, fireDate > Date() else { return }
        pending[notification.id] = notification
    }

    func removePending(ids: [String]) async {
        for id in ids {
            pending[id] = nil
        }
    }

    func setBadge(_ count: Int) async {
        badge = max(0, count)
    }
}
