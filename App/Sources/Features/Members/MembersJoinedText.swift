import Foundation
import TeamTasksCore

/// « Membre depuis le 14 septembre » under a member's name: the day only (the time of joining does not matter), with
/// its article, short enough for one caption line.
enum MembersJoinedText {
    /// « Membre depuis aujourd’hui », « … hier », « … le 14 septembre », « … le 1er décembre 2025 » (the year when it
    /// is not the current one).
    static func sentence(joinedAt: Date, now: Date, calendar: Calendar) -> String {
        "Membre depuis \(day(joinedAt, now: now, calendar: calendar))"
    }

    private static func day(_ date: Date, now: Date, calendar: Calendar) -> String {
        let formatter = FrenchDateFormatter(timeZone: calendar.timeZone)
        switch formatter.dayOffset(of: date, from: now) {
        case 0...:
            // Today, or « tomorrow » from a clock set late: never « depuis demain ».
            return "aujourd’hui"
        case -1:
            return "hier"
        default:
            let components = formatter.calendar.dateComponents([.day, .month, .year], from: date)
            let dayNumber = components.day ?? 1
            let month = FrenchDateFormatter.monthNames[((components.month ?? 1) - 1 + 12) % 12]
            var text = "le \(dayNumber == 1 ? "1er" : "\(dayNumber)") \(month)"
            if let year = components.year, year != formatter.calendar.component(.year, from: now) {
                text += " \(year)"
            }
            return text
        }
    }
}
