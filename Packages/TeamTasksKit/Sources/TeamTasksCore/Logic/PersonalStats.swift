import Foundation

/// The figures of the « Réglages » profile card (docs/CONTRACTS-V3.md §8), from the completion dates of the tasks the
/// user completed:
/// - « tâches ce mois »: completed since the 1st of the month at 00:00, in the injected calendar;
/// - « semaines de série »: consecutive Monday-to-Sunday weeks with at least one completion, counted back from the
///   current week; when the current week has none yet, the count starts from the previous week. Only the weeks read
///   count (`weeksRead`, from `readStart(now:calendar:)`).
///
/// Weeks run from Monday 00:00 (`WeeklyRecap.weekStart`), whatever the calendar's `firstWeekday`. Pure.
public struct PersonalStats: Sendable, Hashable {
    /// The weeks read for the streak, the current one included.
    public static let weeksRead = 12

    public var tasksThisMonth: Int
    public var streakWeeks: Int

    public init(tasksThisMonth: Int, streakWeeks: Int) {
        self.tasksThisMonth = tasksThisMonth
        self.streakWeeks = streakWeeks
    }

    /// The figures of `completions` (the completion dates of the tasks the user completed) at `now`.
    public init(completions: [Date], now: Date, calendar: Calendar) {
        let monthStart = Self.monthStart(of: now, calendar: calendar)
        let readStart = Self.readStart(now: now, calendar: calendar)
        let weeks = Set(completions.filter { $0 >= readStart }.map { WeeklyRecap.weekStart(of: $0, calendar: calendar) })
        var week = WeeklyRecap.weekStart(of: now, calendar: calendar)
        if !weeks.contains(week) {
            week = Self.weekBefore(week, calendar: calendar)
        }
        var streak = 0
        while week >= readStart, weeks.contains(week) {
            streak += 1
            week = Self.weekBefore(week, calendar: calendar)
        }
        self.init(tasksThisMonth: completions.filter { $0 >= monthStart }.count, streakWeeks: streak)
    }

    /// The figures of the tasks among `tasks` that `userId` completed (done, `completedBy == userId`, with a
    /// `completedAt`); each task counts once.
    public init(tasks: [TaskItem], userId: UUID, now: Date, calendar: Calendar) {
        var seen = Set<UUID>()
        var completions: [Date] = []
        for task in tasks where task.status == .done && task.completedBy == userId {
            guard let completedAt = task.completedAt, seen.insert(task.id).inserted else { continue }
            completions.append(completedAt)
        }
        self.init(completions: completions, now: now, calendar: calendar)
    }

    // MARK: - Reading

    /// The first instant to read (`completed_at=gte.<…>`): Monday 00:00 of the week `weeksRead - 1` weeks before the
    /// week of `now`, or the 1st of the month if that is earlier.
    public static func readStart(now: Date, calendar: Calendar) -> Date {
        var start = WeeklyRecap.weekStart(of: now, calendar: calendar)
        for _ in 1..<weeksRead {
            start = weekBefore(start, calendar: calendar)
        }
        return min(start, monthStart(of: now, calendar: calendar))
    }

    /// The 1st of the month of `date` at 00:00.
    public static func monthStart(of date: Date, calendar: Calendar) -> Date {
        let parts = calendar.dateComponents([.year, .month], from: date)
        return calendar.date(from: parts) ?? calendar.startOfDay(for: date)
    }

    // MARK: - Wording

    /// « tâche ce mois » / « tâches ce mois », under the figure.
    public var tasksThisMonthLabel: String {
        FrenchText.isSingular(tasksThisMonth) ? "tâche ce mois" : "tâches ce mois"
    }

    /// « semaine de série » / « semaines de série », under the figure.
    public var streakLabel: String {
        FrenchText.isSingular(streakWeeks) ? "semaine de série" : "semaines de série"
    }

    /// « groupe » / « groupes », under the number of groups.
    public static func groupsLabel(_ count: Int) -> String {
        FrenchText.isSingular(count) ? "groupe" : "groupes"
    }

    private static func weekBefore(_ weekStart: Date, calendar: Calendar) -> Date {
        let dayOfTheWeekBefore = calendar.date(byAdding: .day, value: -7, to: weekStart)
            ?? weekStart.addingTimeInterval(-7 * 86_400)
        return WeeklyRecap.weekStart(of: dayOfTheWeekBefore, calendar: calendar)
    }
}
