import BackgroundTasks
import Foundation
import TeamTasksCore

/// Background App Refresh (free, no entitlement): periodic catch-up of new assignments and reminder
/// synchronization while the app is not running. iOS decides when it actually runs.
///
/// The handler is registered by the scene's `.backgroundTask(.appRefresh(BackgroundRefresh.taskIdentifier))`;
/// the next run is requested when the app goes to the background and at the end of every run.
enum BackgroundRefresh {
    /// Must match `BGTaskSchedulerPermittedIdentifiers` in Info.plist (`$(PRODUCT_BUNDLE_IDENTIFIER).refresh`).
    static var taskIdentifier: String {
        "\(Bundle.main.bundleIdentifier ?? "io.github.equipe.app").refresh"
    }

    /// Do not ask iOS more often than this.
    static let minimumInterval: TimeInterval = 30 * 60

    /// Asks iOS for a future refresh (replaces the previous request). No-op with the mock backend.
    @MainActor
    static func schedule() {
        guard let environment = AppContainer.shared.environment, !environment.isMock else { return }
        let request = BGAppRefreshTaskRequest(identifier: taskIdentifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: minimumInterval)
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            // Unavailable in the simulator, or Background App Refresh disabled by the user: nothing to do,
            // local reminders and the realtime catch-up at the next launch still work.
        }
    }

    /// Body of the background task: schedules the next run, then refreshes (restoring the stored session first
    /// when the app was launched in the background).
    @MainActor
    static func perform() async {
        schedule()
        await AppContainer.shared.appModel?.handleBackgroundRefresh()
    }
}
