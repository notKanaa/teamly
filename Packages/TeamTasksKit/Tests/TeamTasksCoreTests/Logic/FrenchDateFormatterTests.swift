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
        #expect(formatter.relativeDateTime(F.date(2026, 9, 24, 20, 0), relativeTo: reference) == "aujourd'hui à 20:00")
        #expect(formatter.relativeDateTime(F.date(2026, 9, 25, 8, 30), relativeTo: reference) == "demain à 08:30")
        #expect(formatter.relativeDateTime(F.date(2026, 9, 23, 23, 59), relativeTo: reference) == "hier à 23:59")
        #expect(formatter.relativeDateTime(F.date(2026, 9, 28, 9, 0), relativeTo: reference) == "lundi 28 septembre à 09:00")
        #expect(formatter.relativeDateTime(F.date(2027, 1, 1, 10, 0), relativeTo: reference) == "vendredi 1er janvier 2027 à 10:00")
        #expect(formatter.relativeDateTime(F.date(2026, 9, 20, 10, 0), relativeTo: reference) == "dimanche 20 septembre à 10:00")
    }

    @Test func midnightBoundaries() {
        let reference = F.date(2026, 9, 24, 23, 59, 59)
        #expect(formatter.relativeDay(F.date(2026, 9, 25, 0, 0), relativeTo: reference) == "demain")
        #expect(formatter.relativeDay(F.date(2026, 9, 24, 0, 0), relativeTo: reference) == "aujourd'hui")
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
        #expect(formatter.relativeDay(sundayLate, relativeTo: sundayEarly) == "aujourd'hui")
        #expect(formatter.relativeDateTime(F.date(2026, 10, 26, 9, 0), relativeTo: sundayEarly) == "demain à 09:00")
    }

    @Test func capitalizesFirstLetter() {
        #expect(FrenchDateFormatter.capitalizingFirstLetter("aujourd'hui à 20:00") == "Aujourd'hui à 20:00")
        #expect(FrenchDateFormatter.capitalizingFirstLetter("école") == "École")
        #expect(FrenchDateFormatter.capitalizingFirstLetter("") == "")
    }
}
