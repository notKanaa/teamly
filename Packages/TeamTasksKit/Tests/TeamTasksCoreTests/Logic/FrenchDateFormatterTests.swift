import Foundation
import Testing
@testable import TeamTasksCore

@Suite struct FrenchDateFormatterTests {
    let formatter = FrenchDateFormatter(timeZone: LogicFixtures.paris)
    typealias F = LogicFixtures

    @Test func frenchCalendarStartsWeeksOnMonday() {
        let calendar = Calendar.frenchGregorian(timeZone: F.paris)
        #expect(calendar.firstWeekday == 2)
        #expect(calendar.minimumDaysInFirstWeek == 4)
        #expect(calendar.timeZone == F.paris)
        #expect(calendar.identifier == .gregorian)
    }

    @Test func timeIsZeroPadded24Hour() {
        #expect(formatter.time(F.date(2026, 9, 24, 8, 5)) == "08:05")
        #expect(formatter.time(F.date(2026, 9, 24, 20, 0)) == "20:00")
        #expect(formatter.time(F.date(2026, 9, 24, 0, 0)) == "00:00")
        #expect(formatter.time(F.date(2026, 9, 24, 23, 59)) == "23:59")
    }

    @Test func timeUsesTheInjectedTimeZone() {
        let utc = FrenchDateFormatter(timeZone: TimeZone(identifier: "UTC")!)
        let date = F.date(2026, 7, 1, 20, 0) // 18:00 UTC (CEST = UTC+2)
        #expect(utc.time(date) == "18:00")
        #expect(formatter.time(date) == "20:00")
    }

    @Test func fullDayNames() {
        #expect(formatter.day(F.date(2026, 9, 24), includeYear: false) == "jeudi 24 septembre")
        #expect(formatter.day(F.date(2026, 9, 1), includeYear: false) == "mardi 1er septembre")
        #expect(formatter.day(F.date(2027, 1, 1), includeYear: true) == "vendredi 1er janvier 2027")
        #expect(formatter.day(F.date(2026, 8, 16), includeYear: false) == "dimanche 16 août")
        #expect(formatter.day(F.date(2026, 2, 2), includeYear: false) == "lundi 2 février")
        #expect(formatter.day(F.date(2026, 12, 12), includeYear: false) == "samedi 12 décembre")
    }

    @Test func relativeWording() {
        let reference = F.date(2026, 9, 24, 10, 0)
        #expect(formatter.relativeDateTime(F.date(2026, 9, 24, 20, 0), relativeTo: reference) == "aujourd’hui à 20:00")
        #expect(formatter.relativeDateTime(F.date(2026, 9, 25, 8, 30), relativeTo: reference) == "demain à 08:30")
        #expect(formatter.relativeDateTime(F.date(2026, 9, 23, 23, 59), relativeTo: reference) == "hier à 23:59")
        #expect(formatter.relativeDateTime(F.date(2026, 9, 28, 9, 0), relativeTo: reference) == "lundi à 09:00")
        #expect(formatter.relativeDateTime(F.date(2027, 1, 1, 10, 0), relativeTo: reference) == "vendredi 1er janvier 2027 à 10:00")
        #expect(formatter.relativeDateTime(F.date(2026, 9, 20, 10, 0), relativeTo: reference) == "dimanche 20 septembre à 10:00")
    }

    /// 2 to 6 days ahead: the weekday alone; from 7 days ahead and for past days: the full day (review UX-04).
    @Test func nextDaysShowTheWeekdayOnly() {
        let reference = F.date(2026, 9, 24, 10, 0) // Thursday
        #expect(formatter.relativeDay(F.date(2026, 9, 26, 9, 0), relativeTo: reference) == "samedi")
        #expect(formatter.relativeDay(F.date(2026, 9, 27, 9, 0), relativeTo: reference) == "dimanche")
        #expect(formatter.relativeDay(F.date(2026, 9, 30, 23, 59), relativeTo: reference) == "mercredi")
        #expect(formatter.relativeDay(F.date(2026, 10, 1, 0, 0), relativeTo: reference) == "jeudi 1er octobre")
        #expect(formatter.relativeDay(F.date(2026, 9, 22, 9, 0), relativeTo: reference) == "mardi 22 septembre")
        // Across the new year, the weekday alone as well (no year needed within the week).
        let newYearsEve = F.date(2026, 12, 30, 10, 0)
        #expect(formatter.relativeDateTime(F.date(2027, 1, 2, 18, 0), relativeTo: newYearsEve) == "samedi à 18:00")
        #expect(formatter.relativeDateTime(F.date(2027, 1, 6, 18, 0), relativeTo: newYearsEve) == "mercredi 6 janvier 2027 à 18:00")
    }

    /// In the middle of a sentence: « Créée par Lucas Bernard le lundi 14 septembre à 10:00 » (review UX-03).
    @Test func relativeWordingInASentence() {
        let reference = F.date(2026, 9, 24, 10, 0)
        #expect(formatter.relativeDateTimeInSentence(F.date(2026, 9, 24, 9, 0), relativeTo: reference) == "aujourd’hui à 09:00")
        #expect(formatter.relativeDateTimeInSentence(F.date(2026, 9, 23, 23, 59), relativeTo: reference) == "hier à 23:59")
        #expect(formatter.relativeDateTimeInSentence(F.date(2026, 9, 25, 8, 30), relativeTo: reference) == "demain à 08:30")
        #expect(formatter.relativeDateTimeInSentence(F.date(2026, 9, 22, 10, 0), relativeTo: reference) == "le mardi 22 septembre à 10:00")
        #expect(formatter.relativeDateTimeInSentence(F.date(2026, 9, 14, 10, 0), relativeTo: reference) == "le lundi 14 septembre à 10:00")
        #expect(formatter.relativeDateTimeInSentence(F.date(2026, 9, 28, 9, 0), relativeTo: reference) == "le lundi 28 septembre à 09:00")
        #expect(formatter.relativeDateTimeInSentence(F.date(2025, 12, 31, 10, 0), relativeTo: reference) == "le mercredi 31 décembre 2025 à 10:00")
    }

    @Test func midnightBoundaries() {
        let reference = F.date(2026, 9, 24, 23, 59, 59)
        #expect(formatter.relativeDay(F.date(2026, 9, 25, 0, 0), relativeTo: reference) == "demain")
        #expect(formatter.relativeDay(F.date(2026, 9, 24, 0, 0), relativeTo: reference) == "aujourd’hui")
    }

    @Test func dayOffsetAcrossDaylightSavingTransitions() {
        // Spring forward: Sunday 29 March 2026 has 23 hours in Paris.
        let saturdayNight = F.date(2026, 3, 28, 23, 30)
        #expect(formatter.dayOffset(of: F.date(2026, 3, 29, 23, 30), from: saturdayNight) == 1)
        #expect(formatter.dayOffset(of: F.date(2026, 3, 30, 0, 30), from: saturdayNight) == 2)
        // Fall back: Sunday 25 October 2026 has 25 hours in Paris.
        let sundayEarly = F.date(2026, 10, 25, 0, 30)
        let sundayLate = sundayEarly.addingTimeInterval(24 * 3600) // 23:30 the same day
        #expect(formatter.time(sundayLate) == "23:30")
        #expect(formatter.relativeDay(sundayLate, relativeTo: sundayEarly) == "aujourd’hui")
        #expect(formatter.relativeDateTime(F.date(2026, 10, 26, 9, 0), relativeTo: sundayEarly) == "demain à 09:00")
    }

    /// Zones whose spring-forward transition skips midnight (Azores, Chile…): `startOfDay` of that day is 01:00,
    /// so the next day starts only 23 hours later; the offset must still count calendar days.
    @Test(arguments: ["Atlantic/Azores", "America/Santiago"])
    func dayOffsetOnDaysWhoseMidnightIsSkipped(zone: String) throws {
        let formatter = FrenchDateFormatter(timeZone: try #require(TimeZone(identifier: zone)))
        let calendar = formatter.calendar
        var day = try #require(calendar.date(from: DateComponents(year: 2026, month: 1, day: 1, hour: 12)))
        var transitionDay: Date?
        for _ in 0..<366 {
            if calendar.component(.hour, from: calendar.startOfDay(for: day)) != 0 {
                transitionDay = day
                break
            }
            day = try #require(calendar.date(byAdding: .day, value: 1, to: day))
        }
        let transition = try #require(transitionDay, "no skipped midnight in 2026 for \(zone)")
        let noon = try #require(calendar.date(bySettingHour: 12, minute: 0, second: 0, of: transition))
        let ten = try #require(calendar.date(bySettingHour: 10, minute: 0, second: 0, of: transition))
        let tomorrow = try #require(calendar.date(byAdding: .day, value: 1, to: ten))
        let inTwoDays = try #require(calendar.date(byAdding: .day, value: 2, to: ten))
        let yesterday = try #require(calendar.date(byAdding: .day, value: -1, to: ten))
        #expect(formatter.dayOffset(of: tomorrow, from: noon) == 1)
        #expect(formatter.dayOffset(of: inTwoDays, from: noon) == 2)
        #expect(formatter.dayOffset(of: yesterday, from: noon) == -1)
        #expect(formatter.dayOffset(of: noon, from: tomorrow) == -1)
        #expect(formatter.relativeDateTime(tomorrow, relativeTo: noon) == "demain à 10:00")
        #expect(formatter.relativeDateTime(ten, relativeTo: noon) == "aujourd’hui à 10:00")
    }

    @Test func capitalizesFirstLetter() {
        #expect(FrenchDateFormatter.capitalizingFirstLetter("aujourd’hui à 20:00") == "Aujourd’hui à 20:00")
        #expect(FrenchDateFormatter.capitalizingFirstLetter("école") == "École")
        #expect(FrenchDateFormatter.capitalizingFirstLetter("") == "")
    }
}
