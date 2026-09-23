import Foundation
import TeamTasksCore

// PostgREST reads (docs/CONTRACTS.md §4.3): group tasks, my tasks, assignments since.
extension ContractScenarios {
    static let readScenarios: [ContractScenario] = [
        ContractScenario("reads.groupTasksAreScoped") { harness in
            let alice = try await harness.user("Alice")
            let first = try await alice.makeGroup("Un")
            let second = try await alice.makeGroup("Deux")
            let a1 = try await alice.makeTask(in: first.id)
            let a2 = try await alice.makeTask(in: first.id, assignees: [alice])
            let b1 = try await alice.makeTask(in: second.id)
            _ = try await alice.tasks.setStatus(taskId: a2.id, status: .done)
            for includeOldDone in [false, true] {
                let firstTasks = try await alice.tasks.tasks(groupId: first.id, includeOldDone: includeOldDone)
                try Verify.equal(Set(firstTasks.map(\.id)), [a1.id, a2.id], "tasks of the first group (\(includeOldDone))")
                let secondTasks = try await alice.tasks.tasks(groupId: second.id, includeOldDone: includeOldDone)
                try Verify.equal(secondTasks.map(\.id), [b1.id], "tasks of the second group (\(includeOldDone))")
                for task in firstTasks + secondTasks {
                    try Verify.equal(task.myAssignedAt, nil, "group tasks have no myAssignedAt")
                    try Verify.equal(task.groupName, nil, "group tasks have no groupName")
                }
            }
        },

        ContractScenario("reads.myTasks") { harness in
            let alice = try await harness.user("Alice")
            let bob = try await harness.user("Bob")
            let first = try await alice.makeGroup("Un", joinedBy: [bob])
            let second = try await alice.makeGroup("Deux", joinedBy: [bob])
            let todo = try await alice.makeTask(in: first.id, assignees: [bob], dueAt: Fixed.dueA)
            let done = try await alice.makeTask(in: second.id, assignees: [bob, alice])
            _ = try await bob.tasks.setStatus(taskId: done.id, status: .done)
            let notMine = try await alice.makeTask(in: first.id, assignees: [alice])
            let selfAssigned = try await bob.makeTask(in: first.id, assignees: [bob])

            let open = try await bob.tasks.myTasks(includeDone: false)
            try Verify.equal(Set(open.map(\.id)), [todo.id, selfAssigned.id], "open tasks assigned to bob")
            let all = try await bob.tasks.myTasks(includeDone: true)
            try Verify.equal(Set(all.map(\.id)), [todo.id, done.id, selfAssigned.id], "all tasks assigned to bob")
            try Verify.that(!all.contains { $0.id == notMine.id }, "tasks not assigned to bob are excluded")

            let names = [first.id: first.name, second.id: second.name]
            for item in all {
                try Verify.equal(item.groupName, names[item.groupId], "groupName of \(item.title)")
                try Verify.that(item.myAssignedAt != nil, "myAssignedAt of \(item.title)")
                let plain = try await bob.tasks.task(id: item.id)
                try Verify.equal(item.withoutPersonalFields, plain, "myTasks item \(item.title) matches task(id:)")
            }
            let doneItem = try Verify.unwrap(all.first { $0.id == done.id }, "done task in myTasks")
            try Verify.equal(doneItem.assigneeIds, sortedIDs([alice, bob]), "all assignees are listed, sorted")
            try Verify.equal(doneItem.status, .done, "status of the done task")
            let aliceOpen = try await alice.tasks.myTasks(includeDone: false)
            try Verify.equal(Set(aliceOpen.map(\.id)), [notMine.id], "alice's open tasks")
        },

        ContractScenario("reads.assignmentsSince") { harness in
            let alice = try await harness.user("Alice")
            let bob = try await harness.user("Bob")
            let group = try await alice.makeGroup(joinedBy: [bob])
            let first = try await alice.makeTask(in: group.id, "Premiere", assignees: [bob], dueAt: Fixed.dueA)
            let own = try await bob.makeTask(in: group.id, assignees: [bob])
            let second = try await alice.makeTask(in: group.id, "Seconde", assignees: [alice, bob])

            let events = try await bob.tasks.assignments(since: Fixed.longAgo)
            try Verify.equal(events.map(\.taskId), [first.id, second.id], "assignments by others, oldest first")
            try Verify.that(!events.contains { $0.taskId == own.id }, "self-assignments are excluded")
            let event = events[0]
            try Verify.equal(event.groupId, group.id, "event groupId")
            try Verify.equal(event.taskTitle, first.title, "event taskTitle")
            try Verify.equal(event.groupName, group.name, "event groupName")
            try Verify.equal(event.assignedBy, alice.id, "event assignedBy")
            try Verify.equal(event.dueAt, Fixed.dueA, "event dueAt")
            try Verify.that(events[0].assignedAt < events[1].assignedAt, "events ordered by assignedAt")

            let later = try await bob.tasks.assignments(since: events[0].assignedAt)
            try Verify.equal(later.map(\.taskId), [second.id], "since is exclusive")
            let none = try await bob.tasks.assignments(since: events[1].assignedAt)
            try Verify.that(none.isEmpty, "nothing after the last assignment, got \(none)")
            let aliceEvents = try await alice.tasks.assignments(since: Fixed.longAgo)
            try Verify.that(aliceEvents.isEmpty, "alice only assigned herself, got \(aliceEvents)")
        },
    ]
}
