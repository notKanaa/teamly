import Foundation

/// A calendar date without a time of day nor a time zone: a SQL `date`, such as the away dates of a profile
/// (docs/CONTRACTS-V3.md §2). On the wire it is `"2026-10-12"` (ISO 8601, `isoString`).
///
/// Dates of the proleptic Gregorian calendar, compared in calendar order. `init(_:timeZone:)` gives the local date of
/// an instant, like SQL `(instant at time zone tz)::date`. Pure.
public struct LocalDate: Sendable, Hashable, Comparable, Codable, CustomStringConvertible {
    public var year: Int
    public var month: Int
    public var day: Int

    public init(year: Int, month: Int, day: Int) {
        self.year = year
        self.month = month
        self.day = day
    }

    /// The date of `"YYYY-MM-DD"` (4-digit year, 2-digit month and day); nil for anything else or an impossible date
    /// (`"2026-02-30"`).
    public init?(isoString: String) {
        let parts = isoString.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
              parts.allSatisfy({ $0.allSatisfy { ("0"..."9").contains($0) } }),
              let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2])
        else { return nil }
        self.init(year: year, month: month, day: day)
        guard isValid else { return nil }
    }

    /// The local date of `instant` in `timeZone` (SQL `(instant at time zone tz)::date`).
    public init(_ instant: Date, timeZone: TimeZone) {
        let local = LocalDateTime(instant, in: timeZone)
        self.init(dayNumber: local.day)
    }

    /// The date of `instant` in `calendar`'s time zone.
    public init(_ instant: Date, calendar: Calendar) {
        self.init(instant, timeZone: calendar.timeZone)
    }

    /// The date `dayNumber` days after 1970-01-01.
    public init(dayNumber: Int) {
        let civil = CivilDate(dayNumber: dayNumber)
        self.init(year: civil.year, month: civil.month, day: civil.day)
    }

    /// Days since 1970-01-01 (negative before).
    public var dayNumber: Int {
        CivilDate(year: year, month: month, day: day).dayNumber
    }

    /// True for an existing date of the Gregorian calendar (month 1…12, day within the month).
    public var isValid: Bool {
        (1...12).contains(month) && (1...CivilDate.daysInMonth(year: year, month: month)).contains(day)
    }

    /// `"2026-10-12"`.
    public var isoString: String {
        let yearText = String(year)
        let paddedYear = String(repeating: "0", count: max(0, 4 - yearText.count)) + yearText
        return "\(paddedYear)-\(month < 10 ? "0" : "")\(month)-\(day < 10 ? "0" : "")\(day)"
    }

    public var description: String { isoString }

    /// The date `days` days later (earlier when negative).
    public func adding(days: Int) -> LocalDate {
        LocalDate(dayNumber: dayNumber + days)
    }

    /// Days from `self` to `other` (SQL `other - self`): 0 for the same date, 1 for the next day.
    public func days(to other: LocalDate) -> Int {
        other.dayNumber - dayNumber
    }

    /// ISO weekday: 1 = Monday … 7 = Sunday.
    public var isoWeekday: Int {
        NextDueCalculator.isoWeekday(dayNumber)
    }

    /// Midnight at the start of this date in `calendar`'s time zone (nil when the calendar cannot build it).
    public func startDate(in calendar: Calendar) -> Date? {
        calendar.date(from: DateComponents(year: year, month: month, day: day))
    }

    public static func < (lhs: LocalDate, rhs: LocalDate) -> Bool {
        (lhs.year, lhs.month, lhs.day) < (rhs.year, rhs.month, rhs.day)
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let text = try container.decode(String.self)
        guard let date = LocalDate(isoString: text) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid date \(text)")
        }
        self = date
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(isoString)
    }
}
