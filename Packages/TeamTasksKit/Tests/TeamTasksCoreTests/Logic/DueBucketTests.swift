import Foundation
import Testing
@testable import TeamTasksCore

@Suite struct DueBucketTests {
    typealias F = LogicFixtures
    let calendar = LogicFixtures.parisCalendar

    private func bucket(due: Date?, status: TaskStatus = .todo, now: Date) -> DueBucket {
        DueBucket.bucket(for: F.task(1, status: status, due: due), now: now, calendar: calendar)
    }

    @Test func frenchTitlesInDisplayOrder() {
        #expect(DueBucket.allCases.map(\.title) == [
            "En retard", "Aujourd’hui", "Cette semaine", "Plus tard", "Sans échéance", "Terminées",
        ])
        #expect(DueBucket.allCases.sorted() == DueBucket.allCases)
    }

    @Test func midweekBoundaries() {
        // Thursday 24 September 2026, 12:00 (Paris). The week ends on Sunday 27 at midnight.
        let now = F.date(2026, 9, 24, 12, 0)
        #expect(bucket(due: F.date(2026, 9, 24, 11, 59), now: now) == .overdue)
        #expect(bucket(due: F.date(2026, 9, 20), now: now) == .overdue)
        #expect(bucket(due: now, now: now) == .today)
        #expect(bucket(due: F.date(2026, 9, 24, 23, 59, 59), now: now) == .today)
        #expect(bucket(due: F.date(2026, 9, 25, 0, 0), now: now) == .thisWeek)
        #expect(bucket(due: F.date(2026, 9, 27, 23, 59, 59), now: now) == .thisWeek)
        #expect(bucket(due: F.date(2026, 9, 28, 0, 0), now: now) == .later)
        #expect(bucket(due: F.date(2027, 1, 1), now: now) == .later)
        #expect(bucket(due: nil, now: now) == .noDueDate)
        #expect(bucket(due: F.date(2026, 9, 20), status: .done, now: now) == .done)
        #expect(bucket(due: nil, status: .done, now: now) == .done)
        #expect(bucket(due: F.date(2026, 9, 25), status: .inProgress, now: now) == .thisWeek)
    }

    @Test func nowExactlyAtMidnight() {
        let now = F.date(2026, 9, 28, 0, 0) // Monday 00:00
        #expect(bucket(due: F.date(2026, 9, 27, 23, 59), now: now) == .overdue)
        #expect(bucket(due: now, now: now) == .today)
        #expect(bucket(due: F.date(2026, 9, 28, 23, 59), now: now) == .today)
        #expect(bucket(due: F.date(2026, 10, 4, 23, 59), now: now) == .thisWeek)
        #expect(bucket(due: F.date(2026, 10, 5, 0, 0), now: now) == .later)
    }

    @Test func mondayHasAFullWeekAhead() {
        let now = F.date(2026, 9, 21, 8, 0) // Monday
        #expect(bucket(due: F.date(2026, 9, 22, 9, 0), now: now) == .thisWeek)
        #expect(bucket(due: F.date(2026, 9, 27, 23, 0), now: now) == .thisWeek)
        #expect(bucket(due: F.date(2026, 9, 28, 0, 0), now: now) == .later)
    }

    @Test func sundayHasNoThisWeekSection() {
        // Sunday is the last day of a French week: tomorrow (Monday) is already "Plus tard".
        let now = F.date(2026, 9, 27, 10, 0)
        let boundaries = DueBucketBoundaries(now: now, calendar: calendar)
        #expect(boundaries.startOfTomorrow == F.date(2026, 9, 28))
        #expect(boundaries.startOfNextWeek == boundaries.startOfTomorrow)
        #expect(bucket(due: F.date(2026, 9, 27, 22, 0), now: now) == .today)
        #expect(bucket(due: F.date(2026, 9, 28, 8, 0), now: now) == .later)
        let sections = DueBucket.sections(
            for: [F.task(1, due: F.date(2026, 9, 27, 22, 0)), F.task(2, due: F.date(2026, 9, 28, 8, 0))],
            now: now,
            calendar: calendar
        )
        #expect(sections.map(\.bucket) == [.today, .later])
    }

    @Test func weekStartFollowsTheInjectedCalendar() {
        var sundayFirst = Calendar(identifier: .gregorian)
        sundayFirst.timeZone = F.paris
        sundayFirst.firstWeekday = 1
        let saturday = F.date(2026, 9, 26, 10, 0)
        let sunday = F.date(2026, 9, 27, 10, 0)
        // Sunday-first week: on Saturday the week ends tonight; on Sunday a whole week lies ahead.
        #expect(DueBucket.bucket(for: F.task(1, due: sunday), now: saturday, calendar: sundayFirst) == .later)
        #expect(DueBucket.bucket(for: F.task(1, due: F.date(2026, 9, 28, 9, 0)), now: sunday, calendar: sundayFirst) == .thisWeek)
        // Monday-first (French) week: Sunday is still this week when seen from Saturday.
        #expect(DueBucket.bucket(for: F.task(1, due: sunday), now: saturday, calendar: calendar) == .thisWeek)
    }

    @Test func springForwardSunday() {
        // Sunday 29 March 2026: clocks jump from 02:00 to 03:00 (a 23-hour day).
        let now = F.date(2026, 3, 29, 1, 30)
        let boundaries = DueBucketBoundaries(now: now, calendar: calendar)
        #expect(boundaries.startOfToday == F.date(2026, 3, 29))
        #expect(boundaries.startOfTomorrow == F.date(2026, 3, 30))
        #expect(boundaries.startOfTomorrow.timeIntervalSince(boundaries.startOfToday) == 23 * 3600)
        #expect(boundaries.startOfNextWeek == boundaries.startOfTomorrow)
        // Monday 00:30 is only 23.5 hours after Sunday 00:00: a naive "+24 h" would wrongly call it today.
        #expect(bucket(due: F.date(2026, 3, 29, 23, 30), now: now) == .today)
        #expect(bucket(due: F.date(2026, 3, 30, 0, 30), now: now) == .later)
    }

    @Test func springForwardSeenFromSaturday() {
        let now = F.date(2026, 3, 28, 18, 0)
        #expect(bucket(due: F.date(2026, 3, 29, 3, 30), now: now) == .thisWeek)
        #expect(bucket(due: F.date(2026, 3, 29, 23, 59), now: now) == .thisWeek)
        #expect(bucket(due: F.date(2026, 3, 30, 0, 0), now: now) == .later)
    }

    @Test func fallBackSunday() {
        // Sunday 25 October 2026: clocks go back from 03:00 to 02:00 (a 25-hour day).
        let now = F.date(2026, 10, 25, 0, 30)
        let boundaries = DueBucketBoundaries(now: now, calendar: calendar)
        #expect(boundaries.startOfTomorrow.timeIntervalSince(boundaries.startOfToday) == 25 * 3600)
        // Sunday 23:30 is 24.5 hours after midnight: a naive +24 h would wrongly call it tomorrow.
        let sundayLate = boundaries.startOfToday.addingTimeInterval(24.5 * 3600)
        #expect(bucket(due: sundayLate, now: now) == .today)
        #expect(bucket(due: F.date(2026, 10, 26, 0, 0), now: now) == .later)
    }

    @Test func fallBackSeenFromFriday() {
        let now = F.date(2026, 10, 23, 12, 0)
        let boundaries = DueBucketBoundaries(now: now, calendar: calendar)
        #expect(boundaries.startOfNextWeek == F.date(2026, 10, 26))
        #expect(bucket(due: F.date(2026, 10, 25, 23, 59), now: now) == .thisWeek)
        #expect(bucket(due: F.date(2026, 10, 26, 0, 0), now: now) == .later)
    }

    @Test func sectionsAreOrderedNonEmptyAndSorted() {
        let now = F.date(2026, 9, 24, 12, 0)
        let tasks = [
            F.task(1, title: "Plus tard", due: F.date(2026, 10, 5)),
            F.task(2, title: "Sans date B", priority: .low, due: nil),
            F.task(3, title: "Retard", due: F.date(2026, 9, 23)),
            F.task(4, title: "Fini ancien", status: .done, due: F.date(2026, 9, 1), completedAt: F.date(2026, 9, 2)),
            F.task(5, title: "Aujourd'hui 20h", due: F.date(2026, 9, 24, 20, 0)),
            F.task(6, title: "Sans date A", priority: .high, due: nil),
            F.task(7, title: "Aujourd'hui 14h", due: F.date(2026, 9, 24, 14, 0)),
            F.task(8, title: "Fini récent", status: .done, due: nil, completedAt: F.date(2026, 9, 23)),
        ]
        let sections = DueBucket.sections(for: tasks, now: now, calendar: calendar)
        #expect(sections.map(\.bucket) == [.overdue, .today, .later, .noDueDate, .done])
        #expect(sections.map(\.title) == ["En retard", "Aujourd’hui", "Plus tard", "Sans échéance", "Terminées"])
        #expect(sections.map { $0.tasks.map(\.title) } == [
            ["Retard"],
            ["Aujourd'hui 14h", "Aujourd'hui 20h"],
            ["Plus tard"],
            ["Sans date A", "Sans date B"],
            ["Fini récent", "Fini ancien"],
        ])
        #expect(sections.allSatisfy { !$0.tasks.isEmpty })
        #expect(sections.reduce(0) { $0 + $1.tasks.count } == tasks.count)
    }

    @Test func sectionsUseTheRequestedSort() {
        let now = F.date(2026, 9, 24, 12, 0)
        let tasks = [
            F.task(1, title: "Basse tôt", priority: .low, due: F.date(2026, 9, 24, 13, 0)),
            F.task(2, title: "Haute tard", priority: .high, due: F.date(2026, 9, 24, 22, 0)),
        ]
        let byPriority = DueBucket.sections(for: tasks, now: now, calendar: calendar, sort: .priority)
        #expect(byPriority.first?.tasks.map(\.title) == ["Haute tard", "Basse tôt"])
        let byDue = DueBucket.sections(for: tasks, now: now, calendar: calendar)
        #expect(byDue.first?.tasks.map(\.title) == ["Basse tôt", "Haute tard"])
    }

    @Test func emptyInputGivesNoSections() {
        #expect(DueBucket.sections(for: [], now: F.date(2026, 9, 24), calendar: calendar).isEmpty)
    }
}
