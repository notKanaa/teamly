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
    /// « Faire les courses » created then two items checked, and this week's completions; v3: Inès's absence, the two
    /// comments and the photo.
    @Test(arguments: ShowcaseTests.seedTimes)
    func activityFeedOfTheLastThreeDays(now: Date) async throws {
        let services = Self.showcase(at: now).services
        let feed = try await services.groups.activity(groupId: Self.lilas)
        let threeDaysAgo = now.addingTimeInterval(-3 * 86_400)
        #expect((14...15).contains(feed.count))
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
                kept.commentCount = 0
                kept.photos = []
                #expect(kept == task, "\(task.title)")
            }
            let beforeGroups = try await populated.groups.myGroups()
            let afterGroups = try await showcase.groups.myGroups()
            #expect(afterGroups == beforeGroups)
            let members = try await showcase.groups.members(groupId: groupId).map { member in
                var copy = member
                copy.user.awayFrom = nil
                copy.user.awayUntil = nil
                return copy
            }
            #expect(try await members == populated.groups.members(groupId: groupId))
        }
        #expect(try await showcase.profiles.myProfile() == populated.profiles.myProfile())
        let events = try await showcase.tasks.assignments(since: .distantPast)
        #expect(events == (try await populated.tasks.assignments(since: .distantPast)), "no new assignment by others for Camille")
    }

    // MARK: - v3 (docs/CONTRACTS-V3.md)

    /// Inès is away all next week, Monday to Sunday, announced in the feed; the badge reads « Absent·e du … ».
    @Test(arguments: ShowcaseTests.seedTimes)
    func inesIsAwayNextWeek(now: Date) async throws {
        let services = Self.showcase(at: now).services
        let ines = try #require(try await services.groups.members(groupId: Self.lilas).first { $0.user.id == DemoData.ines.id })
        let range = DemoData.Showcase.inesAway(now: now)
        #expect(ines.user.awayRange == range)
        #expect(range.lowerBound.isoWeekday == 1 && range.upperBound.isoWeekday == 7)
        let today = LocalDate(now, calendar: Self.calendar)
        #expect(range.lowerBound > today && today.days(to: range.lowerBound) <= 7)
        let badge = try #require(AwayText.badge(for: ines.user, today: today))
        #expect(badge.hasPrefix("Absent\u{00B7}e du "))
        let away = try await services.groups.activity(groupId: Self.lilas).filter { $0.kind == .memberAway }
        #expect(away.count == 1)
        #expect(away.first?.actorId == DemoData.ines.id && away.first?.subjectId == DemoData.ines.id)
        #expect(away.first?.startsOn == range.lowerBound && away.first?.endsOn == range.upperBound)
        // Nothing to hand over: none of Inès's turns falls next week.
        let tasks = try await services.tasks.tasks(groupId: Self.lilas, includeOldDone: false)
        #expect(!tasks.contains { $0.turnUserId == DemoData.ines.id && $0.status != .done })
    }

    /// Lucas proposed his turn of « Ranger le matériel » to Camille; she can accept it.
    @Test func pendingSwapProposedToCamille() async throws {
        let now = Self.paris(9, 23, 10)
        let environment = Self.showcase(at: now)
        let services = environment.services
        let pending = try await services.tasks.pendingTurnSwaps()
        #expect(pending.map(\.id) == [DemoData.Showcase.pendingSwapId])
        let swap = try #require(pending.first)
        #expect(swap.fromUserId == DemoData.lucas.id && swap.toUserId == DemoData.camille.id && swap.isPending)
        #expect(swap.groupId == DemoData.sportGroupId && swap.taskId == DemoData.Showcase.materielTaskId)
        let task = try await services.tasks.task(id: swap.taskId)
        #expect(task.title == DemoData.Showcase.materielTitle)
        #expect(task.turnUserId == DemoData.lucas.id && task.assigneeIds == [DemoData.lucas.id])
        #expect(task.rotation == DemoData.Showcase.materielRotation && task.seriesId == task.id)
        #expect(try #require(task.dueAt) > now)
        #expect(TaskPermissions.canRespond(to: swap, userId: DemoData.camille.id))
        let accepted = try await services.tasks.respondToTurnSwap(swapId: swap.id, accept: true)
        #expect(accepted.status == .accepted)
        #expect(try await services.tasks.task(id: task.id).turnUserId == DemoData.camille.id)
    }

    /// Reactions on two completions of this week, targeting their actors.
    @Test(arguments: ShowcaseTests.seedTimes)
    func reactionsOnTwoEvents(now: Date) async throws {
        let services = Self.showcase(at: now).services
        let feed = try await services.groups.activity(groupId: Self.lilas)
        let reacted = feed.filter { !$0.reactions.isEmpty }
        #expect(reacted.count == 2)
        let plantes = try #require(reacted.first { $0.taskTitle == "Arroser les plantes" })
        #expect(plantes.actorId == DemoData.ines.id)
        #expect(plantes.reactionSummaries(currentUserId: DemoData.camille.id).map(\.text) == ["\u{1F44F} 2", "\u{1F525} 1"])
        #expect(plantes.reactionSummaries(currentUserId: DemoData.camille.id).first?.includesMe == true)
        let frigo = try #require(reacted.first { $0.taskTitle == "Nettoyer le frigo" })
        #expect(frigo.actorId == DemoData.camille.id)
        #expect(Set(frigo.reactions.map(\.emoji)) == [.muscle, .heart])
        // Camille can take her 👏 back.
        #expect(try await !services.groups.toggleReaction(activityId: plantes.id, emoji: .clap))
    }

    /// Two comments mentioning Camille on « Faire les courses », oldest first, with their events.
    @Test func coursesComments() async throws {
        let now = Self.paris(9, 23, 10)
        let services = Self.showcase(at: now).services
        let comments = try await services.tasks.comments(taskId: DemoData.TaskIDs.faireCourses)
        #expect(comments.map(\.id) == DemoData.Showcase.coursesComments.map(\.id))
        #expect(comments.map(\.authorId) == [DemoData.lucas.id, DemoData.ines.id])
        #expect(comments.allSatisfy { $0.mentions == [DemoData.camille.id] && $0.createdAt < now })
        #expect(try await services.tasks.task(id: DemoData.TaskIDs.faireCourses).commentCount == 2)
        let events = try await services.groups.activity(groupId: Self.lilas).filter { $0.kind == .commentAdded }
        #expect(events.map(\.actorId) == [DemoData.ines.id, DemoData.lucas.id])
        #expect(events.map(\.createdAt) == comments.reversed().map(\.createdAt))
        #expect(events.allSatisfy { $0.taskId == DemoData.TaskIDs.faireCourses })
    }

    /// One photo on « Nettoyer le frigo » (done by Camille this week), shown through a `data:` URL.
    @Test(arguments: ShowcaseTests.seedTimes)
    func photoOnADoneTask(now: Date) async throws {
        let environment = Self.showcase(at: now)
        let services = environment.services
        let task = try await services.tasks.task(id: DemoData.Showcase.photoTaskId)
        #expect(task.status == .done && task.title == "Nettoyer le frigo")
        let photo = try #require(task.photos.first)
        #expect(task.photos.count == 1)
        #expect(photo.id == DemoData.Showcase.photoId && photo.uploadedBy == DemoData.camille.id)
        #expect(InputValidation.isPhotoPath(photo.path, groupId: Self.lilas, taskId: task.id))
        #expect(photo.createdAt == task.completedAt)
        #expect(InputValidation.isJPEG(DemoData.Showcase.photoJPEG) && DemoData.Showcase.photoJPEG.count == 772)
        #expect(environment.backend.photoObjectData(path: photo.path) == DemoData.Showcase.photoJPEG)
        let url = try await services.tasks.photoURL(photo)
        #expect(url.absoluteString == "data:image/jpeg;base64,\(DemoData.Showcase.photoJPEG.base64EncodedString())")
        let events = try await services.groups.activity(groupId: Self.lilas).filter { $0.kind == .photoAdded }
        #expect(events.map(\.taskId) == [task.id])
    }
}
