import Foundation
import TeamTasksCore
import TeamTasksMocks
import Testing

/// v3 server rules that need the mock clock or a look inside the mock (docs/CONTRACTS-V3.md): the 20-hour window of the
/// nudges, the clock rule of the absences, the retention of the reactions, the cascades of an account deletion, the
/// stored photo bytes and the Realtime visibility. The backend-agnostic rules are contract scenarios.
@Suite struct V3BackendTests {
    let clock = MockClock(Date(timeIntervalSince1970: 1_790_150_400)) // 2026-09-23T08:00:00Z
    let lilas = DemoData.lilasGroupId

    static func utc(_ text: String) -> Date {
        ISO8601DateFormatter().date(from: text) ?? .distantPast
    }

    /// `nudge_rate_limited` while an earlier nudge of the caller on the task is at most 20 hours old (inclusive, like the
    /// v1 windows); a second later the window is over.
    @Test func nudgeWindowIsTwentyHours() async throws {
        let backend = InMemoryBackend.demo(now: clock.provider)
        let ines = backend.services(for: DemoData.ines.id)
        let camille = backend.services(for: DemoData.camille.id)
        let courses = DemoData.TaskIDs.faireCourses // Lucas and Camille
        #expect(try await ines.tasks.nudge(taskId: courses) == 2)
        clock.advance(by: 20 * 3600)
        await #expect(throws: AppError.nudgeRateLimited) { try await ines.tasks.nudge(taskId: courses) }
        #expect(try await camille.tasks.nudge(taskId: courses) == 1, "another caller has a window of their own")
        clock.advance(by: 1)
        #expect(try await ines.tasks.nudge(taskId: courses) == 2, "20 hours and a second later")
        let feed = try await camille.groups.activity(groupId: lilas).filter { $0.kind == .taskNudged }
        #expect(feed.count == 5)
    }

    /// `until >= current_date - 1`, the server's date being the UTC date of its clock.
    @Test func awayEndsNoEarlierThanYesterday() async throws {
        clock.set(Self.utc("2026-09-27T23:30:00Z"))
        let backend = InMemoryBackend.demo(now: clock.provider)
        let ines = backend.services(for: DemoData.ines.id)
        let yesterday = LocalDate(year: 2026, month: 9, day: 26)
        let profile = try await ines.profiles.setAway(from: yesterday.adding(days: -3), until: yesterday, announce: false)
        #expect(profile.awayUntil == yesterday)
        await #expect(throws: AppError.invalidAway) {
            try await ines.profiles.setAway(from: yesterday.adding(days: -3), until: yesterday.adding(days: -1), announce: false)
        }
        #expect(try await ines.profiles.myProfile().awayRange == yesterday.adding(days: -3)...yesterday, "unchanged")
    }

    /// The reactions of an event deleted by the 90-day retention go with it.
    @Test func expiredEventsTakeTheirReactions() async throws {
        let backend = InMemoryBackend.demo(now: clock.provider)
        let camille = backend.services(for: DemoData.camille.id)
        let lucas = backend.services(for: DemoData.lucas.id)
        let task = try await camille.tasks.create(groupId: lilas, draft: TaskDraft(title: "Ancienne"))
        let event = try #require(try await lucas.groups.activity(groupId: lilas).first)
        #expect(try await lucas.groups.toggleReaction(activityId: event.id, emoji: .clap))
        clock.advance(by: 91 * 86_400)
        _ = try await camille.tasks.create(groupId: lilas, draft: TaskDraft(title: "Nouvelle"))
        let feed = try await lucas.groups.activity(groupId: lilas)
        #expect(!feed.contains { $0.id == event.id })
        await #expect(throws: AppError.notFound) { try await lucas.groups.toggleReaction(activityId: event.id, emoji: .clap) }
        _ = task
    }

    /// Account deletion: the user's nudges, swaps and reactions go; their comments and photos stay without author.
    @Test func accountDeletionCascades() async throws {
        let backend = InMemoryBackend.showcase(now: clock.provider)
        let camille = backend.services(for: DemoData.camille.id)
        let lucas = backend.services(for: DemoData.lucas.id)
        let courses = DemoData.TaskIDs.faireCourses
        _ = try await camille.tasks.nudge(taskId: courses)
        let photo = try await lucas.tasks.uploadPhoto(taskId: courses, jpegData: DemoData.Showcase.photoJPEG)
        try await lucas.auth.deleteAccount()

        let comments = try await camille.tasks.comments(taskId: courses)
        #expect(comments.first { $0.id == DemoData.Showcase.coursesComments[0].id }?.authorId == nil, "Lucas's comment stays")
        let task = try await camille.tasks.task(id: courses)
        #expect(task.photos.first { $0.id == photo.id }?.uploadedBy == nil, "Lucas's photo stays")
        #expect(backend.photoObjectData(path: photo.path) != nil)
        #expect(try await camille.tasks.pendingTurnSwaps().isEmpty, "Lucas's proposal is gone")
        let reacted = try await camille.groups.activity(groupId: lilas).flatMap(\.reactions)
        #expect(!reacted.contains { $0.userId == DemoData.lucas.id }, "his reactions are gone")
        #expect(reacted.contains { $0.userId == DemoData.camille.id })
    }

    /// The bytes are kept in memory; deleting the photo deletes them; deleting the task leaves the object (an orphan).
    @Test func photoObjects() async throws {
        let backend = InMemoryBackend.demo(now: clock.provider)
        let camille = backend.services(for: DemoData.camille.id)
        let poubelles = DemoData.TaskIDs.sortirPoubelles
        let first = try await camille.tasks.uploadPhoto(taskId: poubelles, jpegData: DemoData.Showcase.photoJPEG)
        let second = try await camille.tasks.uploadPhoto(taskId: poubelles, jpegData: DemoData.Showcase.photoJPEG)
        #expect(first.path != second.path)
        #expect(backend.photoObjectData(path: first.path) == DemoData.Showcase.photoJPEG)
        try await camille.tasks.deletePhoto(first)
        #expect(backend.photoObjectData(path: first.path) == nil)
        try await camille.tasks.delete(taskId: poubelles)
        #expect(backend.photoObjectData(path: second.path) != nil, "objects of deleted tasks are left behind")
        await #expect(throws: AppError.invalidPhoto) {
            try await camille.tasks.uploadPhoto(taskId: DemoData.TaskIDs.faireCourses, jpegData: Data(count: Limits.photoBytesMax + 1))
        }
    }

    /// Realtime: the v3 rows reach only their recipients, as far as RLS lets them; one event per row.
    @Test func socialEventsReachTheirRecipients() async throws {
        let backend = InMemoryBackend.demo(now: clock.provider)
        let camille = backend.services(for: DemoData.camille.id)
        let lucas = backend.services(for: DemoData.lucas.id)
        let ines = backend.services(for: DemoData.ines.id)
        var lucasEvents = lucas.realtime.events(userId: DemoData.lucas.id, groupIds: [lilas]).makeAsyncIterator()
        #expect(await lucasEvents.next() == .connected)

        // Ines nudges Lucas and Camille: Lucas gets his nudge only.
        _ = try await ines.tasks.nudge(taskId: DemoData.TaskIDs.faireCourses)
        #expect(await lucasEvents.next() == .groupActivity(groupId: lilas))
        guard case let .nudged(_, taskId, groupId, fromUserId)? = await lucasEvents.next() else {
            Issue.record("a nudge was expected")
            return
        }
        #expect(taskId == DemoData.TaskIDs.faireCourses && groupId == lilas && fromUserId == DemoData.ines.id)

        // A comment in the group: one event, after the group signal.
        let comment = try await camille.tasks.addComment(taskId: DemoData.TaskIDs.faireCourses, body: "Lait", mentions: [DemoData.lucas.id])
        #expect(await lucasEvents.next() == .groupActivity(groupId: lilas))
        #expect(await lucasEvents.next() == .commentAdded(
            commentId: comment.id, taskId: comment.taskId, groupId: lilas, authorId: DemoData.camille.id, mentions: [DemoData.lucas.id]
        ))

        // Lucas leaves: he no longer receives the group's comments (RLS).
        try await lucas.groups.leave(groupId: lilas)
        #expect(await lucasEvents.next() == .membershipsChanged)
        _ = try await camille.tasks.addComment(taskId: DemoData.TaskIDs.faireCourses, body: "Encore", mentions: [])
        _ = try await lucas.profiles.updateDisplayName("Lucas B.") // sentinel: his own profile
        #expect(await lucasEvents.next() == .membershipsChanged, "no comment of a group he left before the sentinel")
    }

    /// The repayment skips an author who left the group: the turn stays with the member it falls to.
    @Test func noRepaymentToAFormerMember() async throws {
        let backend = InMemoryBackend.demo(now: clock.provider)
        let camille = backend.services(for: DemoData.camille.id)
        let lucas = backend.services(for: DemoData.lucas.id)
        let ines = backend.services(for: DemoData.ines.id)
        let rule = RecurrenceRule(frequency: .weekly, timeZoneId: "Europe/Paris")
        let task = try await camille.tasks.create(groupId: lilas, draft: TaskDraft(
            title: "Tour", dueAt: Self.utc("2041-03-04T07:00:00Z"), recurrence: rule,
            rotation: [DemoData.ines.id, DemoData.lucas.id, DemoData.camille.id]
        ))
        let swap = try await ines.tasks.requestTurnSwap(taskId: task.id, to: DemoData.lucas.id)
        _ = try await lucas.tasks.respondToTurnSwap(swapId: swap.id, accept: true)
        let firstDone = try await lucas.tasks.setStatus(taskId: task.id, status: .done)
        let second = try await lucas.tasks.task(id: try #require(firstDone.nextOccurrenceId))
        #expect(second.turnUserId == DemoData.camille.id)
        try await ines.groups.leave(groupId: lilas)
        let secondDone = try await camille.tasks.setStatus(taskId: second.id, status: .done)
        let third = try await camille.tasks.task(id: try #require(secondDone.nextOccurrenceId))
        #expect(third.turnUserId == DemoData.lucas.id, "Lucas's turn: Inès, who left, is not repaid")
        #expect(third.rotation == [DemoData.lucas.id, DemoData.camille.id])
        #expect(try await camille.tasks.turnSwaps(taskId: task.id).first?.repaidAt == nil)
    }

    @Test func myCompletionsOfTheDemoUser() async throws {
        let backend = InMemoryBackend.showcase(now: clock.provider)
        let camille = backend.services(for: DemoData.camille.id)
        let completions = try await camille.tasks.myCompletions(since: MyStats.readStart(now: clock.peek(), calendar: DemoData.calendar))
        #expect(!completions.isEmpty)
        #expect(completions.allSatisfy { $0.completedBy == DemoData.camille.id && $0.groupId == lilas })
        let stats = MyStats(completions: completions, now: clock.peek(), calendar: DemoData.calendar)
        #expect(stats.tasksThisMonth >= 2)
        #expect(stats.weekStreak >= 1)
    }
}
