import Foundation
import TeamTasksCore

// The compatibility rules of docs/CONTRACTS-V2.md §0 as the Swift client observes them. It always sends full drafts
// (`TaskDraft(task:)`): a nil recurrence clears the rule and the rotation; its reads and the rows returned by the RPCs
// carry the v2 columns; v1 fields edited through a full draft never lose v2 data.
extension ContractScenarios {
    static let compatScenarios: [ContractScenario] = [
        ContractScenario("compat.fullDraftEditsKeepV2Data") { harness in
            let alice = try await harness.user("Alice")
            let bob = try await harness.user("Bob")
            let group = try await alice.makeGroup(joinedBy: [bob])
            let task = try await alice.tasks.create(groupId: group.id, draft: TaskDraft(
                title: Unique.name("Loyer"), details: "Virement", priority: .high, dueAt: try utc("2041-01-31T17:00:00Z"),
                assigneeIds: [bob.id], recurrence: Rule.monthly(), checklist: ["Relevé", "Virement"]
            ))
            let (done, next) = try await bob.completeAndReadNext(task)
            _ = try await bob.tasks.setChecklistItemDone(itemId: next.checklist[0].id, done: true)
            let pending = try await alice.tasks.task(id: next.id)

            // The v1 fields of the pending occurrence change; its rule (month day 31), series, checklist and assignees stay.
            var draft = TaskDraft(task: pending)
            draft.title = Unique.name("Loyer v1")
            draft.details = "Édité"
            draft.priority = .low
            let edited = try await alice.tasks.update(taskId: next.id, draft: draft)
            var expected = pending
            expected.title = draft.title
            expected.details = "Édité"
            expected.priority = .low
            expected.updatedAt = edited.updatedAt
            try Verify.equal(edited, expected, "only the v1 fields changed")
            try Verify.that(edited.updatedAt > pending.updatedAt, "updatedAt moves with the v1 fields")
            try Verify.equal(edited.recurrence?.monthDay, 31, "the month day of the series is kept")
            // The done occurrence keeps its completion and its link to the next one.
            var doneDraft = TaskDraft(task: done)
            doneDraft.priority = .medium
            let doneEdited = try await alice.tasks.update(taskId: task.id, draft: doneDraft)
            try Verify.equal(doneEdited.completedBy, bob.id, "completedBy is kept")
            try Verify.equal(doneEdited.completedAt, done.completedAt, "completedAt is kept")
            try Verify.equal(doneEdited.nextOccurrenceId, next.id, "nextOccurrenceId is kept")
            try Verify.equal(doneEdited.recurrence, done.recurrence, "the rule is kept")
            let series = try await alice.tasks.tasks(groupId: group.id, includeOldDone: true).filter { $0.seriesId == task.id }
            try Verify.equal(Set(series.map(\.id)), [task.id, next.id], "edits never spawn")
        },

        ContractScenario("compat.clearingTheDueDate") { harness in
            let alice = try await harness.user("Alice")
            let bob = try await harness.user("Bob")
            let carol = try await harness.user("Carol")
            let group = try await alice.makeGroup(joinedBy: [bob, carol])
            let task = try await alice.makeRecurringTask(
                in: group.id, rule: Rule.weekly(weekdays: [1, 4]), dueAt: try utc("2041-03-04T07:00:00Z"), rotation: [bob, carol],
                checklist: ["Un", "Deux"]
            )
            let bobRow = try await bob.assignment(of: task.id)

            // A rule needs a due date.
            try await Verify.fails(with: .recurrenceNeedsDueDate, "clearing the due date under a rule") {
                var draft = TaskDraft(task: task)
                draft.dueAt = nil
                return try await alice.tasks.update(taskId: task.id, draft: draft)
            }
            let unchanged = try await alice.tasks.task(id: task.id)
            try Verify.equal(unchanged, task, "a refused edit changes nothing")

            // Clearing both: a plain task; the checklist stays and the draft's assignees apply (the former turn holder
            // keeps his row).
            var draft = TaskDraft(task: task)
            draft.dueAt = nil
            draft.recurrence = nil
            let plain = try await alice.tasks.update(taskId: task.id, draft: draft)
            try Verify.equal(plain.dueAt, nil, "no due date")
            try Verify.equal(plain.recurrence, nil, "no rule")
            try Verify.equal(plain.rotation, [], "no rotation")
            try Verify.equal(plain.turnUserId, nil, "no turn")
            try Verify.equal(plain.seriesId, nil, "no series")
            try Verify.equal(plain.checklist, task.checklist, "the checklist stays")
            try Verify.equal(plain.assigneeIds, [bob.id], "the draft's assignees: the former turn holder")
            try Verify.that(plain.updatedAt > task.updatedAt, "the due date changed")
            let bobRowKept = try await bob.assignment(of: task.id)
            try Verify.equal(bobRowKept.row, bobRow.row, "the same assignment row")
            try Verify.that(!bobRowKept.taskHasRotation, "the task no longer has a rotation")
            let plainDone = try await bob.tasks.setStatus(taskId: task.id, status: .done)
            try Verify.equal(plainDone.nextOccurrenceId, nil, "completing the plain task spawns nothing")

            // A done occurrence: its next occurrence id stays and the pending occurrence is not affected; the draft's
            // assignees then apply as for any plain task.
            let daily = try await alice.makeRecurringTask(
                in: group.id, "Jour", rule: Rule.daily(tz: Zone.utc), dueAt: try utc("2041-03-04T07:00:00Z"), assignees: [bob]
            )
            let (dailyDone, dailyNext) = try await bob.completeAndReadNext(daily)
            var doneDraft = TaskDraft(task: dailyDone)
            doneDraft.dueAt = nil
            doneDraft.recurrence = nil
            doneDraft.assigneeIds = [carol.id]
            let doneCleared = try await alice.tasks.update(taskId: daily.id, draft: doneDraft)
            try Verify.equal(doneCleared.status, .done, "still done")
            try Verify.equal(doneCleared.recurrence, nil, "no rule")
            try Verify.equal(doneCleared.nextOccurrenceId, dailyNext.id, "nextOccurrenceId is kept")
            try Verify.equal(doneCleared.assigneeIds, [carol.id], "the draft's assignees")
            let pendingKept = try await alice.tasks.task(id: dailyNext.id)
            try Verify.equal(pendingKept, dailyNext, "the pending occurrence of the series is not affected")
        },

        ContractScenario("compat.readsAndRowsCarryV2Columns") { harness in
            let alice = try await harness.user("Alice")
            let bob = try await harness.user("Bob")
            let group = try await alice.makeGroup("Coloc", color: .teal, emoji: "🧹", joinedBy: [bob])
            let task = try await alice.makeRecurringTask(
                in: group.id, rule: Rule.weekly(), dueAt: try utc("2041-03-04T07:00:00Z"), rotation: [bob, alice], checklist: ["Un"]
            )
            let fetched = try await bob.tasks.task(id: task.id)
            try Verify.equal(fetched, task, "create returns the row with its v2 columns")
            let listed = try await bob.tasks.tasks(groupId: group.id, includeOldDone: false)
            try Verify.equal(listed, [task], "the group's tasks carry the v2 columns")
            let bobTasks = try await bob.tasks.myTasks(includeDone: false)
            let mine = try Verify.unwrap(bobTasks.first { $0.id == task.id }, "the task in bob's tasks")
            try Verify.equal(mine.groupName, group.name, "myTasks: the group's name")
            try Verify.equal(mine.groupColor, .teal, "myTasks: the group's color")
            try Verify.equal(mine.groupEmoji, "🧹", "myTasks: the group's emoji")
            try Verify.equal(mine.withoutPersonalFields, task, "myTasks returns the same task")
            let bobEvent = try await bob.assignment(of: task.id)
            try Verify.that(bobEvent.taskHasRotation, "assignments(since:): the task has a rotation")

            let done = try await bob.tasks.setStatus(taskId: task.id, status: .done)
            let doneFetched = try await alice.tasks.task(id: task.id)
            try Verify.equal(doneFetched, done, "setStatus returns the row with completedBy and nextOccurrenceId")
            let nextId = try Verify.unwrap(done.nextOccurrenceId, "the next occurrence")
            let aliceTasks = try await alice.tasks.myTasks(includeDone: false)
            let aliceTurn = try Verify.unwrap(aliceTasks.first { $0.id == nextId }, "alice's turn in her tasks")
            try Verify.equal(aliceTurn.myAssignedBy, nil, "a turn handed out by the server")
            try Verify.equal(aliceTurn.groupColor, .teal, "myTasks: the group's color")
            let aliceEvent = try await alice.assignment(of: nextId)
            try Verify.that(aliceEvent.isRotationTurn, "a rotation turn")
            var draft = TaskDraft(task: aliceTurn.withoutPersonalFields)
            draft.title = Unique.name("Édité")
            let updated = try await alice.tasks.update(taskId: nextId, draft: draft)
            let updatedFetched = try await bob.tasks.task(id: nextId)
            try Verify.equal(updatedFetched, updated, "update returns the row with its v2 columns")

            // A plain task in a plain group has no v2 values.
            let plainGroup = try await alice.makeGroup("Simple", joinedBy: [bob])
            let plain = try await alice.makeTask(in: plainGroup.id, assignees: [bob])
            try Verify.equal(plain.recurrence, nil, "no rule")
            try Verify.equal(plain.rotation, [], "no rotation")
            try Verify.equal(plain.checklist, [], "no checklist")
            let plainMine = try await bob.tasks.myTasks(includeDone: false).first { $0.id == plain.id }
            try Verify.equal(plainMine?.groupColor, nil, "an automatic color")
            try Verify.equal(plainMine?.groupEmoji, nil, "no emoji")
            let plainEvent = try await bob.assignment(of: plain.id)
            try Verify.that(!plainEvent.taskHasRotation, "no rotation")
        },
    ]
}
