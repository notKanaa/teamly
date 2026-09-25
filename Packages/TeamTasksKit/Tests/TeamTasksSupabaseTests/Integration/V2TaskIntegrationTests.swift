import Foundation
import TeamTasksContract
import TeamTasksCore
import Testing
@testable import TeamTasksSupabase

extension IntegrationTests {
    /// Recurring tasks, rotations, checklists, reads and the weekly recap against the local stack (docs/CONTRACTS-V2.md
    /// §3, §5, §6, §8, §10).
    @Suite struct V2TaskIntegrationTests {
        static let epoch = Date(timeIntervalSince1970: 0)

        /// The whole life of a rotating series: create (rule, rotation, checklist), edit, check an item, complete the
        /// turn; the next occurrence, the turn handed out by the server, the reads and the recap.
        @Test(.timeLimit(.minutes(1)))
        func rotatingSeriesWithAChecklist() async throws {
            let alice = try await V2IT.user("Alice Série")
            let bob = try await V2IT.user("Bob Série")
            let carol = try await V2IT.user("Carol Série")
            let group = try await V2IT.group(of: alice, color: .teal, emoji: "🧽", joinedBy: [bob, carol])
            let draft = TaskDraft(
                title: " Vaisselle ", details: "Le soir", priority: .high, dueAt: V2IT.monday, assigneeIds: [carol.id],
                recurrence: V2IT.weekly, rotation: [bob.id, alice.id], checklist: ["Laver", " Essuyer ", "Ranger"]
            )
            let created = try await alice.tasks.create(groupId: group.id, draft: draft)
            #expect(created.title == "Vaisselle")
            #expect(created.recurrence == RecurrenceRule(frequency: .weekly, weekdays: [1, 3, 5], timeZoneId: "Europe/Paris"))
            #expect(created.rotation == [bob.id, alice.id])
            #expect(created.turnUserId == bob.id)
            #expect(created.assigneeIds == [bob.id], "the turn holder, not the draft's assignees")
            #expect(created.seriesId == created.id)
            #expect(created.nextOccurrenceId == nil && created.completedBy == nil)
            #expect(created.checklist.map(\.title) == ["Laver", "Essuyer", "Ranger"])
            #expect(created.checklist.map(\.position) == [1, 2, 3])
            #expect(created.checklist.allSatisfy { !$0.isDone && $0.doneAt == nil && $0.doneBy == nil })
            #expect(try await bob.tasks.task(id: created.id) == created, "create returns what a read returns")
            #expect(try await carol.tasks.tasks(groupId: group.id, includeOldDone: false) == [created])

            // Bob's first turn was given by Alice: not a « C’est ton tour ».
            let first = try #require(try await bob.tasks.assignments(since: Self.epoch).first { $0.taskId == created.id })
            #expect(first.assignedBy == alice.id && first.taskHasRotation && !first.isRotationTurn)

            // A full edit from the task keeps the rule and the rotation (the stored list sent back is unchanged).
            let edited = try await alice.tasks.update(taskId: created.id, draft: TaskDraft(task: created).renamed("Vaisselle du soir"))
            #expect(edited.title == "Vaisselle du soir")
            #expect(edited.recurrence == created.recurrence && edited.rotation == created.rotation && edited.turnUserId == bob.id)
            #expect(edited.assigneeIds == [bob.id] && edited.checklist == created.checklist)
            #expect(try await carol.tasks.task(id: created.id) == edited, "update returns what a read returns")

            // Bob checks an item (the same value again changes nothing), then completes his turn.
            let laver = created.checklist[0]
            let checked = try await bob.tasks.setChecklistItemDone(itemId: laver.id, done: true)
            #expect(checked.isDone && checked.doneBy == bob.id && checked.id == laver.id)
            let doneAt = try #require(checked.doneAt)
            #expect(try await bob.tasks.setChecklistItemDone(itemId: laver.id, done: true) == checked)
            let done = try await bob.tasks.setStatus(taskId: created.id, status: .done)
            #expect(done.status == .done && done.completedBy == bob.id)
            let nextId = try #require(done.nextOccurrenceId)
            #expect(done.checklist.first?.doneAt == doneAt)
            #expect(try await alice.tasks.task(id: created.id) == done, "setStatus returns what a read returns")

            // The next occurrence: Wednesday, Alice's turn, the checklist copied unchecked.
            let next = try await alice.tasks.task(id: nextId)
            #expect(next.dueAt == V2IT.monday.addingTimeInterval(2 * 86_400))
            #expect(next.status == .todo && next.completedBy == nil && next.nextOccurrenceId == nil)
            #expect(next.recurrence == created.recurrence)
            #expect(next.rotation == [bob.id, alice.id])
            #expect(next.turnUserId == alice.id && next.assigneeIds == [alice.id])
            #expect(next.seriesId == created.id)
            #expect(next.createdBy == alice.id, "the series creator")
            #expect(next.title == "Vaisselle du soir" && next.details == "Le soir" && next.priority == .high)
            #expect(next.checklist.map(\.title) == ["Laver", "Essuyer", "Ranger"])
            #expect(next.checklist.map(\.position) == [1, 2, 3])
            #expect(next.checklist.allSatisfy { !$0.isDone })
            #expect(Set(next.checklist.map(\.id)).isDisjoint(with: created.checklist.map(\.id)))

            // Alice's turn was handed out by the server: « C’est ton tour ».
            let turn = try #require(try await alice.tasks.assignments(since: Self.epoch).first { $0.taskId == nextId })
            #expect(turn.assignedBy == nil && turn.taskHasRotation && turn.isRotationTurn)
            #expect(turn.taskTitle == "Vaisselle du soir" && turn.groupName == group.group.name)
            #expect(turn.dueAt == next.dueAt)

            // In Alice's tasks, with the group's appearance; otherwise the task itself.
            let mine = try #require(try await alice.tasks.myTasks(includeDone: false).first { $0.id == nextId })
            #expect(mine.groupName == group.group.name && mine.groupColor == .teal && mine.groupEmoji == "🧽")
            #expect(mine.myAssignedBy == nil && mine.myAssignedAt == turn.assignedAt)
            var plain = mine
            plain.myAssignedAt = nil
            plain.myAssignedBy = nil
            plain.groupName = nil
            plain.groupColor = nil
            plain.groupEmoji = nil
            #expect(plain == next)

            // The weekly recap: `since` is inclusive, to the microsecond; non-members read nothing.
            let completedAt = try #require(done.completedAt)
            let recap = try await carol.tasks.completions(groupId: group.id, since: completedAt)
            #expect(recap == [TaskCompletion(taskId: created.id, completedBy: bob.id, completedAt: completedAt)])
            #expect(try await carol.tasks.completions(groupId: group.id, since: V2IT.microsecond(after: completedAt)).isEmpty)
            let eve = try await V2IT.user("Eve Série")
            #expect(try await eve.tasks.completions(groupId: group.id, since: Self.epoch).isEmpty)
        }

        /// `update` is a full edit of the rule and the rotation (docs/CONTRACTS-V2.md §5).
        @Test(.timeLimit(.minutes(1)))
        func fullEditsOfTheRuleAndTheRotation() async throws {
            let alice = try await V2IT.user("Alice Édition")
            let bob = try await V2IT.user("Bob Édition")
            let carol = try await V2IT.user("Carol Édition")
            let eve = try await V2IT.user("Eve Édition")
            let group = try await V2IT.group(of: alice, joinedBy: [bob, carol])
            func rotating(_ title: String) async throws -> TaskItem {
                try await alice.tasks.create(groupId: group.id, draft: TaskDraft(
                    title: title, dueAt: V2IT.monday, recurrence: V2IT.daily, rotation: [bob.id, carol.id]
                ))
            }

            // A new rotation keeps the turn holder while still listed…
            let task = try await rotating("Poubelles")
            #expect(task.turnUserId == bob.id)
            var draft = TaskDraft(task: task)
            draft.rotation = [carol.id, bob.id, alice.id]
            let reordered = try await alice.tasks.update(taskId: task.id, draft: draft)
            #expect(reordered.rotation == [carol.id, bob.id, alice.id])
            #expect(reordered.turnUserId == bob.id && reordered.assigneeIds == [bob.id])
            // …else the turn goes to its first member, the only assignee.
            draft = TaskDraft(task: reordered)
            draft.rotation = [carol.id, alice.id]
            let handed = try await alice.tasks.update(taskId: task.id, draft: draft)
            #expect(handed.turnUserId == carol.id && handed.assigneeIds == [carol.id])

            // An empty rotation removes it (the rule stays); the assignees apply again.
            draft = TaskDraft(task: handed)
            draft.rotation = []
            draft.assigneeIds = [alice.id, bob.id]
            let unrotated = try await alice.tasks.update(taskId: task.id, draft: draft)
            #expect(unrotated.rotation.isEmpty && unrotated.turnUserId == nil)
            #expect(unrotated.recurrence == V2IT.daily)
            let aliceAndBob = [alice.id, bob.id].sorted(by: { $0.uuidString < $1.uuidString })
            #expect(unrotated.assigneeIds == aliceAndBob)

            // Refused edits: a rotation with a non-member (server), a rule without due date (client).
            draft = TaskDraft(task: unrotated)
            draft.rotation = [bob.id, eve.id]
            await #expect(throws: AppError.invalidRotation) { try await alice.tasks.update(taskId: task.id, draft: draft) }
            draft = TaskDraft(task: unrotated)
            draft.dueAt = nil
            await #expect(throws: AppError.recurrenceNeedsDueDate) { try await alice.tasks.update(taskId: task.id, draft: draft) }
            draft = TaskDraft(task: unrotated)
            draft.rotation = [bob.id]
            await #expect(throws: AppError.invalidRotation) { try await alice.tasks.update(taskId: task.id, draft: draft) }
            #expect(try await alice.tasks.task(id: task.id) == unrotated, "refused edits change nothing")

            // No rule (sent as `{}`) with the stored rotation sent back: both are removed; the turn holder stays assigned.
            let second = try await rotating("Aspirateur")
            draft = TaskDraft(task: second)
            draft.recurrence = nil
            let plain = try await alice.tasks.update(taskId: second.id, draft: draft)
            #expect(plain.recurrence == nil && plain.rotation.isEmpty && plain.turnUserId == nil && plain.seriesId == nil)
            #expect(plain.assigneeIds == [bob.id])
            #expect(try await carol.tasks.task(id: second.id) == plain)
            // …but a new rotation without a rule is refused (only the server can tell it from the stored one).
            draft = TaskDraft(task: plain)
            draft.rotation = [bob.id, carol.id]
            await #expect(throws: AppError.invalidRotation) { try await alice.tasks.update(taskId: second.id, draft: draft) }

            // A listed member who left (not the turn holder): the stored list sent back is kept without checks.
            let third = try await rotating("Litière")
            try await carol.groups.leave(groupId: group.id)
            let current = try await alice.tasks.task(id: third.id)
            #expect(current.rotation == [bob.id, carol.id])
            let kept = try await alice.tasks.update(taskId: third.id, draft: TaskDraft(task: current).renamed("Litière du chat"))
            #expect(kept.title == "Litière du chat")
            #expect(kept.rotation == [bob.id, carol.id] && kept.turnUserId == bob.id)
        }

        /// The server's month day comes back in the rule and is kept by the edits and the next occurrence.
        @Test(.timeLimit(.minutes(1)))
        func monthlyRuleKeepsItsMonthDay() async throws {
            let alice = try await V2IT.user("Alice Loyer")
            let group = try await V2IT.group(of: alice)
            let monthly = RecurrenceRule(frequency: .monthly, timeZoneId: "Europe/Paris")
            let task = try await alice.tasks.create(groupId: group.id, draft: TaskDraft(
                title: "Loyer", dueAt: V2IT.january31, assigneeIds: [alice.id], recurrence: monthly
            ))
            let stored = RecurrenceRule(frequency: .monthly, timeZoneId: "Europe/Paris", monthDay: 31)
            #expect(task.recurrence == stored)
            #expect(task.assigneeIds == [alice.id])
            let edited = try await alice.tasks.update(taskId: task.id, draft: TaskDraft(task: task).renamed("Loyer du mois"))
            #expect(edited.recurrence == stored, "sent without its month day, the rule keeps it")
            let done = try await alice.tasks.setStatus(taskId: task.id, status: .done)
            let next = try await alice.tasks.task(id: try #require(done.nextOccurrenceId))
            let february28 = V2IT.january31.addingTimeInterval(28 * 86_400)
            #expect(next.dueAt == february28)
            #expect(next.dueAt == NextDueCalculator.nextDueDate(after: V2IT.january31, rule: stored, now: Date()))
            #expect(next.recurrence == stored, "no drift after a short month")
            #expect(next.assigneeIds == [alice.id], "the same assignees (a continuation)")
            #expect(try await alice.tasks.assignments(since: Self.epoch).isEmpty, "continuations are not assignments by others")
        }

        /// A JSON-null recurrence: `p_recurrence: null` (a v1 client) keeps the rule, the adapter's `{}` removes it; a
        /// JSON-null key inside a rule counts as absent (a rule without weekdays is sent with `"weekdays": null`); the
        /// JSON-null columns of a plain task read as no rule.
        @Test(.timeLimit(.minutes(1)))
        func jsonNullRecurrence() async throws {
            let context = try IntegrationEnvironment.makeContext()
            let alice = try await SupabaseHarness.signUp(displayName: "Alice Null", services: SupabaseBackend.services(for: context))
            let group = try await V2IT.group(of: alice)
            let task = try await alice.tasks.create(
                groupId: group.id, draft: TaskDraft(title: "Arroser", dueAt: V2IT.monday, assigneeIds: [alice.id], recurrence: V2IT.daily)
            )
            #expect(task.recurrence == V2IT.daily && task.recurrence?.weekdays == nil)

            let v1Edit: [String: JSONValue] = [
                "p_task_id": .uuid(task.id), "p_title": .string("Arroser les plantes"), "p_details": .null,
                "p_priority": .string("medium"), "p_due_at": .timestamp(V2IT.monday), "p_assignee_ids": .null,
                "p_recurrence": .null, "p_rotation": .null,
            ]
            _ = try await context.rest.send { _ in RestQuery.rpc("update_task", v1Edit) }
            let kept = try await alice.tasks.task(id: task.id)
            #expect(kept.title == "Arroser les plantes")
            #expect(kept.recurrence == V2IT.daily && kept.seriesId == task.id)
            #expect(kept.assigneeIds == [alice.id], "NULL assignee ids keep the assignees")

            var draft = TaskDraft(task: kept)
            draft.recurrence = nil
            let removed = try await alice.tasks.update(taskId: task.id, draft: draft)
            #expect(removed.recurrence == nil && removed.seriesId == nil)
            let listed = try await alice.tasks.tasks(groupId: group.id, includeOldDone: true)
            #expect(listed == [removed])
        }

        @Test(.timeLimit(.minutes(1)))
        func checklistOperations() async throws {
            let alice = try await V2IT.user("Alice Liste")
            let bob = try await V2IT.user("Bob Liste")
            let carol = try await V2IT.user("Carol Liste")
            let eve = try await V2IT.user("Eve Liste")
            let group = try await V2IT.group(of: alice, joinedBy: [bob, carol])
            let task = try await alice.tasks.create(groupId: group.id, draft: TaskDraft(title: "Courses", assigneeIds: [bob.id]))
            #expect(task.checklist.isEmpty)

            // Added at the end (position = the largest one + 1), the title trimmed; the assignee may manage it.
            let lait = try await bob.tasks.addChecklistItem(taskId: task.id, title: "  Lait ")
            #expect(lait.title == "Lait" && lait.position == 1 && !lait.isDone && lait.doneAt == nil)
            let pain = try await bob.tasks.addChecklistItem(taskId: task.id, title: "Pain")
            #expect(pain.position == 2)
            let oeufs = try await alice.tasks.addChecklistItem(taskId: task.id, title: "Œufs")
            #expect(oeufs.position == 3)
            let renamed = try await bob.tasks.renameChecklistItem(itemId: pain.id, title: " Pain complet ")
            #expect(renamed.title == "Pain complet" && renamed.position == 2 && renamed.id == pain.id)
            let checked = try await bob.tasks.setChecklistItemDone(itemId: lait.id, done: true)
            #expect(checked.isDone && checked.doneBy == bob.id && checked.doneAt != nil)
            let unchecked = try await alice.tasks.setChecklistItemDone(itemId: lait.id, done: false)
            #expect(!unchecked.isDone && unchecked.doneAt == nil && unchecked.doneBy == nil)

            // Deleted: the others keep their positions, the next one goes after the largest.
            try await alice.tasks.deleteChecklistItem(itemId: pain.id)
            let beurre = try await bob.tasks.addChecklistItem(taskId: task.id, title: "Beurre")
            #expect(beurre.position == 4)
            let read = try await carol.tasks.task(id: task.id)
            #expect(read.checklist.map(\.title) == ["Lait", "Œufs", "Beurre"])
            #expect(read.checklist.map(\.position) == [1, 3, 4])
            #expect(read.checklist.map(\.id) == [lait.id, oeufs.id, beurre.id])

            // Rights of « change status »: another member cannot; a non-member does not see the task; unknown ids.
            await #expect(throws: AppError.forbidden) { try await carol.tasks.addChecklistItem(taskId: task.id, title: "Pirate") }
            await #expect(throws: AppError.forbidden) { try await carol.tasks.renameChecklistItem(itemId: lait.id, title: "Pirate") }
            await #expect(throws: AppError.forbidden) { try await carol.tasks.setChecklistItemDone(itemId: lait.id, done: true) }
            await #expect(throws: AppError.forbidden) { try await carol.tasks.deleteChecklistItem(itemId: lait.id) }
            await #expect(throws: AppError.notFound) { try await eve.tasks.addChecklistItem(taskId: task.id, title: "Intrus") }
            await #expect(throws: AppError.notFound) { try await eve.tasks.setChecklistItemDone(itemId: lait.id, done: true) }
            await #expect(throws: AppError.notFound) { try await eve.tasks.deleteChecklistItem(itemId: lait.id) }
            await #expect(throws: AppError.notFound) { try await alice.tasks.renameChecklistItem(itemId: UUID(), title: "Fantôme") }
            await #expect(throws: AppError.notFound) { try await alice.tasks.addChecklistItem(taskId: UUID(), title: "Fantôme") }
            // Titles are checked by the server, after the task (or item) and the rights (§3).
            await #expect(throws: AppError.invalidChecklistItem) { try await alice.tasks.addChecklistItem(taskId: task.id, title: " \u{3000} ") }
            await #expect(throws: AppError.invalidChecklistItem) {
                try await alice.tasks.renameChecklistItem(itemId: lait.id, title: String(repeating: "x", count: 201))
            }
            await #expect(throws: AppError.invalidChecklistItem) { try await bob.tasks.addChecklistItem(taskId: task.id, title: "La\u{0}it") }
            await #expect(throws: AppError.invalidChecklistItem) { try await bob.tasks.renameChecklistItem(itemId: lait.id, title: "\u{0}") }
            await #expect(throws: AppError.forbidden) { try await carol.tasks.addChecklistItem(taskId: task.id, title: " ") }
            await #expect(throws: AppError.forbidden) { try await carol.tasks.renameChecklistItem(itemId: lait.id, title: "\u{0}") }
            await #expect(throws: AppError.notFound) { try await eve.tasks.addChecklistItem(taskId: task.id, title: "") }
            await #expect(throws: AppError.notFound) { try await eve.tasks.renameChecklistItem(itemId: lait.id, title: "") }
            #expect(try await alice.tasks.task(id: task.id).checklist == read.checklist, "refused operations change nothing")

            // At most 30 items.
            for index in 1...(Limits.checklistItemsMax - read.checklist.count) {
                _ = try await alice.tasks.addChecklistItem(taskId: task.id, title: "Article \(index)")
            }
            await #expect(throws: AppError.tooManyChecklistItems) { try await bob.tasks.addChecklistItem(taskId: task.id, title: "Un de trop") }
            #expect(try await alice.tasks.task(id: task.id).checklist.count == Limits.checklistItemsMax)
        }

        /// The checklist of a new task is checked by the server, after its membership rules (TeamTasksCore v2 API note 3):
        /// rotation members, then the assignees, then each title, then the count.
        @Test(.timeLimit(.minutes(1)))
        func newChecklistIsCheckedAfterTheMembershipRules() async throws {
            let alice = try await V2IT.user("Alice Ordre")
            let bob = try await V2IT.user("Bob Ordre")
            let eve = try await V2IT.user("Eve Ordre")
            let group = try await V2IT.group(of: alice, joinedBy: [bob])
            func create(_ draft: TaskDraft) async throws -> TaskItem {
                try await alice.tasks.create(groupId: group.id, draft: draft)
            }
            let blank = ["Lait", "   "]
            await #expect(throws: AppError.assigneeNotMember) { try await create(TaskDraft(title: "T", assigneeIds: [eve.id], checklist: blank)) }
            await #expect(throws: AppError.assigneeNotMember) {
                try await create(TaskDraft(title: "T", assigneeIds: [eve.id], checklist: ["La\u{0}it"]))
            }
            await #expect(throws: AppError.invalidRotation) {
                try await create(TaskDraft(title: "T", dueAt: V2IT.monday, recurrence: V2IT.daily, rotation: [bob.id, eve.id], checklist: blank))
            }
            await #expect(throws: AppError.invalidChecklistItem) { try await create(TaskDraft(title: "T", assigneeIds: [bob.id], checklist: blank)) }
            await #expect(throws: AppError.invalidChecklistItem) { try await create(TaskDraft(title: "T", checklist: ["La\u{0}it"])) }
            await #expect(throws: AppError.invalidChecklistItem) {
                try await create(TaskDraft(title: "T", checklist: [String(repeating: "x", count: 201)]))
            }
            await #expect(throws: AppError.invalidChecklistItem, "every title before the count") {
                try await create(TaskDraft(title: "T", checklist: Array(repeating: " ", count: 31)))
            }
            await #expect(throws: AppError.tooManyChecklistItems) {
                try await create(TaskDraft(title: "T", checklist: (1...31).map { "Article \($0)" }))
            }
            #expect(try await alice.tasks.tasks(groupId: group.id, includeOldDone: true).isEmpty, "refused creations create nothing")

            let titles = (1...Limits.checklistItemsMax).map { "Article \($0)" }
            let full = try await create(TaskDraft(title: "Liste", checklist: titles))
            #expect(full.checklist.map(\.title) == titles)
            #expect(full.checklist.map(\.position) == Array(1...Limits.checklistItemsMax))
            #expect(try await bob.tasks.task(id: full.id) == full)
        }
    }

    /// Every v2 error code from the real server, mapped by the adapters' client (docs/CONTRACTS-V2.md §3). Codes the
    /// adapters' own checks never let through (a typed color, an emoji refused on the client, a v1 call) are sent as raw
    /// requests on the same client.
    @Suite struct V2ErrorMappingIntegrationTests {
        @Test(.timeLimit(.minutes(1)))
        func everyV2ErrorCode() async throws {
            let context = try IntegrationEnvironment.makeContext()
            let alice = try await SupabaseHarness.signUp(displayName: "Alice Erreurs", services: SupabaseBackend.services(for: context))
            let bob = try await V2IT.user("Bob Erreurs")
            let group = try await V2IT.group(of: alice, joinedBy: [bob])
            let rest = context.rest
            func call(_ request: RestRequest) async throws {
                _ = try await rest.send { _ in request }
            }
            func patch(_ path: String, id: UUID, _ fields: [String: JSONValue]) -> RestRequest {
                RestRequest(
                    method: .patch, path: path, query: [RestRequest.QueryItem(name: "id", value: "eq.\(RestQuery.uuid(id))")],
                    body: .object(fields), prefer: "return=representation"
                )
            }
            let groupId = JSONValue.uuid(group.id)
            let due = JSONValue.timestamp(V2IT.monday)

            // invalid_color, invalid_emoji → .invalidAppearance
            await #expect(throws: AppError.invalidAppearance) {
                try await call(RestQuery.rpc("create_group", ["p_name": .string("G"), "p_color": .string("Coral"), "p_emoji": .null]))
            }
            await #expect(throws: AppError.invalidAppearance) {
                try await call(RestQuery.rpc("set_group_appearance", ["p_group_id": groupId, "p_color": .string(""), "p_emoji": .null]))
            }
            await #expect(throws: AppError.invalidAppearance) { try await call(patch("profiles", id: alice.id, ["avatar_color": .string("teal ")])) }
            await #expect(throws: AppError.invalidAppearance) {
                try await call(RestQuery.rpc("set_group_appearance", ["p_group_id": groupId, "p_color": .null, "p_emoji": .string("a b")]))
            }
            await #expect(throws: AppError.invalidAppearance) { try await call(patch("profiles", id: alice.id, ["avatar_emoji": .string("\u{7F}")])) }

            // invalid_recurrence → .invalidRecurrence
            let rules: [JSONValue] = [
                .object(["freq": .string("yearly"), "tz": .string("UTC")]),
                .object(["freq": .string("daily"), "tz": .string("Europe/Paris"), "until": .string("2032-01-01")]),
                .object(["freq": .string("daily"), "interval": .string("2"), "tz": .string("Europe/Paris")]),
                .object(["freq": .string("daily"), "tz": .string("Zulu/Nowhere")]),
            ]
            for rule in rules {
                await #expect(throws: AppError.invalidRecurrence) {
                    try await call(RestQuery.rpc("create_task", ["p_group_id": groupId, "p_title": .string("R"), "p_due_at": due, "p_recurrence": rule]))
                }
            }

            // recurrence_requires_due_date → .recurrenceNeedsDueDate: a direct PATCH clearing the due date of a series.
            let series = try await alice.tasks.create(groupId: group.id, draft: TaskDraft(
                title: "Série", dueAt: V2IT.monday, recurrence: V2IT.daily, rotation: [alice.id, bob.id]
            ))
            await #expect(throws: AppError.recurrenceNeedsDueDate) { try await call(patch("tasks", id: series.id, ["due_at": .null])) }

            // invalid_rotation → .invalidRotation: a v1 `set_task_assignees` on a rotating task; a non-member in a rotation.
            await #expect(throws: AppError.invalidRotation) {
                try await call(RestQuery.rpc("set_task_assignees", ["p_task_id": .uuid(series.id), "p_user_ids": .uuids([bob.id])]))
            }
            await #expect(throws: AppError.invalidRotation) {
                try await alice.tasks.create(groupId: group.id, draft: TaskDraft(
                    title: "R", dueAt: V2IT.monday, recurrence: V2IT.daily, rotation: [alice.id, UUID()]
                ))
            }

            // invalid_item_title → .invalidChecklistItem; too_many_items → .tooManyChecklistItems
            await #expect(throws: AppError.invalidChecklistItem) {
                try await call(RestQuery.rpc("add_checklist_item", ["p_task_id": .uuid(series.id), "p_title": .string(" ")]))
            }
            await #expect(throws: AppError.invalidChecklistItem) {
                try await alice.tasks.create(groupId: group.id, draft: TaskDraft(title: "R", checklist: [""]))
            }
            await #expect(throws: AppError.tooManyChecklistItems) {
                try await alice.tasks.create(groupId: group.id, draft: TaskDraft(title: "R", checklist: (0...30).map { "É\($0)" }))
            }

            // item_not_found → .notFound; a NULL `p_done` (23502 invalid_input) → .invalidInput
            await #expect(throws: AppError.notFound) { try await alice.tasks.deleteChecklistItem(itemId: UUID()) }
            await #expect(throws: AppError.notFound) { try await alice.tasks.renameChecklistItem(itemId: UUID(), title: "Fantôme") }
            let item = try await alice.tasks.addChecklistItem(taskId: series.id, title: "Élément")
            await #expect(throws: AppError.invalidInput) {
                try await call(RestQuery.rpc("set_checklist_item_done", ["p_item_id": .uuid(item.id), "p_done": .null]))
            }
            #expect(try await alice.tasks.task(id: series.id).checklist == [item], "refused calls change nothing")
        }
    }
}
