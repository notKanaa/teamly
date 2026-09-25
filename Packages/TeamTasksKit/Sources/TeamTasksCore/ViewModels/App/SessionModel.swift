import Foundation
import Observation

/// Everything that lives as long as one user is signed in (docs/CONTRACTS.md §7): the `ChangeFeed` observed by
/// the screens, the `RealtimeCoordinator` feeding it, and the ONE `AssignmentNotifier` and `ReminderSynchronizer`
/// of this user in this process (also used by the background refresh).
///
/// Created and owned by `AppModel` (one per signed-in user); every signed-in view model takes it as its
/// dependency. `start()` begins listening, `stop()` tears everything down on sign-out.
@MainActor
@Observable
public final class SessionModel: Identifiable {
    /// Tunables (tests use a zero debounce).
    public struct Configuration: Sendable {
        public var realtimeDebounce: Duration
        public var realtimeRetryDelay: Duration
        /// v2: how long `AppModel` waits for the reads that decide the onboarding before it opens the tabs.
        public var onboardingCheckTimeout: Duration

        /// Defaults: `RealtimeCoordinator.defaultDebounce` (300 ms), `defaultRetryDelay` (5 s), and 5 s for the
        /// onboarding check.
        public init(
            realtimeDebounce: Duration = .milliseconds(300),
            realtimeRetryDelay: Duration = .seconds(5),
            onboardingCheckTimeout: Duration = .seconds(5)
        ) {
            self.realtimeDebounce = realtimeDebounce
            self.realtimeRetryDelay = realtimeRetryDelay
            self.onboardingCheckTimeout = onboardingCheckTimeout
        }
    }

    public nonisolated let id = UUID()
    /// The signed-in account (its e-mail may change during the session).
    public private(set) var user: AuthUser
    public let services: AppServices
    public let platform: PlatformServices
    /// Revisions observed by the screens to know when to reload.
    public let feed: ChangeFeed
    public let realtime: RealtimeCoordinator
    public let notifier: AssignmentNotifier
    public let reminders: ReminderSynchronizer
    /// v2: the weekly recap notification (docs/CONTRACTS-V2.md §8), synchronized with the other notifications.
    public let weeklyRecap: WeeklyRecapNotifier
    /// True between `start()` and `stop()`.
    public private(set) var isRunning = false
    /// True once `stop()` was called: the session no longer schedules anything.
    public private(set) var isStopped = false
    /// v2: the user chose « Plus tard » on the onboarding's notifications step: the app should not ask for the
    /// permission by itself during this session (Réglages still can).
    public private(set) var isNotificationPromptDeferred = false

    /// Initial catch-up and reminder synchronization started by `start()` (tests wait for it).
    @ObservationIgnored private(set) var startupTask: Task<Void, Never>?

    public var userId: UUID { user.id }

    /// Builds the per-session objects; starts nothing (see `start()`).
    public init(user: AuthUser, services: AppServices, platform: PlatformServices, configuration: Configuration = Configuration()) {
        self.user = user
        self.services = services
        self.platform = platform
        let feed = ChangeFeed()
        self.feed = feed
        let groups = services.groups
        let notifier = AssignmentNotifier(
            userId: user.id,
            tasks: services.tasks,
            scheduler: platform.notifications,
            store: platform.store,
            now: platform.now,
            groupName: { groupId in
                try? await groups.myGroups().first { $0.id == groupId }?.group.name
            }
        )
        self.notifier = notifier
        reminders = ReminderSynchronizer(platform: platform)
        weeklyRecap = WeeklyRecapNotifier(platform: platform)
        realtime = RealtimeCoordinator(
            realtime: services.realtime,
            userId: user.id,
            feed: feed,
            groupIds: { try await groups.myGroups().map(\.id) },
            debounce: configuration.realtimeDebounce,
            retryDelay: configuration.realtimeRetryDelay,
            onAssigned: { assignment in
                _ = await notifier.handleRealtime(assignment)
            }
        )
    }

    // MARK: - Lifecycle

    /// Starts listening to realtime change signals and, in the background, catches up on assignments made while
    /// the app was not running, synchronizes the due-date reminders and (v2) the weekly recap notification. No-op
    /// when running or stopped.
    public func start() {
        guard !isRunning, !isStopped else { return }
        isRunning = true
        realtime.start()
        startupTask = Task { [weak self] in
            await self?.refreshNotifications()
        }
    }

    /// Sign-out / account deletion (docs/CONTRACTS.md §7): stops the realtime coordinator, removes every pending
    /// reminder and (v2) the weekly recap notification, and resets the assignment notifier. Idempotent; the session
    /// cannot be restarted.
    public func stop() async {
        guard !isStopped else { return }
        isStopped = true
        isRunning = false
        startupTask?.cancel()
        realtime.stop()
        await reminders.removeAll()
        await weeklyRecap.removeAll()
        await notifier.reset()
    }

    /// Updates the account (same user id, e.g. a new e-mail).
    func update(user newUser: AuthUser) {
        guard newUser.id == user.id, newUser != user else { return }
        user = newUser
    }

    // MARK: - App events

    /// Return to foreground: everything may have changed while suspended (every screen reloads, the realtime
    /// group ids are fetched again), then catch-up of new assignments and reminder synchronization.
    public func handleForeground() async {
        guard isRunning else { return }
        feed.bumpAll()
        realtime.refreshGroupIds()
        await refreshNotifications()
    }

    /// Background App Refresh: catch-up of new assignments and reminder synchronization.
    public func handleBackgroundRefresh() async {
        guard !isStopped else { return }
        await refreshNotifications()
    }

    /// Clock or time zone changed: date wording (« Aujourd'hui », « En retard ») and reminders depend on it.
    public func handleSignificantTimeChange() async {
        guard !isStopped else { return }
        feed.bumpAll()
        await synchronizeReminders()
    }

    // MARK: - Notifications

    /// Catch-up of assignments made by others since the last one (local notifications). Errors are ignored:
    /// the cursor is unchanged and the next catch-up retries.
    public func catchUpAssignments() async {
        guard !isStopped else { return }
        _ = try? await notifier.catchUp()
    }

    /// Loads « Mes tâches » and synchronizes the reminders with it. Returns false (reminders untouched) when the
    /// list could not be loaded: an empty list after a network error would remove every reminder.
    @discardableResult
    public func synchronizeReminders() async -> Bool {
        guard !isStopped else { return false }
        let tasks: [TaskItem]
        do {
            tasks = try await services.tasks.myTasks(includeDone: false)
        } catch {
            return false
        }
        await synchronizeReminders(with: tasks)
        return true
    }

    /// Synchronizes the reminders with a SUCCESSFULLY loaded « Mes tâches » list.
    public func synchronizeReminders(with myTasks: [TaskItem]) async {
        guard !isStopped else { return }
        await reminders.synchronize(myTasks: myTasks, userId: userId)
    }

    /// Asks for the notification permission when it was never asked. Returns the resulting status; when newly
    /// granted, catches up and schedules the reminders (and the weekly recap) right away.
    @discardableResult
    public func requestNotificationAuthorizationIfNeeded() async -> NotificationAuthorization {
        let status = await platform.notifications.authorizationStatus()
        guard status == .notDetermined else { return status }
        let granted = await platform.notifications.requestAuthorization()
        if granted {
            await refreshNotifications()
        }
        return await platform.notifications.authorizationStatus()
    }

    /// v2: the onboarding's « Plus tard » on the notifications step (`isNotificationPromptDeferred`).
    public func deferNotificationPrompt() {
        isNotificationPromptDeferred = true
    }

    /// v2: schedules or removes the weekly recap notification (Réglages switch, permission). Returns whether it is
    /// scheduled afterwards; false once stopped.
    @discardableResult
    public func synchronizeWeeklyRecap() async -> Bool {
        guard !isStopped else { return false }
        return await weeklyRecap.synchronize()
    }

    func refreshNotifications() async {
        await catchUpAssignments()
        await synchronizeReminders()
        await synchronizeWeeklyRecap()
    }
}
