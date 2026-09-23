import Foundation
import TeamTasksCore

// Task RPCs: create / update / status / delete, validation and assignee rules (docs/CONTRACTS.md §1, §3, §4.1).
extension ContractScenarios {
    static let taskScenarios: [ContractScenario] = [
        ContractScenario("task.createFields") { harness in
            let alice = try await harness.user("Alice")
            let bob = try await harness.user("Bob")
            let group = try await alice.makeGroup(joinedBy: [bob])
            let title = Unique.name("Tâche")
            let draft = TaskDraft(
                title: "  \(title)  ", details: "  Détails de la tâche  ", priority: .high, dueAt: Fixed.dueA,
                assigneeIds: [alice.id, bob.id]
            )
            let created = try await alice.tasks.create(groupId: group.id, draft: draft)
            try Verify.equal(created.groupId, group.id, "groupId")
            try Verify.equal(created.title, title, "title (trimmed)")
            try Verify.equal(created.details, "Détails de la tâche", "details (trimmed)")
            try Verify.equal(created.status, .todo, "initial status")
            try Verify.equal(created.priority, .high, "priority")
            try Verify.equal(created.dueAt, Fixed.dueA, "due date")
            try Verify.equal(created.createdBy, alice.id, "createdBy")
            try Verify.equal(created.completedAt, nil, "completedAt of a new task")
            try Verify.equal(created.assigneeIds, sortedIDs([alice, bob]), "assigneeIds sorted by uuidString")
            try Verify.equal(created.myAssignedAt, nil, "myAssignedAt is only filled by myTasks")
            try Verify.equal(created.groupName, nil, "groupName is only filled by myTasks")
            try Verify.that(created.updatedAt >= created.createdAt, "updatedAt ≥ createdAt")

            let fetched = try await bob.tasks.task(id: created.id)
            try Verify.equal(fetched, created, "task(id:) returns what create returned")
            let listed = try await bob.tasks.tasks(groupId: group.id, includeOldDone: false)
            try Verify.equal(listed, [created], "the group's tasks")

            let minimal = try await alice.tasks.create(groupId: group.id, draft: TaskDraft(title: "Minimale", details: "   "))
            try Verify.equal(minimal.details, nil, "blank details are stored as NULL")
            try Verify.equal(minimal.priority, .medium, "default priority")
            try Verify.equal(minimal.dueAt, nil, "no due date")
            try Verify.equal(minimal.assigneeIds, [], "no assignee")
        },

        ContractScenario("task.validation") { harness in
            let alice = try await harness.user("Alice")
            let group = try await alice.makeGroup()
            // U+0000: Postgres text cannot hold it; adapters reject it like the mocks.
            for invalid in ["", "   ", Fixed.text(201), "a\u{0}b"] {
                try await Verify.fails(with: .invalidTitle, "create with the title \(invalid.debugDescription)") {
                    try await alice.tasks.create(groupId: group.id, draft: TaskDraft(title: invalid))
                }
            }
            for invalid in [Fixed.text(5001), "d\u{0}"] {
                try await Verify.fails(with: .invalidDetails, "create with the details \(invalid.debugDescription)") {
                    try await alice.tasks.create(groupId: group.id, draft: TaskDraft(title: "Titre", details: invalid))
                }
            }
            let none = try await alice.tasks.tasks(groupId: group.id, includeOldDone: true)
            try Verify.that(none.isEmpty, "failed creations create nothing, got \(none)")

            let longest = try await alice.tasks.create(
                groupId: group.id, draft: TaskDraft(title: Fixed.text(200), details: Fixed.text(5000))
            )
            try Verify.equal(longest.title, Fixed.text(200), "200-character title accepted")
            try Verify.equal(longest.details, Fixed.text(5000), "5000-character details accepted")

            for invalid in ["", "   ", Fixed.text(201)] {
                try await Verify.fails(with: .invalidTitle, "update with a title of \(invalid.count) characters") {
                    try await alice.tasks.update(taskId: longest.id, draft: TaskDraft(title: invalid))
                }
            }
            try await Verify.fails(with: .invalidDetails, "update with 5001-character details") {
                try await alice.tasks.update(taskId: longest.id, draft: TaskDraft(title: "Titre", details: Fixed.text(5001)))
            }
            let unchanged = try await alice.tasks.task(id: longest.id)
            try Verify.equal(unchanged, longest, "failed updates change nothing")
        },

        ContractScenario("task.assigneesMustBeMembers") { harness in
            let alice = try await harness.user("Alice")
            let bob = try await harness.user("Bob")
            let eve = try await harness.user("Eve")
            let group = try await alice.makeGroup(joinedBy: [bob])
            _ = try await eve.makeGroup("Autre", joinedBy: [alice])
            try await Verify.fails(with: .assigneeNotMember, "assign a member of another group") {
                try await alice.tasks.create(groupId: group.id, draft: TaskDraft(title: "Titre", assigneeIds: [bob.id, eve.id]))
            }
            try await Verify.fails(with: .assigneeNotMember, "assign an unknown user") {
                try await alice.tasks.create(groupId: group.id, draft: TaskDraft(title: "Titre", assigneeIds: [UUID()]))
            }
            let task = try await alice.makeTask(in: group.id, assignees: [bob])
            try await Verify.fails(with: .assigneeNotMember, "reassign to a non-member") {
                try await alice.reassign(task, to: [bob, eve])
            }
            let unchanged = try await alice.tasks.task(id: task.id)
            try Verify.equal(unchanged.assigneeIds, [bob.id], "a refused reassignment changes nothing")
            let tasks = try await alice.tasks.tasks(groupId: group.id, includeOldDone: true)
            try Verify.equal(tasks.map(\.id), [task.id], "refused creations create nothing")
        },

        ContractScenario("task.assigneeLimit") { harness in
            let alice = try await harness.user("Alice")
            var others: [ContractUser] = []
            for index in 1...Limits.maxAssignees {
                others.append(try await harness.user("Membre\(index)"))
            }
            let group = try await alice.makeGroup(joinedBy: others)
            let everyone = [alice] + others
            try Verify.equal(everyone.count, Limits.maxAssignees + 1, "fixture size")

            let twenty = Array(everyone.prefix(Limits.maxAssignees))
            let task = try await Verify.step("create with 20 assignees") {
                try await alice.tasks.create(
                    groupId: group.id, draft: TaskDraft(title: "Vingt", assigneeIds: Set(twenty.map(\.id)))
                )
            }
            try Verify.equal(task.assigneeIds, sortedIDs(twenty), "20 assignees accepted")
            try await Verify.fails(with: .tooManyAssignees, "create with 21 assignees") {
                try await alice.tasks.create(
                    groupId: group.id, draft: TaskDraft(title: "Vingt et un", assigneeIds: Set(everyone.map(\.id)))
                )
            }
            try await Verify.fails(with: .tooManyAssignees, "update to 21 assignees") {
                try await alice.reassign(task, to: everyone)
            }
            let unchanged = try await alice.tasks.task(id: task.id)
            try Verify.equal(unchanged.assigneeIds, sortedIDs(twenty), "a refused update keeps the 20 assignees")
        },

        ContractScenario("task.updateFields") { harness in
            let alice = try await harness.user("Alice")
            let bob = try await harness.user("Bob")
            let carol = try await harness.user("Carol")
            let group = try await alice.makeGroup(joinedBy: [bob, carol])
            let original = try await bob.tasks.create(
                groupId: group.id,
                draft: TaskDraft(title: "Originale", details: "Détails", priority: .low, dueAt: Fixed.dueA, assigneeIds: [bob.id])
            )
            let newTitle = Unique.name("Modifiée")
            let updated = try await bob.tasks.update(
                taskId: original.id,
                draft: TaskDraft(title: "  \(newTitle)  ", details: "", priority: .high, dueAt: nil, assigneeIds: [carol.id])
            )
            try Verify.equal(updated.id, original.id, "same task")
            try Verify.equal(updated.title, newTitle, "title (trimmed)")
            try Verify.equal(updated.details, nil, "empty details are stored as NULL")
            try Verify.equal(updated.priority, .high, "priority")
            try Verify.equal(updated.dueAt, nil, "a nil due date clears it")
            try Verify.equal(updated.assigneeIds, [carol.id], "assignees replaced")
            try Verify.equal(updated.status, .todo, "status untouched by update")
            try Verify.equal(updated.createdBy, bob.id, "createdBy kept")
            try Verify.equal(updated.createdAt, original.createdAt, "createdAt kept")
            try Verify.that(updated.updatedAt > original.updatedAt, "updatedAt moves forward")
            let fetched = try await alice.tasks.task(id: original.id)
            try Verify.equal(fetched, updated, "task(id:) returns what update returned")

            _ = try await bob.tasks.setStatus(taskId: original.id, status: .inProgress)
            let again = try await alice.tasks.update(
                taskId: original.id,
                draft: TaskDraft(title: newTitle, details: "Nouveaux détails", priority: .medium, dueAt: Fixed.dueB, assigneeIds: [])
            )
            try Verify.equal(again.status, .inProgress, "update keeps the current status")
            try Verify.equal(again.dueAt, Fixed.dueB, "new due date")
            try Verify.equal(again.details, "Nouveaux détails", "new details")
            try Verify.equal(again.assigneeIds, [], "assignees cleared")
        },

        ContractScenario("task.statusAndCompletedAt") { harness in
            let alice = try await harness.user("Alice")
            let group = try await alice.makeGroup()
            let task = try await alice.makeTask(in: group.id, assignees: [alice])

            let started = try await alice.tasks.setStatus(taskId: task.id, status: .inProgress)
            try Verify.equal(started.status, .inProgress, "in progress")
            try Verify.equal(started.completedAt, nil, "completedAt while in progress")
            try Verify.that(started.updatedAt > task.updatedAt, "updatedAt moves forward on a status change")

            let done = try await alice.tasks.setStatus(taskId: task.id, status: .done)
            try Verify.equal(done.status, .done, "done")
            let completedAt = try Verify.unwrap(done.completedAt, "completedAt of a done task")
            try Verify.that(completedAt > started.updatedAt, "completedAt is set when the task becomes done")
            let fetched = try await alice.tasks.task(id: task.id)
            try Verify.equal(fetched, done, "task(id:) returns what setStatus returned")
            let visible = try await alice.tasks.tasks(groupId: group.id, includeOldDone: false)
            try Verify.equal(visible.map(\.id), [task.id], "a recently completed task stays visible by default")

            let reopened = try await alice.tasks.setStatus(taskId: task.id, status: .todo)
            try Verify.equal(reopened.completedAt, nil, "completedAt cleared when reopened")
            let redone = try await alice.tasks.setStatus(taskId: task.id, status: .done)
            try Verify.that(redone.completedAt != nil, "completedAt set again")
        },

        // tasks_before_update: updatedAt only moves when title, details, status, priority or due date change.
        ContractScenario("task.updatedAtTracksFieldChanges") { harness in
            let alice = try await harness.user("Alice")
            let bob = try await harness.user("Bob")
            let group = try await alice.makeGroup(joinedBy: [bob])
            let created = try await alice.tasks.create(
                groupId: group.id,
                draft: TaskDraft(title: "Suivi", details: "Détails", priority: .high, dueAt: Fixed.dueA, assigneeIds: [alice.id])
            )
            let reassigned = try await alice.reassign(created, to: [alice, bob])
            try Verify.equal(reassigned.assigneeIds, sortedIDs([alice, bob]), "assignees replaced")
            try Verify.equal(reassigned.updatedAt, created.updatedAt, "an assignee-only edit keeps updatedAt")
            let padded = try await alice.tasks.update(
                taskId: created.id,
                draft: TaskDraft(title: "  Suivi  ", details: " Détails ", priority: .high, dueAt: Fixed.dueA, assigneeIds: [alice.id, bob.id])
            )
            try Verify.equal(padded.updatedAt, created.updatedAt, "identical (trimmed) fields keep updatedAt")
            let todo = try await alice.tasks.setStatus(taskId: created.id, status: .todo)
            try Verify.equal(todo.updatedAt, created.updatedAt, "an unchanged status keeps updatedAt")

            let done = try await alice.tasks.setStatus(taskId: created.id, status: .done)
            try Verify.that(done.updatedAt > created.updatedAt, "a status change moves updatedAt")
            let doneAgain = try await bob.tasks.setStatus(taskId: created.id, status: .done)
            try Verify.equal(doneAgain.updatedAt, done.updatedAt, "done → done keeps updatedAt")
            try Verify.equal(doneAgain.completedAt, done.completedAt, "done → done keeps completedAt")
            let fetched = try await bob.tasks.task(id: created.id)
            try Verify.equal(fetched, doneAgain, "task(id:) returns what setStatus returned")
        },

        ContractScenario("task.unknownTask") { harness in
            let alice = try await harness.user("Alice")
            _ = try await alice.makeGroup()
            let unknown = UUID()
            try await Verify.fails(with: .notFound, "task(id:) of an unknown task") { try await alice.tasks.task(id: unknown) }
            try await Verify.fails(with: .notFound, "update an unknown task") {
                try await alice.tasks.update(taskId: unknown, draft: TaskDraft(title: "Titre"))
            }
            try await Verify.fails(with: .notFound, "setStatus of an unknown task") {
                try await alice.tasks.setStatus(taskId: unknown, status: .done)
            }
            try await Verify.fails(with: .notFound, "delete an unknown task") { try await alice.tasks.delete(taskId: unknown) }
        },

        ContractScenario("task.assigneeRowsKeepMetadata") { harness in
            let alice = try await harness.user("Alice")
            let dan = try await harness.user("Dan")
            let bob = try await harness.user("Bob")
            let carol = try await harness.user("Carol")
            let group = try await alice.makeGroup(joinedBy: [dan, bob, carol])
            try await alice.groups.setRole(groupId: group.id, userId: dan.id, role: .admin)
            let task = try await alice.makeTask(in: group.id, assignees: [bob])
            let first = try await bob.assignment(of: task.id)
            try Verify.equal(first.assignedBy, alice.id, "assignedBy of the first assignment")
            let bobTasks = try await bob.tasks.myTasks(includeDone: true)
            try Verify.equal(bobTasks.first { $0.id == task.id }?.myAssignedAt, first.assignedAt, "myAssignedAt")

            // Dan (another admin) adds Carol: Bob's row is kept as is.
            let updated = try await dan.reassign(task, to: [bob, carol])
            try Verify.equal(updated.assigneeIds, sortedIDs([bob, carol]), "assignees after adding carol")
            let kept = try await bob.assignment(of: task.id)
            try Verify.equal(kept.assignedBy, alice.id, "a retained row keeps assignedBy")
            try Verify.equal(kept.assignedAt, first.assignedAt, "a retained row keeps assignedAt")
            let carolRow = try await carol.assignment(of: task.id)
            try Verify.equal(carolRow.assignedBy, dan.id, "a new row gets assignedBy = caller")
            try Verify.that(carolRow.assignedAt > first.assignedAt, "a new row gets a new assignedAt")

            // Same set again: nothing changes.
            _ = try await dan.reassign(updated, to: [bob, carol])
            let same = try await bob.assignment(of: task.id)
            try Verify.equal(same, kept, "re-saving the same assignees keeps the rows")

            // Removed then re-added: a brand new row.
            let withoutBob = try await dan.reassign(updated, to: [carol])
            try Verify.equal(withoutBob.assigneeIds, [carol.id], "bob unassigned")
            let bobEvents = try await bob.tasks.assignments(since: Fixed.longAgo)
            try Verify.that(!bobEvents.contains { $0.taskId == task.id }, "an unassigned user has no assignment row")
            _ = try await dan.reassign(withoutBob, to: [bob, carol])
            let fresh = try await bob.assignment(of: task.id)
            try Verify.equal(fresh.assignedBy, dan.id, "a re-added row gets the new assigner")
            try Verify.that(fresh.assignedAt > kept.assignedAt, "a re-added row gets a new assignedAt")
        },

        ContractScenario("task.deleteCascades") { harness in
            let alice = try await harness.user("Alice")
            let bob = try await harness.user("Bob")
            let group = try await alice.makeGroup(joinedBy: [bob])
            let task = try await alice.makeTask(in: group.id, assignees: [bob])
            let keep = try await alice.makeTask(in: group.id, assignees: [bob])
            try await alice.tasks.delete(taskId: task.id)
            try await Verify.fails(with: .notFound, "a deleted task") { try await bob.tasks.task(id: task.id) }
            let groupTasks = try await bob.tasks.tasks(groupId: group.id, includeOldDone: true)
            try Verify.equal(groupTasks.map(\.id), [keep.id], "the group's tasks after a deletion")
            let mine = try await bob.tasks.myTasks(includeDone: true)
            try Verify.equal(mine.map(\.id), [keep.id], "myTasks after a deletion")
            let events = try await bob.tasks.assignments(since: Fixed.longAgo)
            try Verify.equal(events.map(\.taskId), [keep.id], "assignments of a deleted task are gone")
        },
    ]
}

extension ContractUser {
    /// This user's assignment event for `taskId` (made by someone else).
    func assignment(of taskId: UUID) async throws -> AssignmentEvent {
        let events = try await tasks.assignments(since: Fixed.longAgo)
        return try Verify.unwrap(events.first { $0.taskId == taskId }, "\(displayName)'s assignment to \(taskId)")
    }
}
