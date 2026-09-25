import Foundation

/// How a recurring task repeats (docs/CONTRACTS-V2.md §5, §6). When an occurrence becomes done, the server creates
/// the next one, due at `NextDueCalculator.nextDueDate(after:rule:now:)`.
///
/// On the wire (`p_recurrence`) a rule is `{"freq", "interval", "weekdays", "tz"}`; `monthDay` is never sent (the
/// server derives it from the due date). Check a rule with `InputValidation.recurrence(_:dueAt:)`.
public struct RecurrenceRule: Sendable, Hashable {
    public enum Frequency: String, Sendable, Hashable, Codable, CaseIterable {
        case daily
        case weekly
        case monthly
    }

    public var frequency: Frequency
    /// Every `interval` days, weeks or months: 1…`Limits.repeatIntervalMax`.
    public var interval: Int
    /// Weekly rules only: ISO weekdays, 1 = Monday … 7 = Sunday, never empty; nil = the due date's weekday.
    public var weekdays: Set<Int>?
    /// IANA name of the time zone in which the occurrences keep their local time of day (e.g. `Europe/Paris`),
    /// exact case. The app sends `TimeZone.current.identifier`.
    public var timeZoneId: String
    /// Monthly rules: the day of month of the series (1–31), stored by the server (`repeat_month_day`) from the local
    /// due date and kept by every occurrence, so that a « 31st » series comes back to the 31st after a short month.
    /// nil = the local day of the due date (a rule that was not stored yet). Never sent to the server.
    public var monthDay: Int?

    public init(
        frequency: Frequency,
        interval: Int = 1,
        weekdays: Set<Int>? = nil,
        timeZoneId: String,
        monthDay: Int? = nil
    ) {
        self.frequency = frequency
        self.interval = interval
        self.weekdays = weekdays
        self.timeZoneId = timeZoneId
        self.monthDay = monthDay
    }

    /// The rule's time zone, nil when this device does not know `timeZoneId`.
    public var timeZone: TimeZone? { TimeZone(identifier: timeZoneId) }
}
