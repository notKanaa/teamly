import Foundation
import TeamTasksCore

// v2 rotation « à tour de rôle » (docs/CONTRACTS-V2.md §0, §3, §5, §6, §11): the first turn, the turns handed out by
// the spawn, the departed members, the handover when the turn holder leaves, and the edits of a rotating task.
extension ContractScenarios {
    static let rotationScenarios: [ContractScenario] = [
        ContractScenario("rotation.create") { harness in
            let alice = try await harness.user("Alice")
            let bob = try await harness.user("Bob")
            let carol = try await harness.user("Carol")
            let dan = try await harness.user("Dan")
            let eve = try await harness.user("Eve")
            let group = try await alice.makeGroup(joinedBy: [bob, carol, dan])
            let due = try utc("2041-03-04T07:00:00Z")
            func create(rule: RecurrenceRule? = Rule.weekly(), rotation: [UUID], assignees: Set<UUID> = []) async throws -> TaskItem {
                try await alice.tasks.create(groupId: group.id, draft: TaskDraft(
                    title: Unique.name("Poubelles"), dueAt: due, assigneeIds: assignees, recurrence: rule, rotation: rotation
                ))
            }

            // With a rotation, the assignee ids are ignored (even a non-member's): rotation[0] takes the first turn,
            // assigned by the creator.
            let task = try await create(rotation: [bob.id, carol.id, dan.id], assignees: [eve.id])
            try Verify.equal(task.rotation, [bob.id, carol.id, dan.id], "the rotation, in turn order")
            try Verify.equal(task.turnUserId, bob.id, "the first turn is rotation[0]'s")
            try Verify.equal(task.assigneeIds, [bob.id], "the turn holder is the only assignee")
            let fetched = try await carol.tasks.task(id: task.id)
            try Verify.equal(fetched, task, "task(id:) returns what create returned")
            let event = try await bob.assignment(of: task.id)
            try Verify.equal(event.assignedBy, alice.id, "the first turn is assigned by the creator")
            try Verify.that(event.taskHasRotation, "the assignment is on a rotating task")
            try Verify.that(!event.isRotationTurn, "the first turn is worded as a new assignment")

            try await Verify.fails(with: .invalidRotation, "a rotation of one member") { try await create(rotation: [bob.id]) }
            try await Verify.fails(with: .invalidRotation, "duplicates") { try await create(rotation: [bob.id, carol.id, bob.id]) }
            try await Verify.fails(with: .invalidRotation, "a non-member") { try await create(rotation: [bob.id, eve.id]) }
            try await Verify.fails(with: .invalidRotation, "an unknown user") { try await create(rotation: [bob.id, UUID()]) }
            try await Verify.fails(with: .invalidRotation, "more than 20 users") {
                try await create(rotation: (0...Limits.rotationMax).map { _ in UUID() })
            }
            try await Verify.fails(with: .invalidRotation, "a rotation without a rule") {
                try await create(rule: nil, rotation: [bob.id, carol.id])
            }
            // Order (§3): recurrence → rotation → assignees.
            try await Verify.fails(with: .invalidRecurrence, "the rule before the rotation") {
                try await create(rule: Rule.weekly(interval: 0), rotation: [bob.id])
            }
            try await Verify.fails(with: .invalidRotation, "the rotation before the assignees") {
                try await create(rotation: [bob.id, eve.id], assignees: [eve.id])
            }
            let pair = try await create(rotation: [carol.id, dan.id])
            try Verify.equal(pair.turnUserId, carol.id, "2 members are enough")
            try Verify.equal(pair.assigneeIds, [carol.id], "the turn holder of a pair")
            let tasks = try await alice.tasks.tasks(groupId: group.id, includeOldDone: true)
            try Verify.equal(Set(tasks.map(\.id)), [task.id, pair.id], "refused creations create nothing")
        },

        ContractScenario("rotation.turnsOnSpawn") { harness in
            let alice = try await harness.user("Alice")
            let bob = try await harness.user("Bob")
            let carol = try await harness.user("Carol")
            let dan = try await harness.user("Dan")
            let group = try await alice.makeGroup(joinedBy: [bob, carol, dan])
            let task = try await alice.makeRecurringTask(
                in: group.id, "Poubelles", rule: Rule.weekly(), dueAt: try utc("2041-03-04T07:00:00Z"), rotation: [bob, carol, dan]
            )

            // Bob completes his turn: Carol's turn, handed out by the server (no assigner: « C’est ton tour »).
            let (done, second) = try await bob.completeAndReadNext(task)
            try Verify.equal(second.rotation, [bob.id, carol.id, dan.id], "the rotation is copied")
            try Verify.equal(second.turnUserId, carol.id, "the turn goes to the next member")
            try Verify.equal(second.assigneeIds, [carol.id], "the turn holder is the only assignee")
            try Verify.equal(done.turnUserId, bob.id, "the completed occurrence keeps its turn")
            let carolEvent = try await carol.assignment(of: second.id)
            try Verify.equal(carolEvent.assignedBy, nil, "a turn handed out by the server has no assigner")
            try Verify.that(carolEvent.isRotationTurn, "worded « C’est ton tour »")
            try Verify.equal(carolEvent.assignedAt, done.completedAt, "assigned in the completion's transaction")
            try Verify.equal(carolEvent.dueAt, try utc("2041-03-11T07:00:00Z"), "the next occurrence's due date")

            // Carol → Dan → Bob (wrap-around).
            let third = try await carol.completeAndReadNext(second).next
            try Verify.equal(third.turnUserId, dan.id, "carol → dan")
            let fourth = try await dan.completeAndReadNext(third).next
            try Verify.equal(fourth.turnUserId, bob.id, "dan → bob (wrap-around)")
            try Verify.equal(fourth.assigneeIds, [bob.id], "bob is the only assignee")
            let bobEvent = try await bob.assignment(of: fourth.id)
            try Verify.that(bobEvent.isRotationTurn, "bob's turn is a rotation turn")
            // Someone else completes bob's turn: the next turn still follows bob.
            let fifth = try await alice.completeAndReadNext(fourth).next
            try Verify.equal(fifth.turnUserId, carol.id, "after bob's turn, carol's, whoever completed it")
            try Verify.equal(fifth.seriesId, task.id, "the same series")

            // The completer takes the turn: assigned by themselves, not notified.
            let mine = try await alice.makeRecurringTask(
                in: group.id, "Vaisselle", rule: Rule.daily(), dueAt: try utc("2041-03-04T18:00:00Z"), rotation: [bob, alice]
            )
            let myTurn = try await alice.completeAndReadNext(mine).next
            try Verify.equal(myTurn.turnUserId, alice.id, "alice completed bob's turn and takes hers")
            try Verify.equal(myTurn.assigneeIds, [alice.id], "alice is the only assignee")
            let aliceEvent = try await alice.assignmentIfAny(of: myTurn.id)
            try Verify.that(aliceEvent == nil, "a turn taken by the completer is not a new assignment")
            let aliceTasks = try await alice.tasks.myTasks(includeDone: false)
            try Verify.equal(
                aliceTasks.first { $0.id == myTurn.id }?.myAssignedBy, alice.id, "assigned by the completer herself"
            )
        },

        ContractScenario("rotation.departedMembersOnSpawn") { harness in
            let alice = try await harness.user("Alice")
            let bob = try await harness.user("Bob")
            let carol = try await harness.user("Carol")
            let dan = try await harness.user("Dan")
            let erin = try await harness.user("Erin")
            let group = try await alice.makeGroup(joinedBy: [bob, carol, dan, erin])
            let due = try utc("2041-03-04T07:00:00Z")

            // Carol is listed but it is not her turn: her leaving changes nothing until the spawn, which removes her
            // from the rotation and skips her.
            let task = try await alice.makeRecurringTask(in: group.id, rule: Rule.weekly(), dueAt: due, rotation: [bob, carol, dan, erin])
            try await carol.groups.leave(groupId: group.id)
            let kept = try await alice.tasks.task(id: task.id)
            try Verify.equal(kept, task, "a listed member who is not the turn holder leaves: nothing changes")
            let next = try await bob.completeAndReadNext(task).next
            try Verify.equal(next.rotation, [bob.id, dan.id, erin.id], "the spawn removes carol from the rotation")
            try Verify.equal(next.turnUserId, dan.id, "and skips her turn")

            // Fewer than 2 members left: the rotation is dropped, the task keeps repeating; the remaining member is the
            // assignee, assigned by the completer when it is them, else by nobody.
            let byBob = try await alice.makeRecurringTask(in: group.id, "Paire", rule: Rule.weekly(), dueAt: due, rotation: [bob, erin])
            let byAlice = try await alice.makeRecurringTask(in: group.id, "Paire", rule: Rule.weekly(), dueAt: due, rotation: [bob, erin])
            try await erin.groups.leave(groupId: group.id)
            let alone = try await bob.completeAndReadNext(byBob).next
            try Verify.equal(alone.rotation, [], "one member left: no rotation")
            try Verify.equal(alone.turnUserId, nil, "and no turn")
            try Verify.equal(alone.recurrence, byBob.recurrence, "the task keeps repeating")
            try Verify.equal(alone.assigneeIds, [bob.id], "the remaining member is the assignee")
            let bobAlone = try await bob.assignmentIfAny(of: alone.id)
            try Verify.that(bobAlone == nil, "assigned by the completer himself: not a new assignment")
            let other = try await alice.completeAndReadNext(byAlice).next
            try Verify.equal(other.assigneeIds, [bob.id], "the remaining member is the assignee")
            let bobOther = try await bob.assignment(of: other.id)
            try Verify.equal(bobOther.assignedBy, nil, "completed by someone else: assigned by nobody")
            try Verify.that(!bobOther.isRotationTurn, "no rotation any more: worded as a new assignment")
        },

        ContractScenario("rotation.handover") { harness in
            let alice = try await harness.user("Alice")
            let bob = try await harness.user("Bob")
            let carol = try await harness.user("Carol")
            let dan = try await harness.user("Dan")
            let erin = try await harness.user("Erin")
            let frank = try await harness.user("Frank")
            let gina = try await harness.user("Gina")
            let group = try await alice.makeGroup(joinedBy: [bob, carol, dan, erin, frank, gina])
            let due = try utc("2041-03-04T07:00:00Z")

            // 1. The turn holder leaves: the next member takes the turn at once.
            let first = try await alice.makeRecurringTask(in: group.id, rule: Rule.weekly(), dueAt: due, rotation: [bob, carol, dan])
            let plain = try await alice.makeTask(in: group.id, assignees: [bob])
            try await bob.groups.leave(groupId: group.id)
            let handed = try await alice.tasks.task(id: first.id)
            try Verify.equal(handed.rotation, [bob.id, carol.id, dan.id], "the departed user stays listed until the next spawn")
            try Verify.equal(handed.turnUserId, carol.id, "the next member takes the turn")
            try Verify.equal(handed.assigneeIds, [carol.id], "and is the only assignee")
            try Verify.equal(handed.updatedAt, first.updatedAt, "the handover keeps updatedAt")
            let carolEvent = try await carol.assignment(of: first.id)
            try Verify.equal(carolEvent.assignedBy, nil, "a handover is assigned by nobody")
            try Verify.that(carolEvent.isRotationTurn, "worded « C’est ton tour »")
            let plainNow = try await alice.tasks.task(id: plain.id)
            try Verify.equal(plainNow.assigneeIds, [], "a task without rotation: the assignment is simply gone")

            // 2. The new turn holder leaves too: fewer than 2 members of that rotation are left, so the rotation and the
            // turn are dropped (the rule stays) and the remaining member is assigned by nobody. A listed member who is
            // not the turn holder changes nothing.
            let wrap = try await alice.makeRecurringTask(in: group.id, "Tour", rule: Rule.weekly(), dueAt: due, rotation: [erin, carol])
            var draft = TaskDraft(task: wrap)
            draft.rotation = [carol.id, dan.id, frank.id, erin.id]
            let reordered = try await alice.tasks.update(taskId: wrap.id, draft: draft)
            try Verify.equal(reordered.turnUserId, erin.id, "a new rotation still listing the turn holder keeps the turn")
            try await carol.groups.leave(groupId: group.id)
            let dropped = try await alice.tasks.task(id: first.id)
            try Verify.equal(dropped.rotation, [], "one member of the rotation left: no rotation")
            try Verify.equal(dropped.turnUserId, nil, "and no turn")
            try Verify.equal(dropped.recurrence, first.recurrence, "the rule stays")
            try Verify.equal(dropped.assigneeIds, [dan.id], "the remaining member is the assignee")
            let danEvent = try await dan.assignment(of: first.id)
            try Verify.equal(danEvent.assignedBy, nil, "assigned by nobody")
            try Verify.that(!danEvent.isRotationTurn, "no rotation any more: worded as a new assignment")
            let wrapKept = try await alice.tasks.task(id: wrap.id)
            try Verify.equal(wrapKept, reordered, "carol is listed but it is not her turn: nothing changes")

            // 3. Removal of a turn holder at the end of the list: the turn wraps around and skips a departed member.
            try await alice.groups.removeMember(groupId: group.id, userId: erin.id)
            let wrapped = try await alice.tasks.task(id: wrap.id)
            try Verify.equal(wrapped.turnUserId, dan.id, "erin removed: wrap-around, carol (gone) skipped, dan's turn")
            try Verify.equal(wrapped.assigneeIds, [dan.id], "dan is the only assignee")
            try Verify.equal(wrapped.rotation, reordered.rotation, "the stored rotation is unchanged")

            // 4. A done occurrence is never handed over, nor an occurrence where the leaver is listed but not the turn holder.
            let pair = try await alice.makeRecurringTask(in: group.id, "Paire", rule: Rule.weekly(), dueAt: due, rotation: [dan, alice])
            let (pairDone, pairNext) = try await dan.completeAndReadNext(pair)
            try Verify.equal(pairNext.turnUserId, alice.id, "alice's turn")
            try await dan.groups.leave(groupId: group.id)
            let doneKept = try await alice.tasks.task(id: pair.id)
            var expectedDone = pairDone
            expectedDone.assigneeIds = [] // dan's assignment goes with his membership (v1)
            try Verify.equal(doneKept, expectedDone, "a done occurrence is untouched (it keeps dan's turn)")
            let pairNextKept = try await alice.tasks.task(id: pairNext.id)
            try Verify.equal(pairNextKept, pairNext, "an occurrence where dan is listed but not the turn holder is untouched")
            let lastOne = try await alice.tasks.task(id: wrap.id)
            try Verify.equal(lastOne.rotation, [], "dan was the turn holder and only frank is left: no rotation")
            try Verify.equal(lastOne.assigneeIds, [frank.id], "frank is the assignee")

            // 5. The turn holder deletes their account: handed over at once, never to nobody.
            let gone = try await alice.makeRecurringTask(in: group.id, "Compte", rule: Rule.weekly(), dueAt: due, rotation: [frank, gina, alice])
            try await frank.auth.deleteAccount()
            let afterDeletion = try await alice.tasks.task(id: gone.id)
            try Verify.equal(afterDeletion.turnUserId, gina.id, "the next member takes the turn")
            try Verify.equal(afterDeletion.assigneeIds, [gina.id], "and is the only assignee")
            try Verify.equal(afterDeletion.rotation, [frank.id, gina.id, alice.id], "the deleted account stays listed until the next spawn")
            let ginaEvent = try await gina.assignment(of: gone.id)
            try Verify.equal(ginaEvent.assignedBy, nil, "assigned by nobody")
            try Verify.that(ginaEvent.isRotationTurn, "worded « C’est ton tour »")
        },

        ContractScenario("rotation.editRules") { harness in
            let alice = try await harness.user("Alice")
            let bob = try await harness.user("Bob")
            let carol = try await harness.user("Carol")
            let dan = try await harness.user("Dan")
            let erin = try await harness.user("Erin")
            let group = try await alice.makeGroup(joinedBy: [bob, carol, dan, erin])
            let task = try await bob.makeRecurringTask(
                in: group.id, rule: Rule.weekly(), dueAt: try utc("2041-03-04T07:00:00Z"), rotation: [carol, dan],
                checklist: ["A", "B"]
            )
            let carolRow = try await carol.assignment(of: task.id)

            // A full-draft edit of the v1 fields keeps the rule, the rotation, the turn and the checklist; the draft's
            // assignees are ignored while the task has a rotation (not even checked).
            var draft = TaskDraft(task: task)
            draft.title = Unique.name("Édité")
            draft.priority = .low
            draft.assigneeIds = [dan.id, erin.id, UUID()]
            let edited = try await bob.tasks.update(taskId: task.id, draft: draft)
            try Verify.equal(edited.title, draft.title, "the new title")
            try Verify.equal(edited.recurrence, task.recurrence, "the rule is kept")
            try Verify.equal(edited.rotation, task.rotation, "the rotation is kept")
            try Verify.equal(edited.turnUserId, carol.id, "the turn is kept")
            try Verify.equal(edited.assigneeIds, [carol.id], "the turn holder stays the only assignee")
            try Verify.equal(edited.checklist, task.checklist, "the checklist is kept")
            try Verify.that(edited.updatedAt > task.updatedAt, "a v1 field changed")
            let carolRowKept = try await carol.assignment(of: task.id)
            try Verify.equal(carolRowKept.row, carolRow.row, "the turn holder's row is kept")

            // A new rotation that still lists the turn holder keeps the turn and the row.
            draft = TaskDraft(task: edited)
            draft.rotation = [dan.id, carol.id, erin.id]
            let reordered = try await bob.tasks.update(taskId: task.id, draft: draft)
            try Verify.equal(reordered.rotation, [dan.id, carol.id, erin.id], "the new rotation")
            try Verify.equal(reordered.turnUserId, carol.id, "the turn holder is still listed: the turn is kept")
            try Verify.equal(reordered.assigneeIds, [carol.id], "the turn holder is the only assignee")
            try Verify.equal(reordered.updatedAt, edited.updatedAt, "a rotation-only edit keeps updatedAt")
            let carolRowAgain = try await carol.assignment(of: task.id)
            try Verify.equal(carolRowAgain.row, carolRow.row, "the row is kept")

            // Without the turn holder: the turn goes to rotation[0], assigned by the editor.
            draft = TaskDraft(task: reordered)
            draft.rotation = [erin.id, dan.id]
            let moved = try await alice.tasks.update(taskId: task.id, draft: draft)
            try Verify.equal(moved.turnUserId, erin.id, "rotation[0]'s turn")
            try Verify.equal(moved.assigneeIds, [erin.id], "the new turn holder is the only assignee")
            let erinRow = try await erin.assignment(of: task.id)
            try Verify.equal(erinRow.assignedBy, alice.id, "assigned by the editor")
            let carolGone = try await carol.assignmentIfAny(of: task.id)
            try Verify.that(carolGone == nil, "the former turn holder is no longer assigned")

            // The stored rotation sent back after a listed member left counts as unchanged (not checked again)…
            try await dan.groups.leave(groupId: group.id)
            draft = TaskDraft(task: moved)
            draft.title = Unique.name("Encore")
            let stillOk = try await bob.tasks.update(taskId: task.id, draft: draft)
            try Verify.equal(stillOk.rotation, [erin.id, dan.id], "the stored rotation is kept as is")
            try Verify.equal(stillOk.turnUserId, erin.id, "the turn is kept")
            // … but a new list with that former member is refused.
            try await Verify.fails(with: .invalidRotation, "a new rotation listing a former member") {
                var changed = TaskDraft(task: stillOk)
                changed.rotation = [dan.id, erin.id]
                return try await bob.tasks.update(taskId: task.id, draft: changed)
            }

            // Removing the rotation: the task keeps repeating and the draft's assignees apply again.
            draft = TaskDraft(task: stillOk)
            draft.rotation = []
            draft.assigneeIds = [erin.id, carol.id]
            let noRotation = try await bob.tasks.update(taskId: task.id, draft: draft)
            try Verify.equal(noRotation.rotation, [], "no rotation")
            try Verify.equal(noRotation.turnUserId, nil, "no turn")
            try Verify.equal(noRotation.recurrence, task.recurrence, "the rule stays")
            try Verify.equal(noRotation.assigneeIds, sortedIDs([carol, erin]), "the draft's assignees")
            let erinRowKept = try await erin.assignment(of: task.id)
            try Verify.equal(erinRowKept.row, erinRow.row, "a retained row keeps its metadata")

            // A rotation on a task with assignees: rotation[0]'s turn, the other assignees are removed.
            draft = TaskDraft(task: noRotation)
            draft.rotation = [carol.id, erin.id]
            let rotating = try await bob.tasks.update(taskId: task.id, draft: draft)
            try Verify.equal(rotating.turnUserId, carol.id, "rotation[0]'s turn")
            try Verify.equal(rotating.assigneeIds, [carol.id], "the other assignees are removed")

            // Clearing the rule with the stored rotation sent back: a plain task (rule and rotation cleared).
            draft = TaskDraft(task: rotating)
            draft.recurrence = nil
            let plain = try await bob.tasks.update(taskId: task.id, draft: draft)
            try Verify.equal(plain.recurrence, nil, "no rule")
            try Verify.equal(plain.rotation, [], "no rotation")
            try Verify.equal(plain.turnUserId, nil, "no turn")
            try Verify.equal(plain.seriesId, nil, "no series")
            try Verify.equal(plain.assigneeIds, [carol.id], "the draft's assignees (the former turn holder)")
            try Verify.equal(plain.checklist, task.checklist, "the checklist stays")
            try await Verify.fails(with: .invalidRotation, "a rotation on a plain task") {
                var changed = TaskDraft(task: plain)
                changed.rotation = [carol.id, erin.id]
                return try await bob.tasks.update(taskId: task.id, draft: changed)
            }
            let other = try await bob.makeRecurringTask(
                in: group.id, rule: Rule.weekly(), dueAt: try utc("2041-03-04T07:00:00Z"), rotation: [carol, erin]
            )
            try await Verify.fails(with: .invalidRotation, "a new rotation while clearing the rule") {
                var changed = TaskDraft(task: other)
                changed.recurrence = nil
                changed.rotation = [erin.id, carol.id]
                return try await bob.tasks.update(taskId: other.id, draft: changed)
            }
            let otherKept = try await bob.tasks.task(id: other.id)
            try Verify.equal(otherKept, other, "refused edits change nothing")
        },
    ]
}
