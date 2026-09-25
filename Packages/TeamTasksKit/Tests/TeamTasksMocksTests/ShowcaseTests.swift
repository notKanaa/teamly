import Foundation
import TeamTasksCore
import TeamTasksMocks
import Testing

/// `MockScenario.showcase` (the v2 screenshots): `populated` plus v2 content that the server rules could have produced
/// (`DemoData.Showcase`), whatever the seed time.
@Suite struct ShowcaseTests {
    static let calendar = DemoData.calendar
    static let lilas = DemoData.lilasGroupId

    static func paris(_ month: Int, _ day: Int, _ hour: Int, _ minute: Int = 0, year: Int = 2026) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    /// Seed times on every weekday, right after and right before a week boundary, and around the DST changes.
    static let seedTimes: [Date] = [
        paris(9, 21, 0), paris(9, 21, 0, 30), paris(9, 21, 10), paris(9, 22, 8), paris(9, 23, 10), paris(9, 24, 1),
        paris(9, 24, 23, 59), paris(9, 25, 12), paris(9, 26, 18), paris(9, 27, 23, 59),
        paris(10, 25, 12), paris(10, 26, 0, 10), paris(3, 29, 12), paris(3, 30, 9), paris(1, 4, 20, year: 2027),
    ]

    static func showcase(at now: Date) -> MockEnvironment {
        MockEnvironment.make(scenario: .showcase, now: { now })
    }

    /// The weekly recap: Inès first (3), Camille second (2), Lucas third (1), and Inès the sole leader for 3 weeks.
    @Test(arguments: ShowcaseTests.seedTimes)
    func weeklyRecapHasThePodiumAndTheStreak(now: Date) async throws {
        let services = Self.showcase(at: now).services
        let members = try await services.groups.members(groupId: Self.lilas)
        let completions = try await services.tasks.completions(
            groupId: Self.lilas, since: WeeklyRecap.readStart(now: now, calendar: Self.calendar)
        )
        let recap = WeeklyRecap(completions: completions, members: members, now: now, calendar: Self.calendar)
        #expect(recap.podium.map(\.user.id) == DemoData.Showcase.podium.map(\.user.id))
        #expect(recap.podium.map(\.count) == DemoData.Showcase.podium.map(\.count))
        #expect(recap.podium.map(\.user.id) == [DemoData.ines.id, DemoData.camille.id, DemoData.lucas.id])
        #expect(recap.streak?.user.id == DemoData.ines.id)
        #expect(recap.streak?.weeks == DemoData.Showcase.streakWeeks)
        #expect(recap.total >= 6)

        // Every done task was completed in the past, after its creation, by the member it was assigned to.
        let tasks = try await services.tasks.tasks(groupId: Self.lilas, includeOldDone: true)
        for task in tasks where task.status == .done {
            let completedAt = try #require(task.completedAt)
            #expect(completedAt <= now && completedAt > task.createdAt, "\(task.title)")
            #expect(task.updatedAt == completedAt || task.completedBy == nil, "\(task.title)")
        }
    }

    /// « Sortir les poubelles »: a weekly series « à tour de rôle » (Inès, Camille, Lucas) whose current occurrence is
    /// Camille's turn, spawned 3 days ago when Camille completed Inès's turn.
    @Test(arguments: ShowcaseTests.seedTimes)
    func poubellesRotatesAndItIsCamillesTurn(now: Date) async throws {
        let services = Self.showcase(at: now).services
        let current = try await services.tasks.task(id: DemoData.TaskIDs.sortirPoubelles)
        let previous = try await services.tasks.task(id: DemoData.Showcase.previousPoubellesId)
        #expect(current.recurrence == DemoData.Showcase.poubellesRule)
        #expect(current.rotation == DemoData.Showcase.poubellesRotation)
        #expect(current.turnUserId == DemoData.camille.id)
        #expect(current.assigneeIds == [DemoData.camille.id])
        #expect(current.seriesId == previous.id)
        #expect(previous.seriesId == previous.id)
        #expect(previous.nextOccurrenceId == current.id)
        #expect(previous.status == .done && previous.completedBy == DemoData.camille.id)
        #expect(previous.turnUserId == DemoData.ines.id)
        #expect(previous.createdBy == current.createdBy, "the series creator")

        // What the server would have done when Camille completed the previous occurrence.
        let completedAt = try #require(previous.completedAt)
        let expectedDue = NextDueCalculator.nextDueDate(after: try #require(previous.dueAt), rule: DemoData.Showcase.poubellesRule, now: completedAt)
        #expect(current.dueAt == expectedDue)
        #expect(current.createdAt == completedAt)
        let handover = RotationHandover(after: previous.rotation, turnUserId: previous.turnUserId) { _ in true }
        #expect(handover.turnUserId == current.turnUserId)
        let mine = try await services.tasks.myTasks(includeDone: false)
        let item = try #require(mine.first { $0.id == current.id })
        #expect(item.myAssignedBy == DemoData.camille.id, "the completer took her own turn")
        #expect(item.myAssignedAt == completedAt)
        #expect(item.groupColor == .coral && item.groupEmoji == "🏠")
    }

    @Test func coursesChecklistIsHalfDone() async throws {
        let now = Self.paris(9, 23, 10)
        let services = Self.showcase(at: now).services
        let courses = try await services.tasks.task(id: DemoData.TaskIDs.faireCourses)
        #expect(courses.checklist.map(\.title) == DemoData.Showcase.coursesChecklist)
        #expect(courses.checklist.map(\.position) == [1, 2, 3, 4])
        #expect(courses.checklist.map(\.isDone) == [true, true, false, false])
        #expect(courses.checklist.map(\.doneBy) == [DemoData.lucas.id, DemoData.camille.id, nil, nil])
        for item in courses.checklist where item.isDone {
            let doneAt = try #require(item.doneAt)
            #expect(doneAt > courses.createdAt && doneAt <= now)
        }
        // Camille (an assignee) may keep checking items.
        let next = try await services.tasks.setChecklistItemDone(itemId: DemoData.Showcase.ChecklistIDs.lessive, done: true)
        #expect(next.isDone && next.doneBy == DemoData.camille.id)
    }

    /// The feed of the last 3 days, newest first: the previous « Sortir les poubelles » completed then Camille's turn,
    /// « Faire les courses » created then two items checked, and this week's completions.
    @Test(arguments: ShowcaseTests.seedTimes)
    func activityFeedOfTheLastThreeDays(now: Date) async throws {
        let services = Self.showcase(at: now).services
        let feed = try await services.groups.activity(groupId: Self.lilas)
        let threeDaysAgo = now.addingTimeInterval(-3 * 86_400)
        #expect((10...11).contains(feed.count))
        #expect(feed.map(\.id) == feed.map(\.id).sorted(by: >), "newest first")
        for (newer, older) in zip(feed, feed.dropFirst()) {
            #expect(newer.createdAt >= older.createdAt)
        }
        #expect(feed.allSatisfy { $0.createdAt >= threeDaysAgo && $0.createdAt <= now })
        let oldest = Array(feed.suffix(2).reversed())
        #expect(oldest.map(\.kind) == [.taskCompleted, .turnStarted])
        #expect(oldest.first?.taskId == DemoData.Showcase.previousPoubellesId)
        #expect(oldest.first?.actorId == DemoData.camille.id)
        #expect(oldest.last?.subjectId == DemoData.camille.id && oldest.last?.actorId == nil)
        #expect(oldest.last?.taskId == DemoData.TaskIDs.sortirPoubelles)
        let checks = feed.filter { $0.kind == .checklistItemDone }
        #expect(checks.map(\.itemTitle) == ["Pâtes", "Lait"])
        #expect(checks.map(\.actorId) == [DemoData.camille.id, DemoData.lucas.id])
        #expect(checks.allSatisfy { $0.taskTitle == "Faire les courses" })
        let created = feed.filter { $0.kind == .taskCreated }
        #expect(created.map(\.taskId) == [DemoData.TaskIDs.faireCourses])
        #expect(created.first?.actorId == DemoData.lucas.id)
        // Each completion event matches its done task.
        for event in feed where event.kind == .taskCompleted {
            let task = try await services.tasks.task(id: try #require(event.taskId))
            #expect(task.completedAt == event.createdAt && task.completedBy == event.actorId && task.title == event.taskTitle)
        }
        #expect(try await services.groups.activity(groupId: DemoData.sportGroupId).isEmpty)
    }

    /// The showcase only adds v2 content: every demo task keeps its v1 fields, and the demo accounts are unchanged.
    @Test func populatedRowsKeepTheirV1Fields() async throws {
        let now = Self.paris(9, 24, 23, 59)
        let populated = MockEnvironment.make(scenario: .populated, now: { now }).services
        let showcase = Self.showcase(at: now).services
        for groupId in [DemoData.lilasGroupId, DemoData.sportGroupId] {
            let before = try await populated.tasks.tasks(groupId: groupId, includeOldDone: true)
            let after = try await showcase.tasks.tasks(groupId: groupId, includeOldDone: true)
            for task in before {
                var kept = try #require(after.first { $0.id == task.id })
                kept.recurrence = nil
                kept.rotation = []
                kept.turnUserId = nil
                kept.seriesId = nil
                kept.checklist = []
                #expect(kept == task, "\(task.title)")
            }
            let beforeGroups = try await populated.groups.myGroups()
            let afterGroups = try await showcase.groups.myGroups()
            #expect(afterGroups == beforeGroups)
            #expect(try await showcase.groups.members(groupId: groupId) == populated.groups.members(groupId: groupId))
        }
        #expect(try await showcase.profiles.myProfile() == populated.profiles.myProfile())
        let events = try await showcase.tasks.assignments(since: .distantPast)
        #expect(events == (try await populated.tasks.assignments(since: .distantPast)), "no new assignment by others for Camille")
    }
}
