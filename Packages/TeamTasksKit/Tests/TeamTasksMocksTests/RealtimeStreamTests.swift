import Foundation
import TeamTasksCore
import TeamTasksMocks
import Testing

/// The mock delivers Realtime events synchronously during each write, in commit order, so these tests read
/// the streams directly. Absence is checked by performing a "sentinel" change whose event must come next.
@Suite struct RealtimeStreamTests {
    let backend = InMemoryBackend.demo()
    var camille: AppServices { backend.services(for: DemoData.camille.id) }
    var lucas: AppServices { backend.services(for: DemoData.lucas.id) }
    var ines: AppServices { backend.services(for: DemoData.ines.id) }

    @Test func connectedFirstThenGroupActivityForFilteredGroups() async throws {
        let camille = camille
        var events = camille.realtime.events(userId: DemoData.camille.id, groupIds: [DemoData.lilasGroupId]).makeAsyncIterator()
        #expect(await events.next() == .connected)

        // Activity in Sport (not in the filter) is not delivered; the next event is the Lilas one.
        _ = try await lucas.tasks.create(groupId: DemoData.sportGroupId, draft: TaskDraft(title: "Hors filtre"))
        _ = try await ines.tasks.create(groupId: DemoData.lilasGroupId, draft: TaskDraft(title: "Dans le filtre"))
        #expect(await events.next() == .groupActivity(groupId: DemoData.lilasGroupId))

        _ = try await camille.groups.rename(groupId: DemoData.lilasGroupId, name: "Coloc' des Lilas")
        #expect(await events.next() == .groupActivity(groupId: DemoData.lilasGroupId))
    }

    @Test func groupActivityRequiresMembership() async throws {
        // Inès lists Sport in her filter but is not a member (RLS): nothing is delivered for it.
        var events = ines.realtime.events(
            userId: DemoData.ines.id, groupIds: [DemoData.sportGroupId, DemoData.lilasGroupId]
        ).makeAsyncIterator()
        #expect(await events.next() == .connected)
        _ = try await lucas.tasks.create(groupId: DemoData.sportGroupId, draft: TaskDraft(title: "Privé"))
        _ = try await camille.tasks.create(groupId: DemoData.lilasGroupId, draft: TaskDraft(title: "Sentinelle"))
        #expect(await events.next() == .groupActivity(groupId: DemoData.lilasGroupId))
    }

    /// The real Realtime server fails the whole channel from about 70 ids in one `id=in.(…)` filter (index row
    /// size limit), so only the first `maxRealtimeGroups` (60) ids are watched.
    @Test func onlyTheFirstSixtyGroupIdsAreWatched() async throws {
        #expect(InMemoryBackend.maxRealtimeGroups == 60)
        let filter = (0..<60).map { _ in UUID() } + [DemoData.lilasGroupId]
        var events = camille.realtime.events(userId: DemoData.camille.id, groupIds: filter).makeAsyncIterator()
        #expect(await events.next() == .connected)
        _ = try await ines.tasks.create(groupId: DemoData.lilasGroupId, draft: TaskDraft(title: "Ignorée"))
        try await lucas.groups.setRole(groupId: DemoData.sportGroupId, userId: DemoData.camille.id, role: .admin)
        #expect(await events.next() == .membershipsChanged)

        let sixty = (0..<59).map { _ in UUID() } + [DemoData.lilasGroupId]
        var watched = camille.realtime.events(userId: DemoData.camille.id, groupIds: sixty).makeAsyncIterator()
        #expect(await watched.next() == .connected)
        _ = try await ines.tasks.create(groupId: DemoData.lilasGroupId, draft: TaskDraft(title: "Suivie"))
        #expect(await watched.next() == .groupActivity(groupId: DemoData.lilasGroupId))
    }

    /// Realtime rows follow the RLS of the SESSION user: a signed-out client (anon role) receives nothing,
    /// whatever `userId` it passes. Signing in later makes the channel deliver again (the token is updated).
    @Test func realtimeIsBoundToTheSessionUser() async throws {
        let device = backend.services(for: nil)
        var events = device.realtime.events(userId: DemoData.camille.id, groupIds: [DemoData.sportGroupId]).makeAsyncIterator()
        #expect(await events.next() == .connected)
        _ = try await lucas.tasks.create(
            groupId: DemoData.sportGroupId, draft: TaskDraft(title: "Privée", assigneeIds: [DemoData.camille.id])
        )
        _ = try await lucas.groups.rename(groupId: DemoData.sportGroupId, name: "Projet Asso Sport 2026")

        // Sentinel: once signed in as Camille, the next change is delivered; nothing may precede it.
        try await device.auth.signIn(email: DemoData.camille.email, password: DemoData.password)
        try await lucas.groups.setRole(groupId: DemoData.sportGroupId, userId: DemoData.camille.id, role: .admin)
        #expect(await events.next() == .groupActivity(groupId: DemoData.sportGroupId))
        #expect(await events.next() == .membershipsChanged)
    }

    /// Filters use the `userId` argument, visibility uses the session user (like RLS on the real server).
    @Test func filtersUseTheUserIdButVisibilityTheSession() async throws {
        // Inès's device subscribes with Camille's id: Camille's assignments in Lilas are visible to Inès (member),
        // those in Sport are not.
        var events = ines.realtime.events(userId: DemoData.camille.id, groupIds: []).makeAsyncIterator()
        #expect(await events.next() == .connected)
        _ = try await lucas.tasks.create(
            groupId: DemoData.sportGroupId, draft: TaskDraft(title: "Sport", assigneeIds: [DemoData.camille.id])
        )
        let lilasTask = try await lucas.tasks.create(
            groupId: DemoData.lilasGroupId, draft: TaskDraft(title: "Lilas", assigneeIds: [DemoData.camille.id])
        )
        #expect(await events.next() == .assigned(taskId: lilasTask.id, groupId: DemoData.lilasGroupId, assignedBy: DemoData.lucas.id))
    }

    @Test func membershipsChangedForTheUsersOwnMemberships() async throws {
        let newcomer = try backend.createAccount(email: "nouveau@example.com", password: "motdepasse123", displayName: "Nouveau")
        let services = backend.services(for: newcomer.id)
        var events = services.realtime.events(userId: newcomer.id, groupIds: []).makeAsyncIterator()
        #expect(await events.next() == .connected)

        _ = try await services.groups.join(code: InviteCode(DemoData.lilasInviteCode)!)
        #expect(await events.next() == .membershipsChanged)
        try await camille.groups.setRole(groupId: DemoData.lilasGroupId, userId: newcomer.id, role: .admin)
        #expect(await events.next() == .membershipsChanged)
        // Someone else's membership change is not delivered to this user.
        try await camille.groups.removeMember(groupId: DemoData.lilasGroupId, userId: DemoData.ines.id)
        // The profile row is updated by a display-name change too (same Realtime binding).
        _ = try await services.profiles.updateDisplayName("Nouveau nom")
        #expect(await events.next() == .membershipsChanged)
        try await services.groups.leave(groupId: DemoData.lilasGroupId)
        #expect(await events.next() == .membershipsChanged)
        _ = try await services.groups.createGroup(name: "Le mien")
        #expect(await events.next() == .membershipsChanged)
    }

    @Test func assignedForEveryNewRowOfTheUser() async throws {
        var events = camille.realtime.events(userId: DemoData.camille.id, groupIds: []).makeAsyncIterator()
        #expect(await events.next() == .connected)

        let byLucas = try await lucas.tasks.create(
            groupId: DemoData.sportGroupId,
            draft: TaskDraft(title: "Pour Camille", assigneeIds: [DemoData.camille.id, DemoData.lucas.id])
        )
        #expect(await events.next() == .assigned(taskId: byLucas.id, groupId: DemoData.sportGroupId, assignedBy: DemoData.lucas.id))

        let own = try await camille.tasks.create(
            groupId: DemoData.lilasGroupId, draft: TaskDraft(title: "Pour moi", assigneeIds: [DemoData.camille.id])
        )
        #expect(await events.next() == .assigned(taskId: own.id, groupId: DemoData.lilasGroupId, assignedBy: DemoData.camille.id))

        // Re-saving the same assignees inserts no row; then a new row for Camille is inserted.
        _ = try await lucas.tasks.update(taskId: byLucas.id, draft: TaskDraft(task: byLucas))
        let task = try await lucas.tasks.create(groupId: DemoData.sportGroupId, draft: TaskDraft(title: "Plus tard"))
        var draft = TaskDraft(task: task)
        draft.assigneeIds = [DemoData.camille.id]
        _ = try await lucas.tasks.update(taskId: task.id, draft: draft)
        #expect(await events.next() == .assigned(taskId: task.id, groupId: DemoData.sportGroupId, assignedBy: DemoData.lucas.id))
    }

    @Test func eventsFollowCommitOrder() async throws {
        var events = camille.realtime.events(
            userId: DemoData.camille.id, groupIds: [DemoData.lilasGroupId, DemoData.sportGroupId]
        ).makeAsyncIterator()
        #expect(await events.next() == .connected)
        let task = try await lucas.tasks.create(
            groupId: DemoData.sportGroupId, draft: TaskDraft(title: "Ordre", assigneeIds: [DemoData.camille.id])
        )
        _ = try await ines.tasks.create(groupId: DemoData.lilasGroupId, draft: TaskDraft(title: "Ensuite"))
        #expect(await events.next() == .groupActivity(groupId: DemoData.sportGroupId))
        #expect(await events.next() == .assigned(taskId: task.id, groupId: DemoData.sportGroupId, assignedBy: DemoData.lucas.id))
        #expect(await events.next() == .groupActivity(groupId: DemoData.lilasGroupId))
    }

    @Test func cancellingTheConsumerUnsubscribes() async throws {
        let backend = backend
        #expect(backend.realtimeSubscriberCount == 0)
        let stream = camille.realtime.events(userId: DemoData.camille.id, groupIds: [DemoData.lilasGroupId])
        #expect(backend.realtimeSubscriberCount == 1)
        let consumer = Task {
            var count = 0
            for await _ in stream { count += 1 }
            return count
        }
        consumer.cancel()
        let received = await consumer.value
        #expect(received <= 1)
        #expect(backend.realtimeSubscriberCount == 0)
    }
}
