import Foundation

/// Due-date section of a task list ("Mes tâches"), in display order.
public enum DueBucket: Int, Sendable, Hashable, Codable, CaseIterable, Comparable, Identifiable {
    /// Not done, due strictly before now.
    case overdue
    /// Not done, due from now until the end of today.
    case today
    /// Not done, due after today and before the start of next week (per the calendar's `firstWeekday`).
    case thisWeek
    /// Not done, due from the start of next week on.
    case later
    /// Not done, without due date.
    case noDueDate
    /// Done tasks, whatever their due date.
    case done

    public var id: Int { rawValue }

    /// French section title.
    public var title: String {
        switch self {
        case .overdue: "En retard"
        case .today: "Aujourd'hui"
        case .thisWeek: "Cette semaine"
        case .later: "Plus tard"
        case .noDueDate: "Sans échéance"
        case .done: "Terminées"
        }
    }

    public static func < (lhs: DueBucket, rhs: DueBucket) -> Bool { lhs.rawValue < rhs.rawValue }

    /// Bucket of one task. Build a `DueBucketBoundaries` once when classifying many tasks.
    public static func bucket(for task: TaskItem, now: Date, calendar: Calendar) -> DueBucket {
        DueBucketBoundaries(now: now, calendar: calendar).bucket(for: task)
    }

    /// Groups tasks into ordered, non-empty sections.
    /// - Parameters:
    ///   - sort: order inside the not-done sections (default: due date, then priority, then title).
    ///     The "Terminées" section lists the most recently completed first, then follows `sort`.
    public static func sections(
        for tasks: [TaskItem],
        now: Date,
        calendar: Calendar,
        sort: TaskSort = .dueDate
    ) -> [DueSection] {
        DueBucketBoundaries(now: now, calendar: calendar).sections(for: tasks, sort: sort)
    }
}

/// A non-empty section of tasks sharing a `DueBucket`.
public struct DueSection: Sendable, Hashable, Identifiable {
    public var bucket: DueBucket
    public var tasks: [TaskItem]

    public var id: DueBucket { bucket }
    public var title: String { bucket.title }

    public init(bucket: DueBucket, tasks: [TaskItem]) {
        self.bucket = bucket
        self.tasks = tasks
    }
}

/// Day boundaries used to classify due dates, computed once from `now` and the injected calendar
/// (time zone and first weekday). Correct across daylight-saving transitions: boundaries are calendar
/// midnights, not multiples of 24 hours.
public struct DueBucketBoundaries: Sendable, Hashable {
    public let now: Date
    /// First instant of today.
    public let startOfToday: Date
    /// First instant of tomorrow (end of the "Aujourd'hui" bucket).
    public let startOfTomorrow: Date
    /// First instant of next week (end of the "Cette semaine" bucket). Equals `startOfTomorrow`
    /// on the last day of the week (Sunday with French conventions), making "Cette semaine" empty.
    public let startOfNextWeek: Date

    public init(now: Date, calendar: Calendar) {
        self.now = now
        let startOfToday = calendar.startOfDay(for: now)
        self.startOfToday = startOfToday

        let weekday = calendar.component(.weekday, from: startOfToday)
        let daysSinceWeekStart = ((weekday - calendar.firstWeekday) % 7 + 7) % 7
        startOfTomorrow = Self.startOfDay(daysAfter: 1, startOfToday, calendar)
        startOfNextWeek = Self.startOfDay(daysAfter: 7 - daysSinceWeekStart, startOfToday, calendar)
    }

    public func bucket(for task: TaskItem) -> DueBucket {
        if task.status == .done { return .done }
        guard let dueAt = task.dueAt else { return .noDueDate }
        if dueAt < now { return .overdue }
        if dueAt < startOfTomorrow { return .today }
        if dueAt < startOfNextWeek { return .thisWeek }
        return .later
    }

    /// See `DueBucket.sections(for:now:calendar:sort:)`.
    public func sections(for tasks: [TaskItem], sort: TaskSort = .dueDate) -> [DueSection] {
        var grouped: [DueBucket: [TaskItem]] = [:]
        for task in tasks {
            grouped[bucket(for: task), default: []].append(task)
        }
        return DueBucket.allCases.compactMap { bucket in
            guard let tasks = grouped[bucket], !tasks.isEmpty else { return nil }
            let ordered = bucket == .done ? Self.sortDone(tasks, sort: sort) : sort.sorted(tasks)
            return DueSection(bucket: bucket, tasks: ordered)
        }
    }

    /// Most recently completed first (unknown completion date last), ties broken by `sort`.
    private static func sortDone(_ tasks: [TaskItem], sort: TaskSort) -> [TaskItem] {
        let base = sort.sorted(tasks)
        let keyed = base.enumerated().map { (offset: $0.offset, task: $0.element) }
        return keyed.sorted { lhs, rhs in
            switch (lhs.task.completedAt, rhs.task.completedAt) {
            case let (l?, r?) where l != r: return l > r
            case (_?, nil): return true
            case (nil, _?): return false
            default: return lhs.offset < rhs.offset
            }
        }.map { $0.task }
    }

    private static func startOfDay(daysAfter days: Int, _ startOfToday: Date, _ calendar: Calendar) -> Date {
        let shifted = calendar.date(byAdding: .day, value: days, to: startOfToday)
            ?? startOfToday.addingTimeInterval(Double(days) * 86_400)
        return calendar.startOfDay(for: shifted)
    }
}
