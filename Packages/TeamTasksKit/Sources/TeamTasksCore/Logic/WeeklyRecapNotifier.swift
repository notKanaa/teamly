import Foundation

/// Keeps the weekly recap notification scheduled (docs/CONTRACTS-V2.md §8): a local notification repeated every Monday
/// at 09:00, « Le récap de la semaine est prêt », on each device while a user is signed in. It can be switched off in
/// Réglages (on by default); it is removed while the notifications are not authorized, and on sign-out.
///
/// `SessionModel` owns one per session: `synchronize()` runs with the other notification work (session start, return
/// to the foreground, background refresh, permission granted) and after the setting changes; `removeAll()` runs on
/// sign-out. Synchronizations run one at a time, and `removeAll()` supersedes every one started before it: such a
/// synchronization schedules nothing more and withdraws what it has just scheduled.
///
/// Idempotent: a pending notification with the same content (a fingerprint kept in the `KeyValueStore`) is left as
/// it is. It has no `userInfo`: a tap opens « Groupes » (`DeepLink(notificationIdentifier:userInfo:)`).
public actor WeeklyRecapNotifier {
    public static let identifierPrefix = "recap-"
    public static let identifier = "recap-weekly"
    public static let title = "Le récap de la semaine est prêt"
    public static let body = "Qui a fait quoi cette semaine, avec le podium de chaque groupe."
    /// Every Monday at 09:00.
    public static let schedule = WeeklyRepeat(weekday: 1, hour: 9)
    /// `KeyValueStore` key of the Réglages switch (a `Bool`; missing = on).
    public static let settingKey = "settings.weeklyRecapNotification"
    /// `KeyValueStore` key of the fingerprint of the scheduled notification.
    static let fingerprintKey = "recap.fingerprint"

    /// The Réglages switch: on unless switched off.
    public static func isEnabled(in store: any KeyValueStore) -> Bool {
        store.value(Bool.self, forKey: settingKey) ?? true
    }

    public static func setEnabled(_ enabled: Bool, in store: any KeyValueStore) {
        store.setValue(enabled, forKey: settingKey)
    }

    /// What the scheduled notification shows and when (not its first delivery date, which moves every week).
    static var fingerprint: String {
        "\(title)\u{1F}\(body)\u{1F}\(schedule.weekday)-\(schedule.hour)-\(schedule.minute)"
    }

    private let scheduler: any NotificationScheduler
    private let store: any KeyValueStore
    private let now: NowProvider
    public nonisolated let calendar: Calendar

    /// Bumped by `removeAll()`.
    private var epoch = 0
    private var isBusy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    public init(scheduler: any NotificationScheduler, store: any KeyValueStore, calendar: Calendar, now: @escaping NowProvider) {
        self.scheduler = scheduler
        self.store = store
        self.calendar = calendar
        self.now = now
    }

    public init(platform: PlatformServices) {
        self.init(scheduler: platform.notifications, store: platform.store, calendar: platform.calendar, now: platform.now)
    }

    /// The notification: weekly on Monday at 09:00, first delivered at the next such time after `now`.
    public nonisolated func notification(now: Date) -> LocalNotification {
        LocalNotification(
            id: Self.identifier,
            title: Self.title,
            body: Self.body,
            fireDate: Self.schedule.nextDate(after: now, calendar: calendar),
            repeatsWeekly: Self.schedule
        )
    }

    /// Schedules the notification when the setting is on and the notifications are authorized, removes it otherwise.
    /// Waits for the synchronization in progress; does nothing when `removeAll()` was called since the call.
    /// - Returns: whether the notification is scheduled afterwards.
    @discardableResult
    public func synchronize() async -> Bool {
        let started = epoch
        await acquire()
        defer { release() }
        guard epoch == started else { return false }

        let isEnabled = Self.isEnabled(in: store)
        let status = await scheduler.authorizationStatus()
        let isPending = await scheduler.pendingIdentifiers(prefix: Self.identifierPrefix).contains(Self.identifier)
        guard epoch == started else { return false }

        guard isEnabled, status == .authorized else {
            if isPending {
                await scheduler.removePending(ids: [Self.identifier])
            }
            store.set(nil, forKey: Self.fingerprintKey)
            return false
        }
        if isPending, store.value(String.self, forKey: Self.fingerprintKey) == Self.fingerprint {
            return true
        }
        if isPending {
            await scheduler.removePending(ids: [Self.identifier])
        }
        do {
            try await scheduler.add(notification(now: now()))
        } catch {
            store.set(nil, forKey: Self.fingerprintKey)
            return false
        }
        guard epoch == started else {
            // Signed out meanwhile: the platform may register the request after the removal.
            await scheduler.removePending(ids: [Self.identifier])
            return false
        }
        store.setValue(Self.fingerprint, forKey: Self.fingerprintKey)
        return true
    }

    /// Removes the notification (sign-out, account deletion). Does not wait for a synchronization in progress: that
    /// one is superseded and withdraws what it schedules late.
    public func removeAll() async {
        epoch += 1
        await scheduler.removePending(ids: [Self.identifier])
        store.set(nil, forKey: Self.fingerprintKey)
    }

    // MARK: - Serialization

    private func acquire() async {
        if !isBusy {
            isBusy = true
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    private func release() {
        if waiters.isEmpty {
            isBusy = false
        } else {
            waiters.removeFirst().resume()
        }
    }
}
