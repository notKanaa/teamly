import Foundation

/// Calendar injected into the view models (docs/CONTRACTS.md §7): Gregorian with the French rules (weeks start
/// on Monday, ISO week numbering) in the device's time zone, following its changes.
enum AppCalendar {
    static var french: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "fr_FR")
        calendar.timeZone = TimeZone.autoupdatingCurrent
        calendar.firstWeekday = 2
        calendar.minimumDaysInFirstWeek = 4
        return calendar
    }
}
