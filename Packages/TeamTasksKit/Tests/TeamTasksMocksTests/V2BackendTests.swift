import Foundation
import TeamTasksCore
import TeamTasksMocks
import Testing

/// v2 server rules that need the mock clock (docs/CONTRACTS-V2.md §6, §7, §9). The backend-agnostic rules are
/// contract scenarios (TeamTasksContract), run against the mocks by `ContractScenarioTests`.
@Suite struct V2BackendTests {
    let clock = MockClock(Date(timeIntervalSince1970: 1_790_150_400)) // 2026-09-23T08:00:00Z
    let lilas = DemoData.lilasGroupId

    static func utc(_ text: String) -> Date {
        ISO8601DateFormatter().date(from: text) ?? .distantPast
    }

    static func rule(
        _ frequency: RecurrenceRule.Frequency, weekdays: Set<Int>? = nil
    ) -> RecurrenceRule {
        RecurrenceRule(frequency: frequency, weekdays: weekdays, timeZoneId: "Europe/Paris")
    }

    /// Rows of the §6 table whose `now` matters (missed occurrences, a slot due exactly now, the 10 000 steps), and a
    /// DST change: name, rule, due date, completion time, next due date.
    static let clockVectors: [(String, RecurrenceRule, String, String, String)] = [
        ("1 daily", rule(.daily), "2026-09-24T18:00:00Z", "2026-09-24T19:00:00Z", "2026-09-25T18:00:00Z"),
        ("4 missed occurrences", rule(.daily), "2026-09-20T06:00:00Z", "2026-09-24T12:00:00Z", "2026-09-25T06:00:00Z"),
        ("5 a slot due exactly now", rule(.daily), "2026-09-22T06:00:00Z", "2026-09-24T06:00:00Z", "2026-09-25T06:00:00Z"),
        ("13 weekdays, missed", rule(.weekly, weekdays: [1, 3, 5]), "2026-09-14T16:00:00Z", "2026-09-24T12:00:00Z",
         "2026-09-25T16:00:00Z"),
        ("20 monthly, missed", rule(.monthly), "2026-05-15T07:00:00Z", "2026-09-24T12:00:00Z", "2026-10-15T07:00:00Z"),
        ("22 autumn DST", rule(.weekly), "2026-10-19T16:30:00Z", "2026-10-19T17:00:00Z", "2026-10-26T17:30:00Z"),
        ("26 10 000 steps", rule(.daily), "1990-01-01T08:00:00Z", "2026-09-24T12:00:00Z", "2017-05-19T07:00:00Z"),
    ]

    /// The mock spawns with its own clock as `now()`: the completion time.
    @Test(arguments: V2BackendTests.clockVectors)
    func spawnUsesTheBackendClock(_ name: String, rule: RecurrenceRule, due: String, now: String, expected: String) async throws {
        let backend = InMemoryBackend.demo(now: clock.provider)
        let camille = backend.services(for: DemoData.camille.id)
        let task = try await camille.tasks.create(
            groupId: lilas, draft: TaskDraft(title: "Vecteur \(name)", dueAt: Self.utc(due), recurrence: rule)
        )
        clock.set(Self.utc(now))
        let done = try await camille.tasks.setStatus(taskId: task.id, status: .done)
        #expect(done.completedAt == Self.utc(now))
        let next = try await camille.tasks.task(id: try #require(done.nextOccurrenceId))
        #expect(next.dueAt == Self.utc(expected), "vector \(name)")
        #expect(next.createdAt == Self.utc(now))
    }

    /// Retention (§7): writing an event of a group deletes that group's events older than 90 days (one exactly 90 days
    /// old is kept); reads delete nothing, other groups are untouched.
    @Test func activityRetentionKeepsNinetyDays() async throws {
        let backend = InMemoryBackend(now: clock.provider)
        let alice = try backend.createAccount(email: "alice@example.com", password: "motdepasse123", displayName: "Alice")
        let bob = try backend.createAccount(email: "bob@example.com", password: "motdepasse123", displayName: "Bob")
        let carol = try backend.createAccount(email: "carol@example.com", password: "motdepasse123", displayName: "Carol")
        let aliceServices = backend.services(for: alice.id)
        let group = try await aliceServices.groups.createGroup(name: "Coloc")
        let other = try await aliceServices.groups.createGroup(name: "Autre")
        let code = try await aliceServices.groups.inviteCode(groupId: group.id)
        let otherCode = try await aliceServices.groups.inviteCode(groupId: other.id)
        let start = clock.peek()
        _ = try await backend.services(for: bob.id).groups.join(code: code) // event 1 of `group`, at `start`
        _ = try await backend.services(for: carol.id).groups.join(code: otherCode) // event of `other`, at `start`
        clock.advance(by: 1)
        _ = try await backend.services(for: carol.id).groups.join(code: code) // event 2 of `group`, at start + 1 s

        let retention = TimeInterval(Limits.activityRetentionDays) * 86_400
        clock.set(start.addingTimeInterval(retention))
        _ = try await aliceServices.tasks.create(groupId: group.id, draft: TaskDraft(title: "Écrite à 90 jours"))
        var feed = try await aliceServices.groups.activity(groupId: group.id)
        #expect(feed.map(\.kind) == [.taskCreated, .memberJoined, .memberJoined], "an event exactly 90 days old is kept")

        clock.set(start.addingTimeInterval(retention + 1))
        feed = try await aliceServices.groups.activity(groupId: group.id)
        #expect(feed.count == 3, "reads delete nothing")
        _ = try await aliceServices.tasks.create(groupId: group.id, draft: TaskDraft(title: "Écrite après"))
        feed = try await aliceServices.groups.activity(groupId: group.id)
        #expect(feed.map(\.kind) == [.taskCreated, .taskCreated, .memberJoined], "the event 90 days and 1 second old is deleted")
        #expect(feed.last?.actorId == carol.id, "the event 1 second younger is kept")
        #expect(feed.map(\.id) == feed.map(\.id).sorted(by: >), "ids keep increasing")
        let otherFeed = try await aliceServices.groups.activity(groupId: other.id)
        #expect(otherFeed.count == 1, "other groups are untouched until one of their events is written")
    }

    /// Onboarding (§9): a new sign-up is dated by the backend's clock and not onboarded; `complete_onboarding()` sets
    /// `onboarded_at` once, at the call's `now()`.
    @Test func onboardingFollowsTheClock() async throws {
        let backend = InMemoryBackend(now: clock.provider)
        let device = backend.services(for: nil)
        let signUpTime = clock.peek()
        _ = try await device.auth.signUp(email: "nina@example.com", password: "motdepasse123", displayName: "Nina")
        let fresh = try await device.profiles.myProfile()
        #expect(fresh.createdAt == signUpTime)
        #expect(fresh.onboardedAt == nil)
        #expect(OnboardingPolicy.shouldShow(profile: fresh, now: signUpTime.addingTimeInterval(OnboardingPolicy.maxAccountAge - 1)))
        #expect(!OnboardingPolicy.shouldShow(profile: fresh, now: signUpTime.addingTimeInterval(OnboardingPolicy.maxAccountAge)))

        clock.advance(by: 3600)
        let completion = clock.peek()
        try await device.profiles.completeOnboarding()
        clock.advance(by: 3600)
        try await device.profiles.completeOnboarding()
        let done = try await device.profiles.myProfile()
        #expect(done.onboardedAt == completion, "set once, at the first call")
        #expect(done.createdAt == signUpTime)
    }

    /// A spawn is one transaction: the rotation's new turn holder receives the group's signal, then the assignment,
    /// with no assigner (Realtime delivers in commit order).
    @Test func spawnSignalsInCommitOrder() async throws {
        let backend = InMemoryBackend.demo(now: clock.provider)
        let camille = backend.services(for: DemoData.camille.id)
        let lucas = backend.services(for: DemoData.lucas.id)
        let task = try await camille.tasks.create(groupId: lilas, draft: TaskDraft(
            title: "Poubelles", dueAt: Self.utc("2041-03-04T07:00:00Z"), recurrence: Self.rule(.weekly),
            rotation: [DemoData.camille.id, DemoData.lucas.id, DemoData.ines.id]
        ))
        var events = lucas.realtime.events(userId: DemoData.lucas.id, groupIds: [lilas]).makeAsyncIterator()
        #expect(await events.next() == .connected)
        let done = try await camille.tasks.setStatus(taskId: task.id, status: .done)
        let nextId = try #require(done.nextOccurrenceId)
        #expect(await events.next() == .groupActivity(groupId: lilas))
        #expect(await events.next() == .assigned(taskId: nextId, groupId: lilas, assignedBy: nil))
    }

    /// The account deletion of a turn holder (§6, §7): `member_left` without actor nor subject, then `turn_started` for
    /// the pending occurrence. The references of a deleted account become NULL (`on delete set null`): the turn and the
    /// completer of a done occurrence, `done_by`, the events.
    @Test func accountDeletionHandsOverAndForgetsTheAccount() async throws {
        let backend = InMemoryBackend.demo(now: clock.provider)
        let camille = backend.services(for: DemoData.camille.id)
        let ines = backend.services(for: DemoData.ines.id)
        let rotation = [DemoData.ines.id, DemoData.lucas.id, DemoData.camille.id]
        let first = try await camille.tasks.create(groupId: lilas, draft: TaskDraft(
            title: "Poubelles", dueAt: Self.utc("2041-03-04T07:00:00Z"), recurrence: Self.rule(.weekly), rotation: rotation
        ))
        let item = try await ines.tasks.addChecklistItem(taskId: first.id, title: "Sac jaune")
        _ = try await ines.tasks.setChecklistItemDone(itemId: item.id, done: true)
        let done = try await ines.tasks.setStatus(taskId: first.id, status: .done)
        let next = try await camille.tasks.task(id: try #require(done.nextOccurrenceId))
        #expect(next.turnUserId == DemoData.lucas.id)
        try await backend.services(for: DemoData.lucas.id).auth.deleteAccount()

        let pending = try await camille.tasks.task(id: next.id)
        #expect(pending.turnUserId == DemoData.camille.id)
        #expect(pending.assigneeIds == [DemoData.camille.id])
        #expect(pending.rotation == rotation, "the deleted account stays listed until the next spawn")
        let feed = try await camille.groups.activity(groupId: lilas)
        #expect(feed.prefix(2).map(\.kind) == [.turnStarted, .memberLeft])
        #expect(feed[1].actorId == nil && feed[1].subjectId == nil)
        #expect(feed[0].subjectId == DemoData.camille.id && feed[0].taskId == next.id)

        // Inès deletes her account too: her done occurrence (her turn, her completion) and her check lose her id.
        try await ines.auth.deleteAccount()
        let completed = try await camille.tasks.task(id: first.id)
        #expect(completed.turnUserId == nil)
        #expect(completed.completedBy == nil)
        #expect(completed.status == .done)
        let kept = try #require(completed.checklist.first)
        #expect(kept.isDone && kept.doneAt != nil && kept.doneBy == nil, "the item stays done, anonymously")
        let events = try await camille.groups.activity(groupId: lilas)
        #expect(!events.contains { $0.actorId == DemoData.ines.id || $0.subjectId == DemoData.ines.id })
        let completions = try await camille.tasks.completions(groupId: lilas, since: .distantPast)
        #expect(completions.first { $0.taskId == first.id }?.completedBy == nil)
    }

    /// Deleting a group deletes its checklist items and its feed with it; nothing is handed over.
    @Test func groupDeletionTakesEverythingWithIt() async throws {
        let backend = InMemoryBackend.demo(now: clock.provider)
        let camille = backend.services(for: DemoData.camille.id)
        let task = try await camille.tasks.create(groupId: lilas, draft: TaskDraft(
            title: "Poubelles", dueAt: Self.utc("2041-03-04T07:00:00Z"), recurrence: Self.rule(.weekly),
            rotation: [DemoData.lucas.id, DemoData.ines.id], checklist: ["Sac jaune"]
        ))
        let item = try #require(task.checklist.first)
        try await camille.groups.deleteGroup(groupId: lilas)
        await #expect(throws: AppError.notFound) { try await camille.tasks.setChecklistItemDone(itemId: item.id, done: true) }
        #expect(try await camille.groups.activity(groupId: lilas).isEmpty)
        let lucasGroups = try await backend.services(for: DemoData.lucas.id).groups.myGroups()
        #expect(lucasGroups.map(\.id) == [DemoData.sportGroupId])
    }
}
