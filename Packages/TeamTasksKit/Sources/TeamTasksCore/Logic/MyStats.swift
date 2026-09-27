import Foundation

/// The personal stats of Réglages (docs/CONTRACTS-V3.md §8), computed on the device from the tasks the user completed
/// (`TaskService.myCompletions(since: MyStats.readStart(now:calendar:))`). Pure.
///
/// - « tâches ce mois » (`tasksThisMonth`): the tasks completed since the 1st of the month at 00:00, in the injected
///   calendar's time zone.
/// - « semaines de série » (`weekStreak`): consecutive weeks (Monday 00:00 to the next Monday 00:00) with at least one
///   completion, counted back from the current week; when the current week has none yet, from the previous week (a
///   streak is not lost before the week is over). At most `weeksRead` weeks: the weeks read.
public struct MyStats: Sendable, Hashable {
    /// Weeks read: the current one and the 11 before it.
    public static let weeksRead = Limits.statsWeeksRead

    public var tasksThisMonth: Int
    public var weekStreak: Int
    /// True when the current week already has a completion (the streak includes it).
    public var isCurrentWeekDone: Bool

    public init(tasksThisMonth: Int, weekStreak: Int, isCurrentWeekDone: Bool) {
        self.tasksThisMonth = tasksThisMonth
        self.weekStreak = weekStreak
        self.isCurrentWeekDone = isCurrentWeekDone
    }

    /// The stats at `now`.
    /// - Parameter completions: the user's completions since `readStart(now:calendar:)` (earlier ones are ignored).
    public init(completions: [TaskCompletion], now: Date, calendar: Calendar) {
        let monthStart = Self.monthStart(of: now, calendar: calendar)
        let currentWeek = WeeklyRecap.weekStart(of: now, calendar: calendar)
        let weekEnd = WeeklyRecap.weekStart(of: Self.adding(days: 7, to: currentWeek, calendar: calendar), calendar: calendar)
        // starts[0] is the current week, starts[k] the week k weeks before it.
        var starts = [currentWeek]
        for _ in 1..<Self.weeksRead {
            let dayOfTheWeekBefore = Self.adding(days: -7, to: starts[starts.count - 1], calendar: calendar)
            starts.append(WeeklyRecap.weekStart(of: dayOfTheWeekBefore, calendar: calendar))
        }
        var doneWeeks = Set<Int>()
        var month = 0
        for completion in completions where completion.completedAt < weekEnd {
            if completion.completedAt >= monthStart { month += 1 }
            if let week = starts.firstIndex(where: { completion.completedAt >= $0 }) {
                doneWeeks.insert(week)
            }
        }
        let currentDone = doneWeeks.contains(0)
        var streak = 0
        var week = currentDone ? 0 : 1
        while week < Self.weeksRead, doneWeeks.contains(week) {
            streak += 1
            week += 1
        }
        self.init(tasksThisMonth: month, weekStreak: streak, isCurrentWeekDone: currentDone)
    }

    /// The first instant to read (`completed_at=gte.<…>`): Monday 00:00 of the week `weeksRead - 1` weeks before the
    /// week of `now` (always before the 1st of the month).
    public static func readStart(now: Date, calendar: Calendar) -> Date {
        var start = WeeklyRecap.weekStart(of: now, calendar: calendar)
        for _ in 1..<weeksRead {
            start = WeeklyRecap.weekStart(of: adding(days: -7, to: start, calendar: calendar), calendar: calendar)
        }
        return min(start, monthStart(of: now, calendar: calendar))
    }

    /// The 1st of the month of `date` at 00:00, in `calendar`'s time zone.
    public static func monthStart(of date: Date, calendar: Calendar) -> Date {
        let components = calendar.dateComponents([.year, .month], from: date)
        return calendar.date(from: DateComponents(year: components.year, month: components.month, day: 1))
            .map { calendar.startOfDay(for: $0) } ?? calendar.startOfDay(for: date)
    }

    /// « tâches ce mois » (`StatsText.monthLabel(_:)`).
    public var monthLabel: String { StatsText.monthLabel(tasksThisMonth) }

    /// « semaines de série » (`StatsText.streakLabel(_:)`).
    public var streakLabel: String { StatsText.streakLabel(weekStreak) }

    private static func adding(days: Int, to date: Date, calendar: Calendar) -> Date {
        calendar.date(byAdding: .day, value: days, to: date) ?? date.addingTimeInterval(TimeInterval(days) * 86_400)
    }
}
