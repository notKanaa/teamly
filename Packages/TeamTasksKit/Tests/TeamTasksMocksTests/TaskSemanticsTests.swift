import Foundation
import TeamTasksCore
import TeamTasksMocks
import Testing

/// Mock-specific task semantics that need an injected clock.
@Suite struct TaskSemanticsTests {
    let clock = MockClock(Date(timeIntervalSince1970: 1_790_150_400))
    let day: TimeInterval = 86_400

    @Test func oldDoneTasksAreHiddenUnlessRequested() async throws {
        let backend = InMemoryBackend.demo(now: clock.provider)
        let camille = backend.services(for: DemoData.camille.id)
        let task = try await camille.tasks.create(
            groupId: DemoData.lilasGroupId, draft: TaskDraft(title: "Arroser les plantes", assigneeIds: [DemoData.camille.id])
        )
        let done = try await camille.tasks.setStatus(taskId: task.id, status: .done)
        #expect(done.completedAt == clock.peek())

        func visible(includeOldDone: Bool) async throws -> Bool {
            try await camille.tasks.tasks(groupId: DemoData.lilasGroupId, includeOldDone: includeOldDone)
                .contains { $0.id == task.id }
        }

        clock.advance(by: TimeInterval(Limits.oldDoneTaskDays) * day)
        #expect(try await visible(includeOldDone: false)) // completed exactly 30 days ago: kept (gte)
        clock.advance(by: 1)
        #expect(try await !visible(includeOldDone: false))
        #expect(try await visible(includeOldDone: true))
        // Other reads are not filtered by age.
        #expect(try await camille.tasks.task(id: task.id).status == .done)
        #expect(try await camille.tasks.myTasks(includeDone: true).contains { $0.id == task.id })
        #expect(try await !camille.tasks.myTasks(includeDone: false).contains { $0.id == task.id })
        // The demo task completed yesterday is now old too; open tasks are never hidden.
        let recent = try await camille.tasks.tasks(groupId: DemoData.lilasGroupId, includeOldDone: false)
        #expect(!recent.contains { $0.id == DemoData.TaskIDs.nettoyerCuisine })
        #expect(recent.contains { $0.id == DemoData.TaskIDs.reparerFuite })

        _ = try await camille.tasks.setStatus(taskId: task.id, status: .inProgress)
        #expect(try await visible(includeOldDone: false))
    }

    @Test func completedAtIsKeptWhenAlreadyDone() async throws {
        let backend = InMemoryBackend.demo(now: clock.provider)
        let camille = backend.services(for: DemoData.camille.id)
        let task = try await camille.tasks.create(groupId: DemoData.lilasGroupId, draft: TaskDraft(title: "Ranger"))
        let done = try await camille.tasks.setStatus(taskId: task.id, status: .done)
        clock.advance(by: 60)
        let again = try await camille.tasks.setStatus(taskId: task.id, status: .done)
        #expect(again.completedAt == done.completedAt)
        #expect(again.updatedAt == done.updatedAt) // nothing changed: SQL keeps updated_at
    }

    @Test func timestampsFollowTheInjectedClock() async throws {
        let backend = InMemoryBackend.demo(now: clock.provider)
        let camille = backend.services(for: DemoData.camille.id)
        clock.advance(by: 1) // the demo groups were last active at the seed time
        let start = clock.peek()
        let task = try await camille.tasks.create(
            groupId: DemoData.sportGroupId, draft: TaskDraft(title: "Tracer les lignes", assigneeIds: [DemoData.lucas.id])
        )
        #expect(task.createdAt == start)
        #expect(task.updatedAt == start)
        let groups = try await camille.groups.myGroups()
        #expect(groups.first?.id == DemoData.sportGroupId) // bumped to now: most recently active
        #expect(groups.first?.group.lastActivityAt == start)

        clock.advance(by: 10)
        let lucas = backend.services(for: DemoData.lucas.id)
        let events = try await lucas.tasks.assignments(since: start.addingTimeInterval(-1))
        #expect(events.map(\.taskId) == [task.id])
        #expect(events.first?.assignedAt == start)
        #expect(events.first?.assignedBy == DemoData.camille.id)
    }

    @Test func assignmentsWithTheSameTimestampAreOrderedDeterministically() async throws {
        let backend = InMemoryBackend.demo(now: clock.provider)
        let camille = backend.services(for: DemoData.camille.id)
        var ids: [UUID] = []
        for title in ["Un", "Deux", "Trois"] {
            let task = try await camille.tasks.create(
                groupId: DemoData.lilasGroupId, draft: TaskDraft(title: title, assigneeIds: [DemoData.ines.id])
            )
            ids.append(task.id)
        }
        let ines = backend.services(for: DemoData.ines.id)
        let events = try await ines.tasks.assignments(since: clock.peek().addingTimeInterval(-1))
        #expect(events.map(\.taskId) == ids.sorted { $0.uuidString < $1.uuidString })
    }
}
