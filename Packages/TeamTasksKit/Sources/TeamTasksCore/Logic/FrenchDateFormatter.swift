import Foundation

extension Calendar {
    /// Gregorian calendar with French conventions: `fr_FR` locale, weeks starting on Monday (ISO 8601),
    /// in the given time zone. Used for due-date sections and French wording.
    public static func frenchGregorian(timeZone: TimeZone) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "fr_FR")
        calendar.timeZone = timeZone
        calendar.firstWeekday = 2
        calendar.minimumDaysInFirstWeek = 4
        return calendar
    }
}

/// French wording of dates and times ("aujourd'hui à 20:00", "mardi 1er septembre 2027").
///
/// Written by hand instead of relying on `DateFormatter`, so the output is byte-for-byte identical on iOS
/// and on Linux whatever the ICU data version (no narrow no-break spaces, no locale surprises).
/// Only the time zone is configurable; the calendar is always Gregorian.
public struct FrenchDateFormatter: Sendable, Hashable {
    /// Weekday names indexed by `Calendar.Component.weekday - 1` (1 = Sunday).
    public static let weekdayNames = ["dimanche", "lundi", "mardi", "mercredi", "jeudi", "vendredi", "samedi"]
    /// Month names indexed by `month - 1`.
    public static let monthNames = [
        "janvier", "février", "mars", "avril", "mai", "juin",
        "juillet", "août", "septembre", "octobre", "novembre", "décembre",
    ]

    /// Gregorian calendar used for every computation (French conventions, injected time zone).
    public let calendar: Calendar

    public init(timeZone: TimeZone) {
        calendar = .frenchGregorian(timeZone: timeZone)
    }

    public var timeZone: TimeZone { calendar.timeZone }

    /// 24-hour wall-clock time, e.g. `08:05`, `20:00`.
    public func time(_ date: Date) -> String {
        let components = calendar.dateComponents([.hour, .minute], from: date)
        return "\(Self.twoDigits(components.hour ?? 0)):\(Self.twoDigits(components.minute ?? 0))"
    }

    /// Full day, e.g. `jeudi 24 septembre`, `mardi 1er septembre`.
    /// The year is appended (`vendredi 1er janvier 2027`) when `includeYear` is true.
    public func day(_ date: Date, includeYear: Bool) -> String {
        let components = calendar.dateComponents([.weekday, .day, .month, .year], from: date)
        let weekday = Self.weekdayNames[((components.weekday ?? 1) - 1 + 7) % 7]
        let dayNumber = components.day ?? 1
        let dayText = dayNumber == 1 ? "1er" : "\(dayNumber)"
        let month = Self.monthNames[((components.month ?? 1) - 1 + 12) % 12]
        var text = "\(weekday) \(dayText) \(month)"
        if includeYear, let year = components.year {
            text += " \(year)"
        }
        return text
    }

    /// Number of calendar days from `reference`'s day to `date`'s day (0 = same day, 1 = tomorrow, -1 = yesterday).
    /// Correct across daylight-saving transitions (days of 23 or 25 hours).
    public func dayOffset(of date: Date, from reference: Date) -> Int {
        let start = calendar.startOfDay(for: reference)
        let end = calendar.startOfDay(for: date)
        return calendar.dateComponents([.day], from: start, to: end).day ?? 0
    }

    /// Day relative to `reference`: `aujourd'hui`, `demain`, `hier`, otherwise the full day
    /// (with the year when it differs from the reference's year). Lowercase, to be embedded in a sentence.
    public func relativeDay(_ date: Date, relativeTo reference: Date) -> String {
        switch dayOffset(of: date, from: reference) {
        case 0: return "aujourd'hui"
        case 1: return "demain"
        case -1: return "hier"
        default:
            let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: reference)
            return day(date, includeYear: !sameYear)
        }
    }

    /// Day and time relative to `reference`, e.g. `aujourd'hui à 20:00`, `demain à 08:30`,
    /// `lundi 28 septembre à 09:00`, `vendredi 1er janvier 2027 à 10:00`. Lowercase.
    public func relativeDateTime(_ date: Date, relativeTo reference: Date) -> String {
        "\(relativeDay(date, relativeTo: reference)) à \(time(date))"
    }

    /// Uppercases the first character, for strings starting a sentence or a label
    /// (`aujourd'hui à 20:00` → `Aujourd'hui à 20:00`).
    public static func capitalizingFirstLetter(_ text: String) -> String {
        guard let first = text.first else { return text }
        return first.uppercased() + text.dropFirst()
    }

    private static func twoDigits(_ value: Int) -> String {
        value < 10 && value >= 0 ? "0\(value)" : "\(value)"
    }
}
