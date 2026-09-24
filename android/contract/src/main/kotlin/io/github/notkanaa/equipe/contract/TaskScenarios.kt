package io.github.notkanaa.equipe.contract

import io.github.notkanaa.equipe.core.AppError
import io.github.notkanaa.equipe.core.AssignmentEvent
import io.github.notkanaa.equipe.core.Limits
import io.github.notkanaa.equipe.core.MemberRole
import io.github.notkanaa.equipe.core.TaskDraft
import io.github.notkanaa.equipe.core.TaskPriority
import io.github.notkanaa.equipe.core.TaskStatus
import java.util.UUID

// Task RPCs: create / update / status / delete, validation and assignee rules (docs/CONTRACTS.md §1, §3, §4.1).
internal val taskScenarios: List<ContractScenario> = listOf(
    ContractScenario("task.createFields") { harness ->
        val alice = harness.user("Alice")
        val bob = harness.user("Bob")
        val group = alice.makeGroup(joinedBy = listOf(bob))
        val title = Unique.name("Tâche")
        val draft = TaskDraft(
            title = "  $title  ", details = "  Détails de la tâche  ", priority = TaskPriority.HIGH, dueAt = Fixed.dueA,
            assigneeIds = setOf(alice.id, bob.id),
        )
        val created = alice.tasks.create(group.id, draft)
        Verify.equal(created.groupId, group.id, "groupId")
        Verify.equal(created.title, title, "title (trimmed)")
        Verify.equal(created.details, "Détails de la tâche", "details (trimmed)")
        Verify.equal(created.status, TaskStatus.TODO, "initial status")
        Verify.equal(created.priority, TaskPriority.HIGH, "priority")
        Verify.equal(created.dueAt, Fixed.dueA, "due date")
        Verify.equal(created.createdBy, alice.id, "createdBy")
        Verify.equal(created.completedAt, null, "completedAt of a new task")
        Verify.equal(created.assigneeIds, sortedIds(listOf(alice, bob)), "assigneeIds sorted by uuidString")
        Verify.equal(created.myAssignedAt, null, "myAssignedAt is only filled by myTasks")
        Verify.equal(created.groupName, null, "groupName is only filled by myTasks")
        Verify.that(created.updatedAt >= created.createdAt, "updatedAt ≥ createdAt")

        val fetched = bob.tasks.task(created.id)
        Verify.equal(fetched, created, "task(id) returns what create returned")
        val listed = bob.tasks.tasks(group.id, includeOldDone = false)
        Verify.equal(listed, listOf(created), "the group's tasks")

        val minimal = alice.tasks.create(group.id, TaskDraft(title = "Minimale", details = "   "))
        Verify.equal(minimal.details, null, "blank details are stored as NULL")
        Verify.equal(minimal.priority, TaskPriority.MEDIUM, "default priority")
        Verify.equal(minimal.dueAt, null, "no due date")
        Verify.equal(minimal.assigneeIds, emptyList<UUID>(), "no assignee")
    },

    ContractScenario("task.validation") { harness ->
        val alice = harness.user("Alice")
        val group = alice.makeGroup()
        // U+0000: Postgres text cannot hold it; adapters reject it like the mocks.
        for (invalid in listOf("", "   ", Fixed.text(201), "a\u0000b")) {
            Verify.fails(AppError.InvalidTitle, "create with the title ${debugDescription(invalid)}") {
                alice.tasks.create(group.id, TaskDraft(title = invalid))
            }
        }
        for (invalid in listOf(Fixed.text(5001), "d\u0000")) {
            Verify.fails(AppError.InvalidDetails, "create with the details ${debugDescription(invalid)}") {
                alice.tasks.create(group.id, TaskDraft(title = "Titre", details = invalid))
            }
        }
        val none = alice.tasks.tasks(group.id, includeOldDone = true)
        Verify.that(none.isEmpty(), "failed creations create nothing, got $none")

        val longest = alice.tasks.create(group.id, TaskDraft(title = Fixed.text(200), details = Fixed.text(5000)))
        Verify.equal(longest.title, Fixed.text(200), "200-character title accepted")
        Verify.equal(longest.details, Fixed.text(5000), "5000-character details accepted")

        for (invalid in listOf("", "   ", Fixed.text(201))) {
            Verify.fails(AppError.InvalidTitle, "update with a title of ${invalid.length} characters") {
                alice.tasks.update(longest.id, TaskDraft(title = invalid))
            }
        }
        Verify.fails(AppError.InvalidDetails, "update with 5001-character details") {
            alice.tasks.update(longest.id, TaskDraft(title = "Titre", details = Fixed.text(5001)))
        }
        val unchanged = alice.tasks.task(longest.id)
        Verify.equal(unchanged, longest, "failed updates change nothing")
    },

    ContractScenario("task.assigneesMustBeMembers") { harness ->
        val alice = harness.user("Alice")
        val bob = harness.user("Bob")
        val eve = harness.user("Eve")
        val group = alice.makeGroup(joinedBy = listOf(bob))
        eve.makeGroup("Autre", joinedBy = listOf(alice))
        Verify.fails(AppError.AssigneeNotMember, "assign a member of another group") {
            alice.tasks.create(group.id, TaskDraft(title = "Titre", assigneeIds = setOf(bob.id, eve.id)))
        }
        Verify.fails(AppError.AssigneeNotMember, "assign an unknown user") {
            alice.tasks.create(group.id, TaskDraft(title = "Titre", assigneeIds = setOf(UUID.randomUUID())))
        }
        val task = alice.makeTask(group.id, assignees = listOf(bob))
        Verify.fails(AppError.AssigneeNotMember, "reassign to a non-member") {
            alice.reassign(task, listOf(bob, eve))
        }
        val unchanged = alice.tasks.task(task.id)
        Verify.equal(unchanged.assigneeIds, listOf(bob.id), "a refused reassignment changes nothing")
        val tasks = alice.tasks.tasks(group.id, includeOldDone = true)
        Verify.equal(tasks.map { it.id }, listOf(task.id), "refused creations create nothing")
    },

    ContractScenario("task.assigneeLimit") { harness ->
        val alice = harness.user("Alice")
        val others = mutableListOf<ContractUser>()
        for (index in 1..Limits.maxAssignees) {
            others.add(harness.user("Membre$index"))
        }
        val group = alice.makeGroup(joinedBy = others)
        val everyone = listOf(alice) + others
        Verify.equal(everyone.size, Limits.maxAssignees + 1, "fixture size")

        val twenty = everyone.take(Limits.maxAssignees)
        val task = Verify.step("create with 20 assignees") {
            alice.tasks.create(group.id, TaskDraft(title = "Vingt", assigneeIds = twenty.map { it.id }.toSet()))
        }
        Verify.equal(task.assigneeIds, sortedIds(twenty), "20 assignees accepted")
        Verify.fails(AppError.TooManyAssignees, "create with 21 assignees") {
            alice.tasks.create(group.id, TaskDraft(title = "Vingt et un", assigneeIds = everyone.map { it.id }.toSet()))
        }
        Verify.fails(AppError.TooManyAssignees, "update to 21 assignees") {
            alice.reassign(task, everyone)
        }
        val unchanged = alice.tasks.task(task.id)
        Verify.equal(unchanged.assigneeIds, sortedIds(twenty), "a refused update keeps the 20 assignees")
    },

    ContractScenario("task.updateFields") { harness ->
        val alice = harness.user("Alice")
        val bob = harness.user("Bob")
        val carol = harness.user("Carol")
        val group = alice.makeGroup(joinedBy = listOf(bob, carol))
        val original = bob.tasks.create(
            group.id,
            TaskDraft(
                title = "Originale", details = "Détails", priority = TaskPriority.LOW, dueAt = Fixed.dueA,
                assigneeIds = setOf(bob.id),
            ),
        )
        val newTitle = Unique.name("Modifiée")
        val updated = bob.tasks.update(
            original.id,
            TaskDraft(
                title = "  $newTitle  ", details = "", priority = TaskPriority.HIGH, dueAt = null,
                assigneeIds = setOf(carol.id),
            ),
        )
        Verify.equal(updated.id, original.id, "same task")
        Verify.equal(updated.title, newTitle, "title (trimmed)")
        Verify.equal(updated.details, null, "empty details are stored as NULL")
        Verify.equal(updated.priority, TaskPriority.HIGH, "priority")
        Verify.equal(updated.dueAt, null, "a null due date clears it")
        Verify.equal(updated.assigneeIds, listOf(carol.id), "assignees replaced")
        Verify.equal(updated.status, TaskStatus.TODO, "status untouched by update")
        Verify.equal(updated.createdBy, bob.id, "createdBy kept")
        Verify.equal(updated.createdAt, original.createdAt, "createdAt kept")
        Verify.that(updated.updatedAt > original.updatedAt, "updatedAt moves forward")
        val fetched = alice.tasks.task(original.id)
        Verify.equal(fetched, updated, "task(id) returns what update returned")

        bob.tasks.setStatus(original.id, TaskStatus.IN_PROGRESS)
        val again = alice.tasks.update(
            original.id,
            TaskDraft(
                title = newTitle, details = "Nouveaux détails", priority = TaskPriority.MEDIUM, dueAt = Fixed.dueB,
                assigneeIds = emptySet(),
            ),
        )
        Verify.equal(again.status, TaskStatus.IN_PROGRESS, "update keeps the current status")
        Verify.equal(again.dueAt, Fixed.dueB, "new due date")
        Verify.equal(again.details, "Nouveaux détails", "new details")
        Verify.equal(again.assigneeIds, emptyList<UUID>(), "assignees cleared")
    },

    ContractScenario("task.statusAndCompletedAt") { harness ->
        val alice = harness.user("Alice")
        val group = alice.makeGroup()
        val task = alice.makeTask(group.id, assignees = listOf(alice))

        val started = alice.tasks.setStatus(task.id, TaskStatus.IN_PROGRESS)
        Verify.equal(started.status, TaskStatus.IN_PROGRESS, "in progress")
        Verify.equal(started.completedAt, null, "completedAt while in progress")
        Verify.that(started.updatedAt > task.updatedAt, "updatedAt moves forward on a status change")

        val done = alice.tasks.setStatus(task.id, TaskStatus.DONE)
        Verify.equal(done.status, TaskStatus.DONE, "done")
        val completedAt = Verify.unwrap(done.completedAt, "completedAt of a done task")
        Verify.that(completedAt > started.updatedAt, "completedAt is set when the task becomes done")
        val fetched = alice.tasks.task(task.id)
        Verify.equal(fetched, done, "task(id) returns what setStatus returned")
        val visible = alice.tasks.tasks(group.id, includeOldDone = false)
        Verify.equal(visible.map { it.id }, listOf(task.id), "a recently completed task stays visible by default")

        val reopened = alice.tasks.setStatus(task.id, TaskStatus.TODO)
        Verify.equal(reopened.completedAt, null, "completedAt cleared when reopened")
        val redone = alice.tasks.setStatus(task.id, TaskStatus.DONE)
        Verify.that(redone.completedAt != null, "completedAt set again")
    },

    // tasks_before_update: updatedAt only moves when title, details, status, priority or due date change.
    ContractScenario("task.updatedAtTracksFieldChanges") { harness ->
        val alice = harness.user("Alice")
        val bob = harness.user("Bob")
        val group = alice.makeGroup(joinedBy = listOf(bob))
        val created = alice.tasks.create(
            group.id,
            TaskDraft(
                title = "Suivi", details = "Détails", priority = TaskPriority.HIGH, dueAt = Fixed.dueA,
                assigneeIds = setOf(alice.id),
            ),
        )
        val reassigned = alice.reassign(created, listOf(alice, bob))
        Verify.equal(reassigned.assigneeIds, sortedIds(listOf(alice, bob)), "assignees replaced")
        Verify.equal(reassigned.updatedAt, created.updatedAt, "an assignee-only edit keeps updatedAt")
        val padded = alice.tasks.update(
            created.id,
            TaskDraft(
                title = "  Suivi  ", details = " Détails ", priority = TaskPriority.HIGH, dueAt = Fixed.dueA,
                assigneeIds = setOf(alice.id, bob.id),
            ),
        )
        Verify.equal(padded.updatedAt, created.updatedAt, "identical (trimmed) fields keep updatedAt")
        val todo = alice.tasks.setStatus(created.id, TaskStatus.TODO)
        Verify.equal(todo.updatedAt, created.updatedAt, "an unchanged status keeps updatedAt")

        val done = alice.tasks.setStatus(created.id, TaskStatus.DONE)
        Verify.that(done.updatedAt > created.updatedAt, "a status change moves updatedAt")
        val doneAgain = bob.tasks.setStatus(created.id, TaskStatus.DONE)
        Verify.equal(doneAgain.updatedAt, done.updatedAt, "done → done keeps updatedAt")
        Verify.equal(doneAgain.completedAt, done.completedAt, "done → done keeps completedAt")
        val fetched = bob.tasks.task(created.id)
        Verify.equal(fetched, doneAgain, "task(id) returns what setStatus returned")
    },

    ContractScenario("task.unknownTask") { harness ->
        val alice = harness.user("Alice")
        alice.makeGroup()
        val unknown = UUID.randomUUID()
        Verify.fails(AppError.NotFound, "task(id) of an unknown task") { alice.tasks.task(unknown) }
        Verify.fails(AppError.NotFound, "update an unknown task") {
            alice.tasks.update(unknown, TaskDraft(title = "Titre"))
        }
        Verify.fails(AppError.NotFound, "setStatus of an unknown task") {
            alice.tasks.setStatus(unknown, TaskStatus.DONE)
        }
        Verify.fails(AppError.NotFound, "delete an unknown task") { alice.tasks.delete(unknown) }
    },

    ContractScenario("task.assigneeRowsKeepMetadata") { harness ->
        val alice = harness.user("Alice")
        val dan = harness.user("Dan")
        val bob = harness.user("Bob")
        val carol = harness.user("Carol")
        val group = alice.makeGroup(joinedBy = listOf(dan, bob, carol))
        alice.groups.setRole(group.id, dan.id, MemberRole.ADMIN)
        val task = alice.makeTask(group.id, assignees = listOf(bob))
        val first = bob.assignment(task.id)
        Verify.equal(first.assignedBy, alice.id, "assignedBy of the first assignment")
        val bobTasks = bob.tasks.myTasks(includeDone = true)
        Verify.equal(bobTasks.firstOrNull { it.id == task.id }?.myAssignedAt, first.assignedAt, "myAssignedAt")
        Verify.equal(bobTasks.firstOrNull { it.id == task.id }?.myAssignedBy, alice.id, "myAssignedBy")

        // Dan (another admin) adds Carol: Bob's row is kept as is.
        val updated = dan.reassign(task, listOf(bob, carol))
        Verify.equal(updated.assigneeIds, sortedIds(listOf(bob, carol)), "assignees after adding carol")
        val kept = bob.assignment(task.id)
        Verify.equal(kept.assignedBy, alice.id, "a retained row keeps assignedBy")
        Verify.equal(kept.assignedAt, first.assignedAt, "a retained row keeps assignedAt")
        val carolRow = carol.assignment(task.id)
        Verify.equal(carolRow.assignedBy, dan.id, "a new row gets assignedBy = caller")
        Verify.that(carolRow.assignedAt > first.assignedAt, "a new row gets a new assignedAt")

        // Same set again: nothing changes.
        dan.reassign(updated, listOf(bob, carol))
        val same = bob.assignment(task.id)
        Verify.equal(same, kept, "re-saving the same assignees keeps the rows")

        // Removed then re-added: a brand new row.
        val withoutBob = dan.reassign(updated, listOf(carol))
        Verify.equal(withoutBob.assigneeIds, listOf(carol.id), "bob unassigned")
        val bobEvents = bob.tasks.assignments(Fixed.longAgo)
        Verify.that(bobEvents.none { it.taskId == task.id }, "an unassigned user has no assignment row")
        dan.reassign(withoutBob, listOf(bob, carol))
        val fresh = bob.assignment(task.id)
        Verify.equal(fresh.assignedBy, dan.id, "a re-added row gets the new assigner")
        Verify.that(fresh.assignedAt > kept.assignedAt, "a re-added row gets a new assignedAt")
    },

    ContractScenario("task.deleteCascades") { harness ->
        val alice = harness.user("Alice")
        val bob = harness.user("Bob")
        val group = alice.makeGroup(joinedBy = listOf(bob))
        val task = alice.makeTask(group.id, assignees = listOf(bob))
        val keep = alice.makeTask(group.id, assignees = listOf(bob))
        alice.tasks.delete(task.id)
        Verify.fails(AppError.NotFound, "a deleted task") { bob.tasks.task(task.id) }
        val groupTasks = bob.tasks.tasks(group.id, includeOldDone = true)
        Verify.equal(groupTasks.map { it.id }, listOf(keep.id), "the group's tasks after a deletion")
        val mine = bob.tasks.myTasks(includeDone = true)
        Verify.equal(mine.map { it.id }, listOf(keep.id), "myTasks after a deletion")
        val events = bob.tasks.assignments(Fixed.longAgo)
        Verify.equal(events.map { it.taskId }, listOf(keep.id), "assignments of a deleted task are gone")
    },
)

/** This user's assignment event for [taskId] (made by someone else). */
internal suspend fun ContractUser.assignment(taskId: UUID): AssignmentEvent {
    val events = tasks.assignments(Fixed.longAgo)
    return Verify.unwrap(events.firstOrNull { it.taskId == taskId }, "$displayName's assignment to $taskId")
}
