import Foundation
import TeamTasksCore

// The v2 reads of docs/CONTRACTS-V2.md §10: « Mes tâches » bounded by a completion date, and the groups overview. The
// bounds are server timestamps read from the completions (`completedAt`), never the device clock. The row limit of the
// server (the overview's pages) needs more than 1000 rows: it is covered by the adapter's unit tests.
extension ContractScenarios {
    static let readV2Scenarios: [ContractScenario] = [
        ContractScenario("reads.myTasksDoneSince") { harness in
            let alice = try await harness.user("Alice")
            let bob = try await harness.user("Bob")
            let first = try await alice.makeGroup("Un", joinedBy: [bob])
            let second = try await alice.makeGroup("Deux", color: .teal, emoji: "🎉", joinedBy: [bob])
            let todo = try await alice.makeTask(in: first.id, "A faire", assignees: [bob], dueAt: Fixed.dueA)
            let started = try await alice.makeTask(in: second.id, "En cours", assignees: [bob])
            let early = try await alice.makeTask(in: first.id, "Tot", assignees: [bob, alice])
            let late = try await alice.makeTask(in: second.id, "Tard", assignees: [bob])
            let reopened = try await alice.makeTask(in: first.id, "Rouverte", assignees: [bob])
            let notBob = try await alice.makeTask(in: first.id, "Pas Bob", assignees: [alice])
            _ = try await bob.tasks.setStatus(taskId: started.id, status: .inProgress)
            let earlyDone = try await bob.tasks.setStatus(taskId: early.id, status: .done)
            _ = try await bob.tasks.setStatus(taskId: reopened.id, status: .done)
            let notBobDone = try await alice.tasks.setStatus(taskId: notBob.id, status: .done)
            let lateDone = try await bob.tasks.setStatus(taskId: late.id, status: .done)
            _ = try await bob.tasks.setStatus(taskId: reopened.id, status: .todo)
            let earlyAt = try Verify.unwrap(earlyDone.completedAt, "completedAt of \(early.title)")
            let notBobAt = try Verify.unwrap(notBobDone.completedAt, "completedAt of \(notBob.title)")
            let lateAt = try Verify.unwrap(lateDone.completedAt, "completedAt of \(late.title)")
            try Verify.that(earlyAt < notBobAt && notBobAt < lateAt, "completions in order: \(earlyAt), \(notBobAt), \(lateAt)")

            // Every task not done, plus the done ones completed at or after the bound (inclusive).
            let open: Set<UUID> = [todo.id, started.id, reopened.id]
            let all = try await bob.tasks.myTasks(includeDone: true)
            let everything = Dictionary(all.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            let cases: [(since: Date, expected: Set<UUID>, label: String)] = [
                (Fixed.longAgo, open.union([early.id, late.id]), "every done task since long ago"),
                (earlyAt, open.union([early.id, late.id]), "since is inclusive (first completion)"),
                (earlyAt.addingTimeInterval(0.001), open.union([late.id]), "a task done before since is left out"),
                (lateAt, open.union([late.id]), "since is inclusive (last completion)"),
                (lateAt.addingTimeInterval(0.001), open, "only the tasks not done after the last completion"),
            ]
            for (since, expected, label) in cases {
                let bounded = try await bob.tasks.myTasks(doneSince: since)
                try Verify.equal(Set(bounded.map(\.id)), expected, "bob: \(label)")
                for item in bounded {
                    // The same item as the full read: myAssignedAt, myAssignedBy, the group's name, color and emoji.
                    try Verify.equal(Optional(item), everything[item.id], "bob: \(item.title) as myTasks(includeDone: true) reads it")
                }
            }
            let secondItem = try await bob.tasks.myTasks(doneSince: lateAt).first { $0.id == late.id }
            try Verify.equal(secondItem?.groupName, second.name, "the group's name")
            try Verify.equal(secondItem?.groupColor, .teal, "the group's color")
            try Verify.equal(secondItem?.groupEmoji, "🎉", "the group's emoji")

            // Only the caller's tasks.
            let aliceFromEarly = try await alice.tasks.myTasks(doneSince: earlyAt)
            try Verify.equal(Set(aliceFromEarly.map(\.id)), [early.id, notBob.id], "alice: her done tasks since the first completion")
            let aliceAfterLate = try await alice.tasks.myTasks(doneSince: lateAt)
            try Verify.that(aliceAfterLate.isEmpty, "alice: nothing done after the last completion, got \(aliceAfterLate)")
        },

        ContractScenario("reads.groupOverviews") { harness in
            let alice = try await harness.user("Alice")
            let bob = try await harness.user("Bob")
            let carol = try await harness.user("Carol")
            let dan = try await harness.user("Dan")
            let eve = try await harness.user("Eve")
            _ = try await bob.profiles.updateAvatar(color: .teal, emoji: "🦊")
            let big = try await alice.makeGroup("Grand", color: .coral, emoji: "🏠", joinedBy: [bob, carol, dan])
            let small = try await bob.makeGroup("Petit", joinedBy: [alice])
            let empty = try await alice.makeGroup("Vide")
            let foreign = try await eve.makeGroup("Autre")

            // « Grand »: 3 tasks not done (to do, in progress, reopened), 2 done one after the other.
            _ = try await alice.makeTask(in: big.id, "A faire", assignees: [bob])
            let started = try await alice.makeTask(in: big.id, "En cours", assignees: [carol])
            let early = try await alice.makeTask(in: big.id, "Tot", assignees: [dan])
            let late = try await alice.makeTask(in: big.id, "Tard", assignees: [bob])
            let reopened = try await alice.makeTask(in: big.id, "Rouverte")
            _ = try await carol.tasks.setStatus(taskId: started.id, status: .inProgress)
            let earlyDone = try await dan.tasks.setStatus(taskId: early.id, status: .done)
            _ = try await alice.tasks.setStatus(taskId: reopened.id, status: .done)
            _ = try await alice.tasks.setStatus(taskId: reopened.id, status: .todo)
            let lateDone = try await bob.tasks.setStatus(taskId: late.id, status: .done)
            // « Petit »: one task to do, one done after all of them. Another user's group has a task too.
            _ = try await bob.makeTask(in: small.id, "A faire", assignees: [alice])
            let smallTask = try await bob.makeTask(in: small.id, "Faite")
            _ = try await bob.tasks.setStatus(taskId: smallTask.id, status: .done)
            _ = try await eve.makeTask(in: foreign.id)
            let earlyAt = try Verify.unwrap(earlyDone.completedAt, "completedAt of \(early.title)")
            let lateAt = try Verify.unwrap(lateDone.completedAt, "completedAt of \(late.title)")

            // One overview per distinct group of the caller, in the order asked; other groups are left out.
            let asked = [small.id, foreign.id, big.id, UUID(), empty.id, big.id]
            let overviews = try await alice.groups.overviews(groupIds: asked, doneSince: lateAt)
            try Verify.equal(overviews.map(\.groupId), [small.id, big.id, empty.id], "alice's groups, in the order asked, once each")
            for overview in overviews {
                let members = try await alice.groups.members(groupId: overview.groupId)
                try Verify.equal(overview.members, members, "the members of \(overview.groupId), as members(groupId:) reads them")
            }
            let bigOverview = overviews[1]
            try Verify.equal(bigOverview.members.count, 4, "the members of \(big.name)")
            let bobMember = try Verify.unwrap(bigOverview.members.first { $0.user.id == bob.id }, "bob in \(big.name)")
            try Verify.equal(bobMember.user.avatarColor, .teal, "bob's avatar color")
            try Verify.equal(bobMember.user.avatarEmoji, "🦊", "bob's avatar emoji")
            try Verify.equal(bigOverview.openTaskCount, 3, "to do, in progress and reopened tasks are not done")
            try Verify.equal(bigOverview.doneTaskCount, 1, "a task done at doneSince counts (inclusive)")
            try Verify.equal(overviews[0].members.map(\.user.id), [bob.id, alice.id], "the admin first")
            try Verify.equal(overviews[0].openTaskCount, 1, "the task to do of \(small.name)")
            try Verify.equal(overviews[0].doneTaskCount, 1, "the task done after doneSince")
            try Verify.equal(overviews[2].members.map(\.user.id), [alice.id], "a group of one member")
            try Verify.equal(overviews[2].openTaskCount, 0, "no task")
            try Verify.equal(overviews[2].doneTaskCount, 0, "no task")

            // doneSince only moves the done count.
            for (since, done, label) in [
                (Fixed.longAgo, 2, "every done task since long ago"),
                (earlyAt, 2, "doneSince is inclusive"),
                (earlyAt.addingTimeInterval(0.001), 1, "a task done before doneSince does not count"),
                (lateAt.addingTimeInterval(0.001), 0, "nothing done after the last completion"),
            ] {
                let read = try await alice.groups.overviews(groupIds: [big.id], doneSince: since)
                try Verify.equal(read.map(\.doneTaskCount), [done], label)
                try Verify.equal(read.map(\.openTaskCount), [3], "\(label): the tasks not done")
            }
            // The same counts as the group's tasks.
            let bigTasks = try await alice.tasks.tasks(groupId: big.id, includeOldDone: true)
            try Verify.equal(bigOverview.openTaskCount, bigTasks.filter { $0.status != .done }.count, "open tasks as tasks(groupId:) reads them")
            try Verify.equal(
                bigOverview.doneTaskCount, bigTasks.filter { $0.status == .done && ($0.completedAt ?? .distantPast) >= lateAt }.count,
                "done tasks as tasks(groupId:) reads them"
            )

            // Every member reads the same overview; non-members and an empty list read nothing.
            let seenByBob = try await bob.groups.overviews(groupIds: [big.id], doneSince: lateAt)
            try Verify.equal(seenByBob, [bigOverview], "every member reads the same overview")
            try await Verify.hidden("the overviews of a non-member") {
                try await eve.groups.overviews(groupIds: [big.id, small.id, empty.id], doneSince: Fixed.longAgo)
            }
            let none = try await alice.groups.overviews(groupIds: [], doneSince: Fixed.longAgo)
            try Verify.that(none.isEmpty, "no group asked, no overview: \(none)")

            // A member who leaves is no longer listed, and no longer reads the group.
            try await carol.groups.leave(groupId: big.id)
            let afterLeave = try await alice.groups.overviews(groupIds: [big.id], doneSince: lateAt)
            let remaining = try await alice.memberIDs(of: big.id)
            try Verify.equal(afterLeave.map { $0.members.map(\.user.id) }, [remaining], "the members after carol left")
            try Verify.equal(remaining.count, 3, "three members left")
            try await Verify.hidden("the overview of a group carol left") {
                try await carol.groups.overviews(groupIds: [big.id], doneSince: Fixed.longAgo)
            }
        },
    ]
}
