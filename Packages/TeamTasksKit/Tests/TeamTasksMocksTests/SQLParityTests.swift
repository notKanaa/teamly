import Foundation
import TeamTasksCore
import TeamTasksMocks
import Testing

/// Mock behaviours checked against the SQL backend (probes of the local Supabase stack).
@Suite struct SQLParityTests {
    let clock = MockClock(Date(timeIntervalSince1970: 1_790_150_400))
    let lilas = DemoData.lilasGroupId

    func lastActivity(_ services: AppServices, _ groupId: UUID) async throws -> Date {
        try #require(try await services.groups.myGroups().first { $0.id == groupId }).group.lastActivityAt
    }

    /// SQL `set_member_role` returns before its UPDATE when the role does not change: no bump, no signal.
    @Test func noOpRoleChangeHasNoSideEffects() async throws {
        let backend = InMemoryBackend.demo(now: clock.provider)
        let camille = backend.services(for: DemoData.camille.id)
        let lucas = backend.services(for: DemoData.lucas.id)
        let ines = backend.services(for: DemoData.ines.id)
        let before = try await lastActivity(camille, lilas)
        var events = lucas.realtime.events(userId: DemoData.lucas.id, groupIds: [lilas]).makeAsyncIterator()
        #expect(await events.next() == .connected)
        clock.advance(by: 60)

        try await camille.groups.setRole(groupId: lilas, userId: DemoData.lucas.id, role: .member) // already a member
        try await camille.groups.setRole(groupId: lilas, userId: DemoData.camille.id, role: .admin) // the only admin
        #expect(try await lastActivity(camille, lilas) == before)
        #expect(try await camille.groups.members(groupId: lilas).map(\.role) == [.admin, .member, .member])

        // Sentinel: a new assignment of Lucas; nothing may precede its events.
        clock.advance(by: 60)
        let sentinel = try await ines.tasks.create(groupId: lilas, draft: TaskDraft(title: "Sentinelle", assigneeIds: [DemoData.lucas.id]))
        #expect(await events.next() == .groupActivity(groupId: lilas))
        #expect(await events.next() == .assigned(taskId: sentinel.id, groupId: lilas, assignedBy: DemoData.ines.id))
    }

    /// SQL `tasks_before_update` keeps `updated_at` unless title, details, status, priority or due date change.
    @Test func updatedAtOnlyMovesWhenAFieldChanges() async throws {
        let backend = InMemoryBackend.demo(now: clock.provider)
        let camille = backend.services(for: DemoData.camille.id)
        let created = try await camille.tasks.create(
            groupId: lilas,
            draft: TaskDraft(title: "Tâche P2", details: "d", priority: .high, dueAt: Date(timeIntervalSince1970: 1_924_992_000), assigneeIds: [DemoData.camille.id])
        )
        clock.advance(by: 60)
        let reassigned = try await camille.tasks.update(
            taskId: created.id,
            draft: TaskDraft(title: "Tâche P2", details: "d", priority: .high, dueAt: created.dueAt, assigneeIds: [DemoData.camille.id, DemoData.ines.id])
        )
        #expect(reassigned.assigneeIds.count == 2)
        #expect(reassigned.updatedAt == created.updatedAt, "an assignee-only edit keeps updatedAt")
        clock.advance(by: 60)
        var padded = TaskDraft(task: reassigned)
        padded.title = "  Tâche P2  "
        padded.details = " d "
        let same = try await camille.tasks.update(taskId: created.id, draft: padded)
        #expect(same.updatedAt == created.updatedAt, "an edit with identical (trimmed) fields keeps updatedAt")
        clock.advance(by: 60)
        let todoAgain = try await camille.tasks.setStatus(taskId: created.id, status: .todo)
        #expect(todoAgain.updatedAt == created.updatedAt, "todo → todo keeps updatedAt")

        clock.advance(by: 60)
        let done = try await camille.tasks.setStatus(taskId: created.id, status: .done)
        #expect(done.updatedAt == clock.peek())
        #expect(done.completedAt == done.updatedAt)
        clock.advance(by: 60)
        let doneAgain = try await camille.tasks.setStatus(taskId: created.id, status: .done)
        #expect(doneAgain.updatedAt == done.updatedAt, "done → done keeps updatedAt")
        #expect(doneAgain.completedAt == done.completedAt)
        #expect(try await camille.tasks.task(id: created.id) == doneAgain)

        clock.advance(by: 60)
        var retitled = TaskDraft(task: doneAgain)
        retitled.title = "Tâche P3"
        let changed = try await camille.tasks.update(taskId: created.id, draft: retitled)
        #expect(changed.updatedAt == clock.peek())
    }

    /// The UPDATE still happens (and bumps the group) even when `updated_at` is kept.
    @Test func unchangedUpdatesStillBumpTheGroup() async throws {
        let backend = InMemoryBackend.demo(now: clock.provider)
        let camille = backend.services(for: DemoData.camille.id)
        let task = try await camille.tasks.task(id: DemoData.TaskIDs.sortirPoubelles)
        clock.advance(by: 60)
        _ = try await camille.tasks.setStatus(taskId: task.id, status: task.status)
        #expect(try await lastActivity(camille, lilas) == clock.peek())
        clock.advance(by: 60)
        _ = try await camille.tasks.update(taskId: task.id, draft: TaskDraft(task: task))
        #expect(try await lastActivity(camille, lilas) == clock.peek())
    }

    /// Deleting an account sets `created_by` to NULL; SQL keeps `updated_at` (nothing editable changed).
    @Test func accountDeletionKeepsUpdatedAtOfTheirTasks() async throws {
        let backend = InMemoryBackend.demo(now: clock.provider)
        let camille = backend.services(for: DemoData.camille.id)
        let before = try await camille.tasks.task(id: DemoData.TaskIDs.faireCourses) // created by Lucas
        clock.advance(by: 60)
        try await backend.services(for: DemoData.lucas.id).auth.deleteAccount()
        let after = try await camille.tasks.task(id: before.id)
        #expect(after.createdBy == nil)
        #expect(after.updatedAt == before.updatedAt)
        #expect(try await lastActivity(camille, lilas) == clock.peek()) // the UPDATE still bumps the group
    }

    /// Postgres `text` cannot hold U+0000 (PostgREST answers 22P05): the field's validation error instead.
    @Test func nulCharacterIsRejected() async throws {
        let backend = InMemoryBackend.demo(now: clock.provider)
        let camille = backend.services(for: DemoData.camille.id)
        await #expect(throws: AppError.invalidTitle) {
            try await camille.tasks.create(groupId: lilas, draft: TaskDraft(title: "a\u{0}b"))
        }
        await #expect(throws: AppError.invalidDetails) {
            try await camille.tasks.create(groupId: lilas, draft: TaskDraft(title: "Titre", details: "x\u{0}"))
        }
        await #expect(throws: AppError.invalidTitle) {
            try await camille.tasks.update(taskId: DemoData.TaskIDs.sortirPoubelles, draft: TaskDraft(title: "\u{0}"))
        }
        await #expect(throws: AppError.invalidName) { try await camille.groups.createGroup(name: "x\u{0}y") }
        await #expect(throws: AppError.invalidName) { try await camille.groups.rename(groupId: lilas, name: "x\u{0}y") }
        await #expect(throws: AppError.invalidDisplayName) { try await camille.profiles.updateDisplayName("Ca\u{0}mille") }
        await #expect(throws: AppError.invalidDisplayName) {
            try await backend.services(for: nil).auth.signUp(email: "nul@example.com", password: "motdepasse123", displayName: "N\u{0}")
        }
        #expect(try await camille.tasks.tasks(groupId: lilas, includeOldDone: true).count == 5)
    }
}
