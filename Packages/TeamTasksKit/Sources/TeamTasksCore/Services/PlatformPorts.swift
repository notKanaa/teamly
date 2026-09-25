import Foundation

// Platform abstractions implemented by the iOS app (UserNotifications, UserDefaults…)
// and by simple fakes in tests, so all the logic stays testable on Linux.

public enum NotificationAuthorization: Sendable, Hashable {
    case notDetermined
    case denied
    case authorized
}

/// A local notification request.
public struct LocalNotification: Sendable, Hashable, Identifiable {
    /// Stable identifier. Prefixes: `due-` (due-date reminders), `assigned-` (new assignment), `summary-`, and (v2)
    /// `recap-` (the weekly recap).
    public var id: String
    public var title: String
    public var body: String
    /// Delivery date; nil means "deliver now". With `repeatsWeekly`, the first delivery (for a scheduler that does
    /// not know repeating triggers).
    public var fireDate: Date?
    /// Routing info for taps: keys `taskId`, `groupId` (UUID strings).
    public var userInfo: [String: String]
    public var threadId: String?
    /// v2: delivered every week at this time, in the device's calendar and time zone, until removed. The platform
    /// schedules a repeating calendar trigger and ignores `fireDate`.
    public var repeatsWeekly: WeeklyRepeat?

    public init(
        id: String,
        title: String,
        body: String,
        fireDate: Date? = nil,
        userInfo: [String: String] = [:],
        threadId: String? = nil,
        repeatsWeekly: WeeklyRepeat? = nil
    ) {
        self.id = id
        self.title = title
        self.body = body
        self.fireDate = fireDate
        self.userInfo = userInfo
        self.threadId = threadId
        self.repeatsWeekly = repeatsWeekly
    }
}

/// v2: a weekly time of a repeating local notification (the weekly recap, docs/CONTRACTS-V2.md §8): every `weekday`
/// at `hour`:`minute`, in the device's calendar and time zone.
public struct WeeklyRepeat: Sendable, Hashable, Codable {
    /// ISO weekday: 1 = Monday … 7 = Sunday.
    public var weekday: Int
    public var hour: Int
    public var minute: Int

    public init(weekday: Int, hour: Int, minute: Int = 0) {
        self.weekday = weekday
        self.hour = hour
        self.minute = minute
    }

    /// The same day as a Gregorian `DateComponents.weekday`: 1 = Sunday, 2 = Monday … 7 = Saturday.
    public var gregorianWeekday: Int { weekday % 7 + 1 }

    /// The components the platform trigger matches (`UNCalendarNotificationTrigger(dateMatching:repeats: true)`).
    public var dateComponents: DateComponents {
        DateComponents(hour: hour, minute: minute, weekday: gregorianWeekday)
    }

    /// The first time strictly after `date`, in `calendar`'s time zone.
    public func nextDate(after date: Date, calendar: Calendar) -> Date {
        let startOfToday = calendar.startOfDay(for: date)
        let today = calendar.component(.weekday, from: startOfToday)
        let daysAhead = (gregorianWeekday - today + 7) % 7
        for extraWeeks in 0...2 {
            guard let day = calendar.date(byAdding: .day, value: daysAhead + 7 * extraWeeks, to: startOfToday),
                  let candidate = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day)
            else { continue }
            if candidate > date { return candidate }
        }
        return date.addingTimeInterval(7 * 86_400)
    }
}

public protocol NotificationScheduler: Sendable {
    func authorizationStatus() async -> NotificationAuthorization
    /// Returns true if granted.
    func requestAuthorization() async -> Bool
    /// Identifiers of pending (not yet delivered) requests starting with `prefix`.
    func pendingIdentifiers(prefix: String) async -> [String]
    func add(_ notification: LocalNotification) async throws
    func removePending(ids: [String]) async
    func setBadge(_ count: Int) async
}

/// Small persistent key-value storage (UserDefaults on iOS).
public protocol KeyValueStore: Sendable {
    func data(forKey key: String) -> Data?
    func set(_ data: Data?, forKey key: String)
}

extension KeyValueStore {
    public func value<T: Decodable>(_ type: T.Type, forKey key: String) -> T? {
        guard let data = data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    public func setValue<T: Encodable>(_ value: T?, forKey key: String) {
        guard let value else {
            set(nil, forKey: key)
            return
        }
        set(try? JSONEncoder().encode(value), forKey: key)
    }
}

/// In-memory `KeyValueStore` (tests, previews, UI tests).
public final class InMemoryKeyValueStore: KeyValueStore, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String: Data] = [:]

    public init() {}

    public func data(forKey key: String) -> Data? {
        lock.withLock { storage[key] }
    }

    public func set(_ data: Data?, forKey key: String) {
        lock.withLock { storage[key] = data }
    }
}

/// Current-date provider (injectable for tests). Not named `Clock` to avoid clashing with Swift's `Clock`.
public typealias NowProvider = @Sendable () -> Date

/// Platform services injected into view models.
public struct PlatformServices: Sendable {
    public var notifications: any NotificationScheduler
    public var store: any KeyValueStore
    public var now: NowProvider
    public var calendar: Calendar

    public init(
        notifications: any NotificationScheduler,
        store: any KeyValueStore,
        now: @escaping NowProvider = { Date() },
        calendar: Calendar = .current
    ) {
        self.notifications = notifications
        self.store = store
        self.now = now
        self.calendar = calendar
    }
}
