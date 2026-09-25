import Foundation

/// French wording of a repetition rule (docs/CONTRACTS-V2.md §5, §6). Pure.
///
/// - `summary(_:)`: the frequency alone, for rows: « Chaque jour », « Tous les 2 jours », « Chaque semaine »,
///   « Toutes les 2 semaines », « Chaque mois », « Tous les 3 mois »;
/// - `description(_:dueAt:)`: the summary, then the days, for the task screen and the editor: « Chaque semaine, le
///   samedi », « Toutes les 2 semaines, le mardi et le vendredi », « Chaque semaine, du lundi au vendredi »,
///   « Chaque mois, le 25 », « Chaque mois, le 1er », « Chaque mois, le 31 ou le dernier jour du mois ».
///
/// The days that follow the due date (a weekly rule without weekdays, a monthly rule without `monthDay`) are read in
/// the rule's time zone, like the server and `NextDueCalculator` do.
public enum RecurrenceText {
    /// Weekday names indexed by ISO weekday − 1 (1 = Monday … 7 = Sunday).
    public static let weekdayNames = ["lundi", "mardi", "mercredi", "jeudi", "vendredi", "samedi", "dimanche"]

    /// « Chaque semaine », « Toutes les 2 semaines »…
    public static func summary(_ rule: RecurrenceRule) -> String {
        summary(frequency: rule.frequency, interval: rule.interval)
    }

    /// « Chaque jour », « Tous les 2 jours », « Chaque semaine », « Toutes les 2 semaines », « Chaque mois », « Tous
    /// les 3 mois » (an interval below 1 reads as 1).
    public static func summary(frequency: RecurrenceRule.Frequency, interval: Int) -> String {
        let count = max(1, interval)
        switch frequency {
        case .daily: return count == 1 ? "Chaque jour" : "Tous les \(count) jours"
        case .weekly: return count == 1 ? "Chaque semaine" : "Toutes les \(count) semaines"
        case .monthly: return count == 1 ? "Chaque mois" : "Tous les \(count) mois"
        }
    }

    /// The summary, then the days of a weekly or monthly rule.
    /// - Parameter dueAt: the task's due date: a weekly rule without weekdays repeats on its weekday, a monthly rule
    ///   without `monthDay` on its day of the month. Without it (and without explicit days), only the summary.
    public static func description(_ rule: RecurrenceRule, dueAt: Date?) -> String {
        let summary = summary(rule)
        switch rule.frequency {
        case .daily:
            return summary
        case .weekly:
            let weekdays = rule.weekdays ?? dueAt.map { [localWeekday(of: $0, rule: rule)] } ?? []
            guard let days = weekdaysText(weekdays) else { return summary }
            return "\(summary), \(days)"
        case .monthly:
            guard let day = rule.monthDay ?? dueAt.map({ localDay(of: $0, rule: rule) }) else { return summary }
            return "\(summary), \(monthDayText(day))"
        }
    }

    /// « le samedi », « le mardi et le vendredi », « le lundi, le mercredi et le vendredi », « du lundi au
    /// vendredi », « tous les jours »; nil without any day in 1…7.
    public static func weekdaysText(_ weekdays: Set<Int>) -> String? {
        let days = weekdays.filter { (1...7).contains($0) }.sorted()
        guard let last = days.last else { return nil }
        if days.count == 7 { return "tous les jours" }
        if days == [1, 2, 3, 4, 5] { return "du lundi au vendredi" }
        guard days.count > 1 else { return "le \(weekdayNames[last - 1])" }
        let first = days.dropLast().map { "le \(weekdayNames[$0 - 1])" }.joined(separator: ", ")
        return "\(first) et le \(weekdayNames[last - 1])"
    }

    /// « le 25 », « le 1er », and for a day that some months do not have, « le 31 ou le dernier jour du mois ».
    public static func monthDayText(_ day: Int) -> String {
        let clamped = min(max(day, 1), 31)
        let number = clamped == 1 ? "1er" : "\(clamped)"
        return clamped > 28 ? "le \(number) ou le dernier jour du mois" : "le \(number)"
    }

    // MARK: - Local dates of the rule's time zone

    /// The rule's time zone, UTC when this device does not know it.
    static func timeZone(of rule: RecurrenceRule) -> TimeZone {
        rule.timeZone ?? TimeZone(secondsFromGMT: 0) ?? .gmt
    }

    /// ISO weekday (1 = Monday) of `date` in the rule's time zone.
    static func localWeekday(of date: Date, rule: RecurrenceRule) -> Int {
        NextDueCalculator.isoWeekday(LocalDateTime(date, in: timeZone(of: rule)).day)
    }

    /// Day of the month of `date` in the rule's time zone.
    static func localDay(of date: Date, rule: RecurrenceRule) -> Int {
        CivilDate(dayNumber: LocalDateTime(date, in: timeZone(of: rule)).day).day
    }
}
