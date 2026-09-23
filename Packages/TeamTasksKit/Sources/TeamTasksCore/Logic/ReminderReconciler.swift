import Foundation

/// What `ReminderReconciler.apply(_:)` changed.
public struct ReminderReconciliation: Sendable, Hashable {
    /// Ids scheduled for the first time.
    public var added: [String] = []
    /// Ids already pending whose content or fire date changed (removed, then added again).
    public var replaced: [String] = []
    /// Pending ids no longer desired (task done, unassigned, deleted, due date changed, reminders off…).
    public var removed: [String] = []
    /// Ids whose scheduling failed; retried by the next `apply`.
    public var failed: [String] = []
    /// Desired reminders already pending with the same content.
    public var unchanged: Int = 0

    public init() {}

    /// True when nothing had to be scheduled or removed.
    public var isNoOp: Bool { added.isEmpty && replaced.isEmpty && removed.isEmpty && failed.isEmpty }
}

/// Makes the pending `due-` notifications match a desired set (from `ReminderPlanner`) through
/// `NotificationScheduler`. Idempotent: applying the same set twice does nothing the second time.
///
/// Notifications other than `due-` ones are never touched. Because a reminder's id only encodes the task
/// and its due date, a fingerprint of every scheduled reminder (content + fire date) is kept in the
/// `KeyValueStore`, so that a lead-time change or a renamed task replaces the pending request.
public struct ReminderReconciler: Sendable {
    /// `KeyValueStore` key of the `[id: fingerprint]` map.
    public static let fingerprintsKey = "reminders.fingerprints"

    private let scheduler: any NotificationScheduler
    private let store: any KeyValueStore

    public init(scheduler: any NotificationScheduler, store: any KeyValueStore) {
        self.scheduler = scheduler
        self.store = store
    }

    @discardableResult
    public func apply(_ desired: [LocalNotification]) async -> ReminderReconciliation {
        let prefix = ReminderPlanner.identifierPrefix
        var unique: [LocalNotification] = []
        var desiredIds = Set<String>()
        for notification in desired where notification.id.hasPrefix(prefix) {
            if desiredIds.insert(notification.id).inserted {
                unique.append(notification)
            }
        }

        let pending = Set(await scheduler.pendingIdentifiers(prefix: prefix))
        let stored = store.value([String: String].self, forKey: Self.fingerprintsKey) ?? [:]
        var result = ReminderReconciliation()
        var toAdd: [(notification: LocalNotification, fingerprint: String, isReplacement: Bool)] = []

        for notification in unique {
            let fingerprint = Self.fingerprint(of: notification)
            if pending.contains(notification.id) {
                if stored[notification.id] == fingerprint {
                    result.unchanged += 1
                } else {
                    toAdd.append((notification, fingerprint, true))
                }
            } else {
                toAdd.append((notification, fingerprint, false))
            }
        }

        result.removed = pending.subtracting(desiredIds).sorted()
        let toRemove = result.removed + toAdd.filter { $0.isReplacement }.map { $0.notification.id }
        if !toRemove.isEmpty {
            await scheduler.removePending(ids: toRemove)
        }

        var fingerprints = stored.filter { desiredIds.contains($0.key) && pending.contains($0.key) }
        for item in toAdd {
            do {
                try await scheduler.add(item.notification)
                fingerprints[item.notification.id] = item.fingerprint
                if item.isReplacement {
                    result.replaced.append(item.notification.id)
                } else {
                    result.added.append(item.notification.id)
                }
            } catch {
                fingerprints[item.notification.id] = nil
                result.failed.append(item.notification.id)
            }
        }

        if fingerprints != stored {
            store.setValue(fingerprints, forKey: Self.fingerprintsKey)
        }
        return result
    }

    /// Stable (process-independent) fingerprint of everything a reminder displays or when it fires.
    static func fingerprint(of notification: LocalNotification) -> String {
        let fireMillis = notification.fireDate.map { String(Int64(($0.timeIntervalSince1970 * 1000).rounded())) } ?? "-"
        let userInfo = notification.userInfo.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }
        let parts = [notification.title, notification.body, fireMillis, notification.threadId ?? "-"] + userInfo
        return StableHash.fnv1a64Hex(parts.joined(separator: "\u{1F}"))
    }
}

/// Plans and applies the due-date reminders in one call (app launch, "Mes tâches" reload, lead time
/// change, background refresh). Reads the lead time from the store; when notifications are not
/// authorized, every pending reminder is removed (they would not be shown anyway).
public struct ReminderSynchronizer: Sendable {
    public var planner: ReminderPlanner
    private let reconciler: ReminderReconciler
    private let scheduler: any NotificationScheduler
    private let store: any KeyValueStore
    private let now: NowProvider

    public init(
        scheduler: any NotificationScheduler,
        store: any KeyValueStore,
        calendar: Calendar,
        now: @escaping NowProvider,
        maxPending: Int = ReminderPlanner.defaultMaxPending
    ) {
        planner = ReminderPlanner(calendar: calendar, maxPending: maxPending)
        reconciler = ReminderReconciler(scheduler: scheduler, store: store)
        self.scheduler = scheduler
        self.store = store
        self.now = now
    }

    public init(platform: PlatformServices) {
        self.init(scheduler: platform.notifications, store: platform.store, calendar: platform.calendar, now: platform.now)
    }

    /// Reconciles the pending reminders with `myTasks` (tasks assigned to `userId`).
    @discardableResult
    public func synchronize(myTasks: [TaskItem], userId: UUID) async -> ReminderReconciliation {
        let leadTime = ReminderLeadTime.load(from: store)
        let authorized = await scheduler.authorizationStatus() == .authorized
        let desired = authorized
            ? planner.plan(tasks: myTasks, userId: userId, leadTime: leadTime, now: now())
            : []
        return await reconciler.apply(desired)
    }

    /// Removes every pending reminder (sign-out, account deletion).
    @discardableResult
    public func removeAll() async -> ReminderReconciliation {
        await reconciler.apply([])
    }
}

/// FNV-1a 64-bit hash: stable across processes and platforms (unlike `Hasher`).
enum StableHash {
    static func fnv1a64Hex(_ text: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        let hex = String(hash, radix: 16)
        return String(repeating: "0", count: 16 - hex.count) + hex
    }
}
