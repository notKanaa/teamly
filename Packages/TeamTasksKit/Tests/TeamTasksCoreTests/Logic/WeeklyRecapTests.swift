import Foundation
import Testing
@testable import TeamTasksCore

@Suite struct WeeklyRecapTests {
    typealias F = LogicFixtures

    static let group = F.groupA
    static let camille = UserProfile(id: F.uuid(0xC1), displayName: "Camille Martin")
    static let lucas = UserProfile(id: F.uuid(0xC2), displayName: "Lucas Bernard")
    static let ines = UserProfile(id: F.uuid(0xC3), displayName: "Inès Dubois")
    static let zoe = UserProfile(id: F.uuid(0xC4), displayName: "zoé")
    /// Someone who left the group.
    static let departed = F.uuid(0xDE)

    static let members = [camille, lucas, ines, zoe].map {
        Membership(groupId: group, user: $0, role: .member, joinedAt: F.date(2026, 1, 1))
    }

    /// Thursday 24 September 2026, 10:00 in Paris: the current week runs from Monday 21 to Monday 28.
    static let now = F.date(2026, 9, 24, 10)

    private var number = 0

    private mutating func done(_ user: UUID?, _ date: Date, times: Int = 1) -> [TaskCompletion] {
        (0..<times).map { _ in
            number += 1
            return TaskCompletion(taskId: F.uuid(number), completedBy: user, completedAt: date)
        }
    }

    private func recap(_ completions: [TaskCompletion], members: [Membership] = WeeklyRecapTests.members) -> WeeklyRecap {
        WeeklyRecap(completions: completions, members: members, now: Self.now, calendar: F.parisCalendar)
    }

    // MARK: Weeks

    @Test func weeksRunFromMondayMidnightInTheCalendarsTimeZone() {
        #expect(WeeklyRecap.weekStart(of: Self.now, calendar: F.parisCalendar) == F.date(2026, 9, 21))
        #expect(WeeklyRecap.weekStart(of: F.date(2026, 9, 21), calendar: F.parisCalendar) == F.date(2026, 9, 21))
        #expect(WeeklyRecap.weekStart(of: F.date(2026, 9, 27, 23, 59, 59), calendar: F.parisCalendar) == F.date(2026, 9, 21))
        #expect(WeeklyRecap.weekStart(of: F.date(2026, 9, 28), calendar: F.parisCalendar) == F.date(2026, 9, 28))
        // Three weeks before the current one.
        #expect(WeeklyRecap.readStart(now: Self.now, calendar: F.parisCalendar) == F.date(2026, 8, 31))
        let recap = recap([])
        #expect(recap.weekStart == F.date(2026, 9, 21))
        #expect(recap.weekEnd == F.date(2026, 9, 28))
    }

    /// Mondays, whatever the calendar's `firstWeekday`, and across the DST changes.
    @Test func weeksStartOnMondayAcrossDaylightSavingTime() {
        var sundayFirst = F.parisCalendar
        sundayFirst.firstWeekday = 1
        #expect(WeeklyRecap.weekStart(of: F.date(2026, 9, 27, 12), calendar: sundayFirst) == F.date(2026, 9, 21))
        // The week of the fall-back change (Sunday 25 October) and the one after it.
        #expect(WeeklyRecap.weekStart(of: F.date(2026, 10, 25, 12), calendar: F.parisCalendar) == F.date(2026, 10, 19))
        #expect(WeeklyRecap.readStart(now: F.date(2026, 10, 27, 9), calendar: F.parisCalendar) == F.date(2026, 10, 5))
        let recap = WeeklyRecap(completions: [], members: [], now: F.date(2026, 10, 20, 9), calendar: F.parisCalendar)
        #expect(recap.weekEnd == F.date(2026, 10, 26))
        #expect(recap.weekEnd.timeIntervalSince(recap.weekStart) == 7 * 86_400 + 3600)
    }

    // MARK: Total and podium

    @Test func totalCountsEveryTaskDoneThisWeek() {
        var test = self
        let completions = test.done(Self.camille.id, F.date(2026, 9, 21), times: 2) // Monday 00:00: this week
            + test.done(Self.departed, F.date(2026, 9, 22, 8))
            + test.done(nil, F.date(2026, 9, 23, 8))
            + test.done(Self.lucas.id, F.date(2026, 9, 20, 23, 59, 59)) // last week
            + test.done(Self.lucas.id, F.date(2026, 9, 28)) // next week (device clock behind)
            + test.done(Self.lucas.id, F.date(2026, 8, 30, 12)) // before the weeks read
        let recap = recap(completions)
        #expect(recap.total == 4)
        #expect(recap.podium == [WeeklyRecap.Entry(user: Self.camille, count: 2)])
    }

    /// Departed members and unknown completers count in the total only; ties follow `NameOrder`; three places.
    @Test func podiumOfCurrentMembersWithNameOrderTies() {
        var test = self
        let day = F.date(2026, 9, 23, 18)
        let completions = test.done(Self.departed, day, times: 5)
            + test.done(nil, day, times: 4)
            + test.done(Self.zoe.id, day, times: 3)
            + test.done(Self.lucas.id, day, times: 3)
            + test.done(Self.camille.id, day, times: 3)
            + test.done(Self.ines.id, day, times: 1)
        let recap = recap(completions)
        #expect(recap.total == 19)
        // « Camille Martin » < « Lucas Bernard » < « zoé » (case- and accent-insensitive).
        #expect(recap.podium.map(\.user) == [Self.camille, Self.lucas, Self.zoe])
        #expect(recap.podium.map(\.count) == [3, 3, 3])
        #expect(recap.streak == nil)
    }

    @Test func identicalNamesAreOrderedByUserId() {
        let twinA = UserProfile(id: F.uuid(0xA), displayName: "Alex")
        let twinB = UserProfile(id: F.uuid(0xB), displayName: "Alex")
        let members = [twinB, twinA].map { Membership(groupId: Self.group, user: $0, role: .member, joinedAt: F.date(2026, 1, 1)) }
        var test = self
        let completions = test.done(twinB.id, F.date(2026, 9, 22)) + test.done(twinA.id, F.date(2026, 9, 22))
        #expect(recap(completions, members: members).podium.map(\.user.id) == [twinA.id, twinB.id])
    }

    @Test func noCompletionMeansAnEmptyRecap() {
        let recap = recap([])
        #expect(recap.total == 0)
        #expect(recap.podium.isEmpty)
        #expect(recap.streak == nil)
    }

    // MARK: Streak

    /// Lucas is the sole leader this week and the two weeks before, not three weeks ago: a streak of 3.
    @Test func streakOfConsecutiveSoleLeaderships() {
        var test = self
        let completions = test.done(Self.lucas.id, F.date(2026, 9, 24, 8), times: 2)
            + test.done(Self.camille.id, F.date(2026, 9, 22, 8))
            + test.done(Self.lucas.id, F.date(2026, 9, 15, 8))
            + test.done(Self.lucas.id, F.date(2026, 9, 7))
            + test.done(Self.departed, F.date(2026, 9, 8), times: 4) // ignored: not a member
            + test.done(Self.camille.id, F.date(2026, 9, 1), times: 2)
            + test.done(Self.lucas.id, F.date(2026, 9, 2))
        #expect(recap(completions).streak == WeeklyRecap.Streak(user: Self.lucas, weeks: 3))
    }

    @Test func streakCoversAtMostTheWeeksRead() {
        var test = self
        let completions = [F.date(2026, 9, 24), F.date(2026, 9, 14), F.date(2026, 9, 7), F.date(2026, 8, 31), F.date(2026, 8, 24)]
            .flatMap { test.done(Self.ines.id, $0) }
        #expect(recap(completions).streak == WeeklyRecap.Streak(user: Self.ines, weeks: WeeklyRecap.weeksRead))
    }

    @Test func aStreakNeedsTwoWeeksAndSoleLeaders() {
        var test = self
        // One week only.
        let single = test.done(Self.lucas.id, F.date(2026, 9, 24))
        #expect(recap(single).streak == nil)
        // A tie last week breaks the streak.
        let tie = test.done(Self.lucas.id, F.date(2026, 9, 24))
            + test.done(Self.lucas.id, F.date(2026, 9, 15))
            + test.done(Self.ines.id, F.date(2026, 9, 16))
        #expect(recap(tie).streak == nil)
        // A tie this week: no leader, no streak.
        let tieNow = test.done(Self.lucas.id, F.date(2026, 9, 24))
            + test.done(Self.ines.id, F.date(2026, 9, 24))
            + test.done(Self.lucas.id, F.date(2026, 9, 15))
        #expect(recap(tieNow).streak == nil)
        // An empty week in between breaks it too.
        let gap = test.done(Self.lucas.id, F.date(2026, 9, 24)) + test.done(Self.lucas.id, F.date(2026, 9, 8))
        #expect(recap(gap).streak == nil)
    }

    /// The leader must still be a member: a streak of someone who left is not shown.
    @Test func departedLeadersHaveNoStreak() {
        var test = self
        let completions = test.done(Self.departed, F.date(2026, 9, 24), times: 3)
            + test.done(Self.departed, F.date(2026, 9, 15), times: 3)
            + test.done(Self.camille.id, F.date(2026, 9, 24))
        let recap = recap(completions)
        #expect(recap.podium == [WeeklyRecap.Entry(user: Self.camille, count: 1)])
        #expect(recap.streak == nil)
    }
}
