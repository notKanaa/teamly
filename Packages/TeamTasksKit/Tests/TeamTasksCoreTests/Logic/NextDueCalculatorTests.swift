import Foundation
import Testing
@testable import TeamTasksCore

/// One row of the test-vector table of docs/CONTRACTS-V2.md §6 (computed with PostgreSQL's `private.next_due_at`).
struct RecurrenceVector: Sendable, CustomTestStringConvertible {
    let name: String
    let rule: RecurrenceRule
    let dueAt: String
    let now: String
    let expected: String

    var testDescription: String { name }

    /// UTC instant of `2026-09-24T18:00:00Z`.
    static func instant(_ text: String) -> Date {
        let parts = text.dropLast().split(whereSeparator: { "-T:".contains($0) }).compactMap { Int($0) }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar.date(from: DateComponents(
            year: parts[0], month: parts[1], day: parts[2], hour: parts[3], minute: parts[4], second: parts[5]
        ))!
    }

    static func utc(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        func two(_ value: Int?) -> String {
            let text = String(value ?? 0)
            return text.count < 2 ? "0" + text : text
        }
        return "\(c.year ?? 0)-\(two(c.month))-\(two(c.day))T\(two(c.hour)):\(two(c.minute)):\(two(c.second))Z"
    }
}

private func rule(
    _ frequency: RecurrenceRule.Frequency,
    interval: Int = 1,
    weekdays: Set<Int>? = nil,
    tz: String = "Europe/Paris",
    monthDay: Int? = nil
) -> RecurrenceRule {
    RecurrenceRule(frequency: frequency, interval: interval, weekdays: weekdays, timeZoneId: tz, monthDay: monthDay)
}

@Suite struct NextDueCalculatorTests {
    /// Every row of docs/CONTRACTS-V2.md §6, in order.
    static let vectors: [RecurrenceVector] = [
        .init(name: "1 daily, 20:00 CEST", rule: rule(.daily),
              dueAt: "2026-09-24T18:00:00Z", now: "2026-09-24T19:00:00Z", expected: "2026-09-25T18:00:00Z"),
        .init(name: "2 completed early", rule: rule(.daily),
              dueAt: "2026-09-26T18:00:00Z", now: "2026-09-24T10:00:00Z", expected: "2026-09-27T18:00:00Z"),
        .init(name: "3 every 3 days", rule: rule(.daily, interval: 3),
              dueAt: "2026-09-24T06:00:00Z", now: "2026-09-24T07:00:00Z", expected: "2026-09-27T06:00:00Z"),
        .init(name: "4 missed occurrences skipped", rule: rule(.daily),
              dueAt: "2026-09-20T06:00:00Z", now: "2026-09-24T12:00:00Z", expected: "2026-09-25T06:00:00Z"),
        .init(name: "5 a slot due exactly now is skipped", rule: rule(.daily),
              dueAt: "2026-09-22T06:00:00Z", now: "2026-09-24T06:00:00Z", expected: "2026-09-25T06:00:00Z"),
        .init(name: "6 weekly, the due date's weekday", rule: rule(.weekly),
              dueAt: "2026-09-21T07:00:00Z", now: "2026-09-21T08:00:00Z", expected: "2026-09-28T07:00:00Z"),
        .init(name: "7 every 2 weeks", rule: rule(.weekly, interval: 2),
              dueAt: "2026-09-21T07:00:00Z", now: "2026-09-21T08:00:00Z", expected: "2026-10-05T07:00:00Z"),
        .init(name: "8 Mon/Wed/Fri from a Wednesday", rule: rule(.weekly, weekdays: [1, 3, 5]),
              dueAt: "2026-09-23T16:00:00Z", now: "2026-09-23T17:00:00Z", expected: "2026-09-25T16:00:00Z"),
        .init(name: "9 Mon/Wed/Fri from a Friday", rule: rule(.weekly, weekdays: [1, 3, 5]),
              dueAt: "2026-09-25T16:00:00Z", now: "2026-09-25T17:00:00Z", expected: "2026-09-28T16:00:00Z"),
        .init(name: "10 Tue/Thu every 2 weeks from a Tuesday", rule: rule(.weekly, interval: 2, weekdays: [2, 4]),
              dueAt: "2026-09-22T16:00:00Z", now: "2026-09-22T17:00:00Z", expected: "2026-09-24T16:00:00Z"),
        .init(name: "11 Tue/Thu every 2 weeks from a Thursday", rule: rule(.weekly, interval: 2, weekdays: [2, 4]),
              dueAt: "2026-09-24T16:00:00Z", now: "2026-09-24T17:00:00Z", expected: "2026-10-06T16:00:00Z"),
        .init(name: "12 due on a Sunday, outside the weekdays", rule: rule(.weekly, interval: 2, weekdays: [1, 3]),
              dueAt: "2026-09-27T08:00:00Z", now: "2026-09-27T09:00:00Z", expected: "2026-10-05T08:00:00Z"),
        .init(name: "13 weekdays, missed occurrences skipped", rule: rule(.weekly, weekdays: [1, 3, 5]),
              dueAt: "2026-09-14T16:00:00Z", now: "2026-09-24T12:00:00Z", expected: "2026-09-25T16:00:00Z"),
        .init(name: "14 the 31st → February 28", rule: rule(.monthly),
              dueAt: "2026-01-31T17:00:00Z", now: "2026-01-31T18:00:00Z", expected: "2026-02-28T17:00:00Z"),
        .init(name: "15 → back to March 31 (after the DST change)", rule: rule(.monthly, monthDay: 31),
              dueAt: "2026-02-28T17:00:00Z", now: "2026-02-28T18:00:00Z", expected: "2026-03-31T16:00:00Z"),
        .init(name: "16 → April 30", rule: rule(.monthly, monthDay: 31),
              dueAt: "2026-03-31T16:00:00Z", now: "2026-03-31T17:00:00Z", expected: "2026-04-30T16:00:00Z"),
        .init(name: "17 → May 31, no drift", rule: rule(.monthly, monthDay: 31),
              dueAt: "2026-04-30T16:00:00Z", now: "2026-04-30T17:00:00Z", expected: "2026-05-31T16:00:00Z"),
        .init(name: "18 leap year", rule: rule(.monthly, monthDay: 31),
              dueAt: "2028-01-31T17:00:00Z", now: "2028-01-31T18:00:00Z", expected: "2028-02-29T17:00:00Z"),
        .init(name: "19 every 3 months", rule: rule(.monthly, interval: 3),
              dueAt: "2026-01-15T08:00:00Z", now: "2026-01-15T09:00:00Z", expected: "2026-04-15T07:00:00Z"),
        .init(name: "20 monthly, missed occurrences skipped", rule: rule(.monthly),
              dueAt: "2026-05-15T07:00:00Z", now: "2026-09-24T12:00:00Z", expected: "2026-10-15T07:00:00Z"),
        .init(name: "21 spring DST change: 08:00 CET → 08:00 CEST", rule: rule(.daily),
              dueAt: "2026-03-28T07:00:00Z", now: "2026-03-28T08:00:00Z", expected: "2026-03-29T06:00:00Z"),
        .init(name: "22 autumn DST change: 18:30 CEST → 18:30 CET", rule: rule(.weekly),
              dueAt: "2026-10-19T16:30:00Z", now: "2026-10-19T17:00:00Z", expected: "2026-10-26T17:30:00Z"),
        .init(name: "23 another zone: 09:00 EST → 09:00 EDT", rule: rule(.daily, tz: "America/New_York"),
              dueAt: "2026-03-07T14:00:00Z", now: "2026-03-07T15:00:00Z", expected: "2026-03-08T13:00:00Z"),
        .init(name: "24 the local date counts (Tokyo)", rule: rule(.monthly, tz: "Asia/Tokyo"),
              dueAt: "2026-01-30T15:30:00Z", now: "2026-01-30T16:00:00Z", expected: "2026-02-27T15:30:00Z"),
        .init(name: "25 Sunday only", rule: rule(.weekly, weekdays: [7], tz: "UTC"),
              dueAt: "2026-09-27T20:00:00Z", now: "2026-09-27T21:00:00Z", expected: "2026-10-04T20:00:00Z"),
        .init(name: "26 10 000 steps at most", rule: rule(.daily),
              dueAt: "1990-01-01T08:00:00Z", now: "2026-09-24T12:00:00Z", expected: "2017-05-19T07:00:00Z"),
        .init(name: "27 yearly on February 29", rule: rule(.monthly, interval: 12, monthDay: 29),
              dueAt: "2027-02-28T09:00:00Z", now: "2027-02-28T10:00:00Z", expected: "2028-02-29T09:00:00Z"),
    ]

    /// PostgreSQL's reading of local times that do not exist or are ambiguous (docs/CONTRACTS-V2.md §6 « DST »,
    /// pgTAP `13_v2_recurrence`).
    static let dstVectors: [RecurrenceVector] = [
        .init(name: "02:30 on the spring-forward day does not exist: 03:30 CEST", rule: rule(.daily),
              dueAt: "2026-03-28T01:30:00Z", now: "2026-03-28T02:00:00Z", expected: "2026-03-29T01:30:00Z"),
        .init(name: "02:30 on the fall-back day is ambiguous: the later instant, 02:30 CET", rule: rule(.daily),
              dueAt: "2026-10-24T00:30:00Z", now: "2026-10-24T01:00:00Z", expected: "2026-10-25T01:30:00Z"),
    ]

    @Test func theTableHasEveryRow() {
        #expect(Self.vectors.count == 27)
    }

    @Test(arguments: NextDueCalculatorTests.vectors)
    func matchesTheServerVector(_ vector: RecurrenceVector) throws {
        let next = try #require(NextDueCalculator.nextDueDate(
            after: RecurrenceVector.instant(vector.dueAt), rule: vector.rule, now: RecurrenceVector.instant(vector.now)
        ))
        #expect(RecurrenceVector.utc(next) == vector.expected)
    }

    @Test(arguments: NextDueCalculatorTests.dstVectors)
    func readsSkippedAndRepeatedLocalTimesLikePostgreSQL(_ vector: RecurrenceVector) throws {
        let next = try #require(NextDueCalculator.nextDueDate(
            after: RecurrenceVector.instant(vector.dueAt), rule: vector.rule, now: RecurrenceVector.instant(vector.now)
        ))
        #expect(RecurrenceVector.utc(next) == vector.expected)
    }

    /// The other side of the DST changes: the first local times after the change and the last ones before it.
    @Test func localTimesAroundTheDSTChangesOfParis() throws {
        let paris = try #require(TimeZone(identifier: "Europe/Paris"))
        func instant(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int) -> String {
            let dayNumber = CivilDate(year: year, month: month, day: day).dayNumber
            let time = TimeInterval(hour * 3600 + minute * 60)
            return RecurrenceVector.utc(NextDueCalculator.instant(day: dayNumber, time: time, in: paris))
        }
        // Spring forward, 2026-03-29 at 01:00Z (02:00 CET → 03:00 CEST).
        #expect(instant(2026, 3, 29, 1, 59) == "2026-03-29T00:59:00Z")
        #expect(instant(2026, 3, 29, 2, 0) == "2026-03-29T01:00:00Z")
        #expect(instant(2026, 3, 29, 3, 0) == "2026-03-29T01:00:00Z")
        #expect(instant(2026, 3, 29, 3, 30) == "2026-03-29T01:30:00Z")
        // Fall back, 2026-10-25 at 01:00Z (03:00 CEST → 02:00 CET): 02:00–02:59 happen twice.
        #expect(instant(2026, 10, 25, 1, 59) == "2026-10-24T23:59:00Z")
        #expect(instant(2026, 10, 25, 2, 0) == "2026-10-25T01:00:00Z")
        #expect(instant(2026, 10, 25, 2, 59) == "2026-10-25T01:59:00Z")
        #expect(instant(2026, 10, 25, 3, 0) == "2026-10-25T02:00:00Z")
        // An ordinary day.
        #expect(instant(2026, 9, 24, 20, 0) == "2026-09-24T18:00:00Z")
    }

    @Test func anUnknownTimeZoneGivesNoDate() {
        let unknown = rule(.daily, tz: "Mars/Olympus_Mons")
        let date = RecurrenceVector.instant("2026-09-24T18:00:00Z")
        #expect(NextDueCalculator.nextDueDate(after: date, rule: unknown, now: date) == nil)
        #expect(NextDueCalculator.upcomingDueDates(after: date, rule: unknown, now: date, count: 3).isEmpty)
    }

    /// The month day of a new rule is the local day of the due date, not its UTC day (vector 24).
    @Test func aNewMonthlyRuleUsesTheLocalDay() throws {
        let tokyo = rule(.monthly, tz: "Asia/Tokyo")
        let dueAt = RecurrenceVector.instant("2026-01-30T15:30:00Z") // January 31, 00:30 in Tokyo
        let dates = NextDueCalculator.upcomingDueDates(after: dueAt, rule: tokyo, now: dueAt, count: 3)
        #expect(dates.map(RecurrenceVector.utc) == ["2026-02-27T15:30:00Z", "2026-03-30T15:30:00Z", "2026-04-29T15:30:00Z"])
    }

    // MARK: - Steps

    @Test func civilDatesRoundTrip() {
        #expect(CivilDate(year: 1970, month: 1, day: 1).dayNumber == 0)
        #expect(CivilDate(dayNumber: 0) == CivilDate(year: 1970, month: 1, day: 1))
        #expect(CivilDate(year: 2000, month: 3, day: 1).dayNumber == 11_017)
        #expect(CivilDate(dayNumber: -1) == CivilDate(year: 1969, month: 12, day: 31))
        for day in stride(from: -800_000, through: 3_000_000, by: 997) {
            #expect(CivilDate(dayNumber: CivilDate(dayNumber: day).dayNumber).dayNumber == CivilDate(dayNumber: day).dayNumber)
            #expect(CivilDate(dayNumber: day).dayNumber == day)
        }
        #expect(CivilDate.daysInMonth(year: 2028, month: 2) == 29)
        #expect(CivilDate.daysInMonth(year: 2100, month: 2) == 28)
        #expect(CivilDate.daysInMonth(year: 2000, month: 2) == 29)
    }

    @Test func isoWeekdays() {
        #expect(NextDueCalculator.isoWeekday(0) == 4) // 1970-01-01, a Thursday
        #expect(NextDueCalculator.isoWeekday(CivilDate(year: 2026, month: 9, day: 21).dayNumber) == 1)
        #expect(NextDueCalculator.isoWeekday(CivilDate(year: 2026, month: 9, day: 27).dayNumber) == 7)
        #expect(NextDueCalculator.isoWeekday(-1) == 3)
    }

    // MARK: - Previews

    @Test func upcomingDatesOfAWeekdayRule() {
        let mwf = rule(.weekly, weekdays: [1, 3, 5])
        let dueAt = RecurrenceVector.instant("2026-09-23T16:00:00Z") // Wednesday 18:00 CEST
        let dates = NextDueCalculator.upcomingDueDates(after: dueAt, rule: mwf, now: dueAt, count: 4)
        #expect(dates.map(RecurrenceVector.utc) == [
            "2026-09-25T16:00:00Z", "2026-09-28T16:00:00Z", "2026-09-30T16:00:00Z", "2026-10-02T16:00:00Z",
        ])
    }

    /// A « 31st » series: the month day stays 31 across the whole preview, like the stored `repeat_month_day`.
    @Test func upcomingMonthlyDatesDoNotDrift() {
        let monthly = rule(.monthly)
        let dueAt = RecurrenceVector.instant("2026-01-31T17:00:00Z")
        let dates = NextDueCalculator.upcomingDueDates(after: dueAt, rule: monthly, now: dueAt, count: 4)
        #expect(dates.map(RecurrenceVector.utc) == [
            "2026-02-28T17:00:00Z", "2026-03-31T16:00:00Z", "2026-04-30T16:00:00Z", "2026-05-31T16:00:00Z",
        ])
    }

    /// The first date is the occurrence created by a completion at `now` (missed slots skipped).
    @Test func upcomingDatesStartAfterNow() {
        let daily = rule(.daily)
        let dueAt = RecurrenceVector.instant("2026-09-20T06:00:00Z")
        let now = RecurrenceVector.instant("2026-09-24T12:00:00Z")
        let dates = NextDueCalculator.upcomingDueDates(after: dueAt, rule: daily, now: now, count: 2)
        #expect(dates.map(RecurrenceVector.utc) == ["2026-09-25T06:00:00Z", "2026-09-26T06:00:00Z"])
        #expect(NextDueCalculator.upcomingDueDates(after: dueAt, rule: daily, now: now, count: 0).isEmpty)
        #expect(NextDueCalculator.upcomingDueDates(after: dueAt, rule: daily, now: now, count: -1).isEmpty)
    }

    /// Like the server's successive spawns, each date keeps the local time of the previous one: a time skipped by
    /// the spring change (02:30 → 03:30 CEST) stays 03:30 afterwards.
    @Test func upcomingDatesChainLikeSuccessiveOccurrences() {
        let daily = rule(.daily)
        let dueAt = RecurrenceVector.instant("2026-03-28T01:30:00Z") // 02:30 CET
        let dates = NextDueCalculator.upcomingDueDates(after: dueAt, rule: daily, now: dueAt, count: 2)
        #expect(dates.map(RecurrenceVector.utc) == ["2026-03-29T01:30:00Z", "2026-03-30T01:30:00Z"])
    }

    /// An invalid rule never loops forever: the step budget ends it.
    @Test func aZeroIntervalStopsAfterTheStepBudget() throws {
        let broken = rule(.daily, interval: 0)
        let dueAt = RecurrenceVector.instant("2026-09-24T18:00:00Z")
        let next = try #require(NextDueCalculator.nextDueDate(after: dueAt, rule: broken, now: dueAt))
        #expect(next == dueAt)
    }
}

@Suite struct RotationHandoverTests {
    static let m1 = UUID(uuidString: "00000000-0000-0000-0000-0000000000D1")!
    static let m2 = UUID(uuidString: "00000000-0000-0000-0000-0000000000D2")!
    static let m3 = UUID(uuidString: "00000000-0000-0000-0000-0000000000D3")!
    static let m4 = UUID(uuidString: "00000000-0000-0000-0000-0000000000D4")!
    static let m5 = UUID(uuidString: "00000000-0000-0000-0000-0000000000D5")!

    private func handover(_ rotation: [UUID], turn: UUID?, members: Set<UUID>) -> RotationHandover {
        RotationHandover(after: rotation, turnUserId: turn, isMember: { members.contains($0) })
    }

    @Test func theTurnGoesToTheNextOneAndWrapsAround() {
        let rotation = [Self.m1, Self.m2, Self.m3]
        let all: Set = [Self.m1, Self.m2, Self.m3]
        #expect(handover(rotation, turn: Self.m1, members: all)
            == RotationHandover(rotation: rotation, turnUserId: Self.m2, assigneeId: Self.m2))
        #expect(handover(rotation, turn: Self.m2, members: all).turnUserId == Self.m3)
        #expect(handover(rotation, turn: Self.m3, members: all).turnUserId == Self.m1)
    }

    /// pgTAP `14_v2_spawn_rotation`: m4 left, skipped and removed from the new rotation.
    @Test func departedMembersAreSkippedAndDropped() {
        let result = handover([Self.m1, Self.m4, Self.m2, Self.m3], turn: Self.m1, members: [Self.m1, Self.m2, Self.m3])
        #expect(result == RotationHandover(rotation: [Self.m1, Self.m2, Self.m3], turnUserId: Self.m2, assigneeId: Self.m2))
    }

    /// The previous turn holder left: the turn goes on from their position in the original list.
    @Test func aDepartedTurnHolderKeepsTheirPosition() {
        let result = handover([Self.m3, Self.m5, Self.m1], turn: Self.m5, members: [Self.m1, Self.m3])
        #expect(result == RotationHandover(rotation: [Self.m3, Self.m1], turnUserId: Self.m1, assigneeId: Self.m1))
    }

    /// No turn holder (a deleted account) or one that is not listed: the first member of the cleaned list.
    @Test func withoutAListedTurnHolderTheFirstMemberStarts() {
        let gone = UUID()
        #expect(handover([gone, Self.m2, Self.m3], turn: nil, members: [Self.m2, Self.m3])
            == RotationHandover(rotation: [Self.m2, Self.m3], turnUserId: Self.m2, assigneeId: Self.m2))
        #expect(handover([Self.m1, Self.m2], turn: Self.m5, members: [Self.m1, Self.m2]).turnUserId == Self.m1)
    }

    /// The turn handover when the turn holder of a pending occurrence stops being a member (pgTAP
    /// `17_v2_turn_handover_signals`): computed from the departed user's position; the stored rotation is kept.
    @Test func turnHandoverWhenTheTurnHolderLeaves() {
        let (x1, x2, x3, x4) = (Self.m1, Self.m2, Self.m3, Self.m4)
        // x2, the turn holder, leaves: x3's turn.
        let left = handover([x1, x2, x3], turn: x2, members: [x1, x3])
        #expect(left.turnUserId == x3 && left.assigneeId == x3 && !left.rotation.isEmpty)
        // x4, the turn holder, is removed; x1 left earlier: the turn wraps around and skips x1.
        #expect(handover([x1, x2, x3, x4], turn: x4, members: [x2, x3]).turnUserId == x2)
        // One member of the rotation left: the rotation is dropped, x2 is the assignee.
        #expect(handover([x1, x2], turn: x1, members: [x2]) == RotationHandover(rotation: [], turnUserId: nil, assigneeId: x2))
        // Nobody left: no rotation, no assignee.
        #expect(handover([x1, x2], turn: x1, members: []) == RotationHandover(rotation: [], turnUserId: nil, assigneeId: nil))
        // Account deletion with the turn already NULL: the handover starts from the departed user (x2).
        #expect(handover([x1, x2, x3], turn: x2, members: [x1, x3]).turnUserId == x3)
    }

    /// Fewer than 2 members left: no rotation nor turn; the one member left (if any) is the assignee.
    @Test func aRotationOfFewerThanTwoMembersIsDropped() {
        #expect(handover([Self.m1, Self.m4], turn: Self.m1, members: [Self.m1])
            == RotationHandover(rotation: [], turnUserId: nil, assigneeId: Self.m1))
        #expect(handover([Self.m2, Self.m3], turn: Self.m2, members: [])
            == RotationHandover(rotation: [], turnUserId: nil, assigneeId: nil))
        #expect(handover([], turn: nil, members: [Self.m1]) == RotationHandover(rotation: [], turnUserId: nil, assigneeId: nil))
    }
}
