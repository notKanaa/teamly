import Foundation

/// The weekly recap of a group (docs/CONTRACTS-V2.md §8), computed on the device from the group's done tasks
/// (`TaskService.completions(groupId:since: WeeklyRecap.readStart(now:calendar:))`) and its members. Pure.
///
/// Weeks run from Monday 00:00 to the next Monday 00:00 in the injected calendar's time zone (the app injects
/// `Calendar.frenchGregorian(timeZone:)`), whatever its `firstWeekday`.
/// - total: every task done in the current week;
/// - podium: the top `podiumSize` completers among the current members, most tasks first, ties by `NameOrder` on
///   the display name, then by user id;
/// - streak: the same current member as the sole leader (strictly more tasks than any other member) of consecutive
///   weeks, the current one included, when at least `minimumStreak` weeks (at most `weeksRead`: the weeks read).
/// Tasks completed by people who are no longer members, or by nobody known (`completedBy` nil), count in the total
/// only.
public struct WeeklyRecap: Sendable, Hashable {
    /// One member of the podium.
    public struct Entry: Sendable, Hashable, Identifiable {
        public var user: UserProfile
        /// Tasks done in the current week.
        public var count: Int

        public var id: UUID { user.id }

        public init(user: UserProfile, count: Int) {
            self.user = user
            self.count = count
        }
    }

    /// Consecutive weeks, ending with the current one, with the same sole leader.
    public struct Streak: Sendable, Hashable {
        public var user: UserProfile
        public var weeks: Int

        public init(user: UserProfile, weeks: Int) {
            self.user = user
            self.weeks = weeks
        }
    }

    /// Weeks read and compared: the current one and the 3 before it.
    public static let weeksRead = 4
    public static let podiumSize = 3
    /// Shortest streak shown.
    public static let minimumStreak = 2

    /// Start of the current week: Monday 00:00.
    public var weekStart: Date
    /// Start of the next week (exclusive end of the current one).
    public var weekEnd: Date
    public var total: Int
    /// At most `podiumSize` entries, first place first; only members with at least one task done.
    public var podium: [Entry]
    /// nil unless the streak has at least `minimumStreak` weeks.
    public var streak: Streak?

    public init(weekStart: Date, weekEnd: Date, total: Int, podium: [Entry], streak: Streak?) {
        self.weekStart = weekStart
        self.weekEnd = weekEnd
        self.total = total
        self.podium = podium
        self.streak = streak
    }

    /// The recap of the week of `now`.
    /// - Parameters:
    ///   - completions: the group's done tasks since `readStart(now:calendar:)` (others are ignored).
    ///   - members: the group's current members.
    public init(completions: [TaskCompletion], members: [Membership], now: Date, calendar: Calendar) {
        let current = Self.weekStart(of: now, calendar: calendar)
        let end = Self.weekStart(of: Self.adding(days: 7, to: current, calendar: calendar), calendar: calendar)
        // starts[0] is the current week, starts[k] the week k weeks before it.
        var starts = [current]
        for _ in 1..<Self.weeksRead {
            let dayOfTheWeekBefore = Self.adding(days: -7, to: starts[starts.count - 1], calendar: calendar)
            starts.append(Self.weekStart(of: dayOfTheWeekBefore, calendar: calendar))
        }

        var profiles: [UUID: UserProfile] = [:]
        for member in members {
            profiles[member.user.id] = member.user
        }
        var total = 0
        var counts = Array(repeating: [UUID: Int](), count: Self.weeksRead)
        for completion in completions where completion.completedAt < end {
            guard let week = starts.firstIndex(where: { completion.completedAt >= $0 }) else { continue }
            if week == 0 { total += 1 }
            if let userId = completion.completedBy, profiles[userId] != nil {
                counts[week][userId, default: 0] += 1
            }
        }

        let podium = counts[0]
            .compactMap { userId, count in profiles[userId].map { Entry(user: $0, count: count) } }
            .sorted(by: Self.ranks)
            .prefix(Self.podiumSize)

        var streak: Streak?
        if let leader = Self.soleLeader(counts[0]), let user = profiles[leader] {
            let weeks = 1 + counts.dropFirst().prefix(while: { Self.soleLeader($0) == leader }).count
            if weeks >= Self.minimumStreak {
                streak = Streak(user: user, weeks: weeks)
            }
        }

        self.init(weekStart: current, weekEnd: end, total: total, podium: Array(podium), streak: streak)
    }

    /// Monday 00:00 of the week of `date`, in `calendar`'s time zone.
    public static func weekStart(of date: Date, calendar: Calendar) -> Date {
        let startOfDay = calendar.startOfDay(for: date)
        // Gregorian weekday: 1 = Sunday, 2 = Monday … 7 = Saturday.
        let daysSinceMonday = (calendar.component(.weekday, from: startOfDay) + 5) % 7
        return calendar.startOfDay(for: adding(days: -daysSinceMonday, to: startOfDay, calendar: calendar))
    }

    /// The first instant to read (`completed_at=gte.<…>`): Monday 00:00 of the week `weeksRead - 1` weeks before the
    /// week of `now`.
    public static func readStart(now: Date, calendar: Calendar) -> Date {
        var start = weekStart(of: now, calendar: calendar)
        for _ in 1..<weeksRead {
            start = weekStart(of: adding(days: -7, to: start, calendar: calendar), calendar: calendar)
        }
        return start
    }

    // MARK: - Helpers

    private static func adding(days: Int, to date: Date, calendar: Calendar) -> Date {
        calendar.date(byAdding: .day, value: days, to: date) ?? date.addingTimeInterval(TimeInterval(days) * 86_400)
    }

    /// The member with strictly more tasks than every other member, if any.
    private static func soleLeader(_ counts: [UUID: Int]) -> UUID? {
        guard let best = counts.values.max() else { return nil }
        let leaders = counts.filter { $0.value == best }
        return leaders.count == 1 ? leaders.first?.key : nil
    }

    /// Podium order: count descending, then `NameOrder` on the display name, then user id.
    private static func ranks(_ lhs: Entry, _ rhs: Entry) -> Bool {
        if lhs.count != rhs.count { return lhs.count > rhs.count }
        if let order = NameOrder.precedes(lhs.user.displayName, rhs.user.displayName) { return order }
        return lhs.user.id.uuidString < rhs.user.id.uuidString
    }
}
