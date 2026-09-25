import Foundation
import TeamTasksCore

// v2 checklists (docs/CONTRACTS-V2.md §3, §4, §5): created with the task, then edited item by item with the rights of
// « change status » (admin, creator, assignee). Adapters must leave the checks after the permission to the server:
// another member adding a blank item gets `.forbidden`, not `.invalidChecklistItem`.
extension ContractScenarios {
    static let checklistScenarios: [ContractScenario] = [
        ContractScenario("checklist.createWithTask") { harness in
            let alice = try await harness.user("Alice")
            let bob = try await harness.user("Bob")
            let eve = try await harness.user("Eve")
            let group = try await alice.makeGroup(joinedBy: [bob])
            _ = try await eve.makeGroup("Eve", joinedBy: [alice])
            func create(title: String = "Liste", assignees: Set<UUID> = [], checklist: [String]) async throws -> TaskItem {
                try await bob.tasks.create(groupId: group.id, draft: TaskDraft(
                    title: title, assigneeIds: assignees, checklist: checklist
                ))
            }

            let task = try await create(title: Unique.name("Courses"), checklist: ["  Premier ", "Deuxième", "Troisième"])
            try Verify.equal(task.checklist.map(\.title), ["Premier", "Deuxième", "Troisième"], "the items, in order, trimmed")
            try Verify.equal(task.checklist.map(\.position), [1, 2, 3], "positions 1…n")
            try Verify.that(task.checklist.allSatisfy { !$0.isDone && $0.doneAt == nil && $0.doneBy == nil }, "unchecked")
            let fetched = try await alice.tasks.task(id: task.id)
            try Verify.equal(fetched, task, "task(id:) returns what create returned")
            let empty = try await create(checklist: [])
            try Verify.equal(empty.checklist, [], "an empty checklist creates no item")

            // Each title (1–200 characters), then the count (at most 30).
            try await Verify.fails(with: .invalidChecklistItem, "a blank item") { try await create(checklist: ["Ok", "  "]) }
            try await Verify.fails(with: .invalidChecklistItem, "a 201-character item") {
                try await create(checklist: [Fixed.text(Limits.checklistItemTitleMax + 1)])
            }
            let tooMany = Array(repeating: "x", count: Limits.checklistItemsMax + 1)
            try await Verify.fails(with: .tooManyChecklistItems, "31 items") { try await create(checklist: tooMany) }
            try await Verify.fails(with: .invalidChecklistItem, "every title before the count") {
                try await create(checklist: tooMany + [Fixed.text(Limits.checklistItemTitleMax + 1)])
            }
            let full = try await create(checklist: Array(repeating: "x", count: Limits.checklistItemsMax))
            try Verify.equal(full.checklist.map(\.position), Array(1...Limits.checklistItemsMax), "30 items are accepted")
            let longest = try await create(checklist: [Fixed.text(Limits.checklistItemTitleMax)])
            try Verify.equal(longest.checklist.first?.title, Fixed.text(Limits.checklistItemTitleMax), "200 characters are accepted")

            // Order (§3): the title first, the assignees (count, then membership) before the checklist.
            try await Verify.fails(with: .invalidTitle, "the title first") { try await create(title: " ", checklist: [""]) }
            try await Verify.fails(with: .tooManyAssignees, "the assignee count before the checklist") {
                try await create(assignees: Set((0...Limits.maxAssignees).map { _ in UUID() }), checklist: [""])
            }
            try await Verify.fails(with: .assigneeNotMember, "the assignees' membership before the checklist") {
                try await create(assignees: [eve.id], checklist: [""])
            }
            let tasks = try await alice.tasks.tasks(groupId: group.id, includeOldDone: true)
            try Verify.equal(Set(tasks.map(\.id)), [task.id, empty.id, full.id, longest.id], "refused creations create nothing")
        },

        ContractScenario("checklist.operations") { harness in
            let alice = try await harness.user("Alice")
            let bob = try await harness.user("Bob")
            let carol = try await harness.user("Carol")
            let group = try await alice.makeGroup(joinedBy: [bob, carol])
            let task = try await bob.tasks.create(groupId: group.id, draft: TaskDraft(
                title: Unique.name("Liste"), assigneeIds: [carol.id], checklist: ["Un", "Deux"]
            ))
            let (un, deux) = (task.checklist[0], task.checklist[1])

            // Add: at the end (the largest position + 1), trimmed; the item as task(id:) reads it.
            let trois = try await carol.tasks.addChecklistItem(taskId: task.id, title: "  Trois  ")
            try Verify.equal(trois.title, "Trois", "the new title (trimmed)")
            try Verify.equal(trois.position, 3, "added at the end")
            try Verify.that(!trois.isDone && trois.doneAt == nil && trois.doneBy == nil, "a new item is unchecked")
            let afterAdd = try await alice.tasks.task(id: task.id)
            try Verify.equal(afterAdd.checklist, [un, deux, trois], "task(id:) lists the items by position")
            // Rename: trimmed, the position kept.
            let renamed = try await alice.tasks.renameChecklistItem(itemId: trois.id, title: " Troisième ")
            try Verify.equal(renamed, ChecklistItem(id: trois.id, title: "Troisième", position: 3), "renamed in place")
            // Check: doneAt and doneBy follow; the same value is a no-op; unchecking clears them.
            let checked = try await carol.tasks.setChecklistItemDone(itemId: un.id, done: true)
            let doneAt = try Verify.unwrap(checked.doneAt, "doneAt of a checked item")
            try Verify.equal(checked, ChecklistItem(id: un.id, title: "Un", position: 1, isDone: true, doneAt: doneAt, doneBy: carol.id), "checked")
            try Verify.that(doneAt > task.createdAt, "doneAt is the time of the check")
            let again = try await bob.tasks.setChecklistItemDone(itemId: un.id, done: true)
            try Verify.equal(again, checked, "checking a checked item changes nothing (doneAt and doneBy kept)")
            let unchecked = try await bob.tasks.setChecklistItemDone(itemId: un.id, done: false)
            try Verify.equal(unchecked, ChecklistItem(id: un.id, title: "Un", position: 1), "unchecking clears doneAt and doneBy")
            let uncheckedAgain = try await bob.tasks.setChecklistItemDone(itemId: un.id, done: false)
            try Verify.equal(uncheckedAgain, unchecked, "unchecking an unchecked item changes nothing")
            // Delete: the other items keep their positions; an addition takes the largest position + 1.
            try await carol.tasks.deleteChecklistItem(itemId: deux.id)
            let afterDelete = try await alice.tasks.task(id: task.id)
            try Verify.equal(afterDelete.checklist.map(\.position), [1, 3], "a gap is left at 2")
            let quatre = try await bob.tasks.addChecklistItem(taskId: task.id, title: "Quatre")
            try Verify.equal(quatre.position, 4, "the largest position + 1")
            try await bob.tasks.deleteChecklistItem(itemId: quatre.id)
            let quatreBis = try await bob.tasks.addChecklistItem(taskId: task.id, title: "Quatre bis")
            try Verify.equal(quatreBis.position, 4, "after deleting the last item, the largest remaining + 1")
            try await Verify.fails(with: .notFound, "a deleted item") {
                try await bob.tasks.setChecklistItemDone(itemId: deux.id, done: true)
            }

            // Titles, then the count.
            try await Verify.fails(with: .invalidChecklistItem, "add: a blank title") {
                try await carol.tasks.addChecklistItem(taskId: task.id, title: " \n ")
            }
            try await Verify.fails(with: .invalidChecklistItem, "add: 201 characters") {
                try await carol.tasks.addChecklistItem(taskId: task.id, title: Fixed.text(Limits.checklistItemTitleMax + 1))
            }
            try await Verify.fails(with: .invalidChecklistItem, "rename: a blank title") {
                try await carol.tasks.renameChecklistItem(itemId: un.id, title: "")
            }
            let almostFull = try await bob.tasks.create(groupId: group.id, draft: TaskDraft(
                title: Unique.name("Pleine"), checklist: Array(repeating: "x", count: Limits.checklistItemsMax - 1)
            ))
            let thirtieth = try await bob.tasks.addChecklistItem(taskId: almostFull.id, title: "Trentième")
            try Verify.equal(thirtieth.position, Limits.checklistItemsMax, "the 30th item")
            try await Verify.fails(with: .invalidChecklistItem, "the title before the count") {
                try await bob.tasks.addChecklistItem(taskId: almostFull.id, title: "  ")
            }
            try await Verify.fails(with: .tooManyChecklistItems, "the 31st item") {
                try await bob.tasks.addChecklistItem(taskId: almostFull.id, title: "Trente et un")
            }
            let final = try await alice.tasks.task(id: task.id)
            try Verify.equal(final.checklist.map(\.title), ["Un", "Troisième", "Quatre bis"], "refused calls change nothing")
        },

        ContractScenario("checklist.rights") { harness in
            let fixture = try await MatrixFixture.make(harness)
            let taskId = fixture.task.id
            // Admin, creator and assignee: every operation (the rights of « change status »).
            for user in [fixture.admin, fixture.creator, fixture.assignee] {
                let item = try await Verify.step("\(user.displayName) adds an item") {
                    try await user.tasks.addChecklistItem(taskId: taskId, title: "Par \(user.displayName)")
                }
                _ = try await Verify.step("\(user.displayName) renames it") {
                    try await user.tasks.renameChecklistItem(itemId: item.id, title: "Renommé")
                }
                let checked = try await Verify.step("\(user.displayName) checks it") {
                    try await user.tasks.setChecklistItemDone(itemId: item.id, done: true)
                }
                try Verify.equal(checked.doneBy, user.id, "doneBy = \(user.displayName)")
                _ = try await Verify.step("\(user.displayName) unchecks it") {
                    try await user.tasks.setChecklistItemDone(itemId: item.id, done: false)
                }
                try await Verify.step("\(user.displayName) deletes it") { try await user.tasks.deleteChecklistItem(itemId: item.id) }
            }
            let kept = try await fixture.creator.tasks.addChecklistItem(taskId: taskId, title: "Reste")

            // Another member: forbidden, before the title is checked.
            let other = fixture.other
            try await Verify.fails(with: .forbidden, "another member adds") { try await other.tasks.addChecklistItem(taskId: taskId, title: "X") }
            try await Verify.fails(with: .forbidden, "another member adds a blank item: the permission first") {
                try await other.tasks.addChecklistItem(taskId: taskId, title: "")
            }
            try await Verify.fails(with: .forbidden, "another member renames") {
                try await other.tasks.renameChecklistItem(itemId: kept.id, title: "X")
            }
            try await Verify.fails(with: .forbidden, "another member renames with a blank title: the permission first") {
                try await other.tasks.renameChecklistItem(itemId: kept.id, title: "")
            }
            try await Verify.fails(with: .forbidden, "another member checks") {
                try await other.tasks.setChecklistItemDone(itemId: kept.id, done: true)
            }
            try await Verify.fails(with: .forbidden, "another member deletes") { try await other.tasks.deleteChecklistItem(itemId: kept.id) }
            // A non-member: not found, before the title is checked.
            let outsider = fixture.outsider
            try await Verify.fails(with: .notFound, "a non-member adds") {
                try await outsider.tasks.addChecklistItem(taskId: taskId, title: "")
            }
            try await Verify.fails(with: .notFound, "a non-member renames") {
                try await outsider.tasks.renameChecklistItem(itemId: kept.id, title: "")
            }
            try await Verify.fails(with: .notFound, "a non-member checks") {
                try await outsider.tasks.setChecklistItemDone(itemId: kept.id, done: true)
            }
            try await Verify.fails(with: .notFound, "a non-member deletes") { try await outsider.tasks.deleteChecklistItem(itemId: kept.id) }
            // Unknown task or item.
            let admin = fixture.admin
            try await Verify.fails(with: .notFound, "add to an unknown task") { try await admin.tasks.addChecklistItem(taskId: UUID(), title: "X") }
            try await Verify.fails(with: .notFound, "rename an unknown item") {
                try await admin.tasks.renameChecklistItem(itemId: UUID(), title: "X")
            }
            try await Verify.fails(with: .notFound, "check an unknown item") {
                try await admin.tasks.setChecklistItemDone(itemId: UUID(), done: true)
            }
            try await Verify.fails(with: .notFound, "delete an unknown item") { try await admin.tasks.deleteChecklistItem(itemId: UUID()) }

            // A former assignee loses the rights; a creator who left can no longer see the task.
            _ = try await fixture.creator.reassign(fixture.task, to: [])
            try await Verify.fails(with: .forbidden, "a former assignee adds") {
                try await fixture.assignee.tasks.addChecklistItem(taskId: taskId, title: "X")
            }
            try await fixture.creator.groups.leave(groupId: fixture.group.id)
            try await Verify.fails(with: .notFound, "a creator who left adds") {
                try await fixture.creator.tasks.addChecklistItem(taskId: taskId, title: "X")
            }
            try await Verify.fails(with: .notFound, "a creator who left checks") {
                try await fixture.creator.tasks.setChecklistItemDone(itemId: kept.id, done: true)
            }
            let final = try await admin.tasks.task(id: taskId)
            try Verify.equal(final.checklist, [kept], "refused calls change nothing")
        },

        ContractScenario("checklist.writesBumpTheGroup") { harness in
            let alice = try await harness.user("Alice")
            let bob = try await harness.user("Bob")
            let group = try await alice.makeGroup(joinedBy: [bob])
            let task = try await alice.tasks.create(groupId: group.id, draft: TaskDraft(
                title: Unique.name("Liste"), assigneeIds: [bob.id], checklist: ["Un"]
            ))
            var last = try await alice.lastActivity(of: group.id)
            let item = try await bob.tasks.addChecklistItem(taskId: task.id, title: "Deux")
            last = try await alice.checkBumped(group.id, since: last, "add_checklist_item")
            _ = try await bob.tasks.renameChecklistItem(itemId: item.id, title: "Deux")
            last = try await alice.checkBumped(group.id, since: last, "rename_checklist_item, even with the same title")
            _ = try await bob.tasks.setChecklistItemDone(itemId: item.id, done: true)
            last = try await alice.checkBumped(group.id, since: last, "checking an item")
            _ = try await bob.tasks.setChecklistItemDone(itemId: item.id, done: true)
            let noOp = try await alice.lastActivity(of: group.id)
            try Verify.equal(noOp, last, "a no-op check writes nothing")
            _ = try await bob.tasks.setChecklistItemDone(itemId: item.id, done: false)
            last = try await alice.checkBumped(group.id, since: last, "unchecking an item")
            try await bob.tasks.deleteChecklistItem(itemId: item.id)
            _ = try await alice.checkBumped(group.id, since: last, "delete_checklist_item")
            let reread = try await alice.tasks.task(id: task.id)
            try Verify.equal(reread.updatedAt, task.updatedAt, "checklist writes do not move the task's updatedAt")
        },
    ]
}
