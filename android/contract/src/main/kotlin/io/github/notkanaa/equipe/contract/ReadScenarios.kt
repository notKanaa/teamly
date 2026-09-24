package io.github.notkanaa.equipe.contract

import io.github.notkanaa.equipe.core.TaskStatus

// PostgREST reads (docs/CONTRACTS.md §4.3): group tasks, my tasks, assignments since.
internal val readScenarios: List<ContractScenario> = listOf(
    ContractScenario("reads.groupTasksAreScoped") { harness ->
        val alice = harness.user("Alice")
        val first = alice.makeGroup("Un")
        val second = alice.makeGroup("Deux")
        val a1 = alice.makeTask(first.id)
        val a2 = alice.makeTask(first.id, assignees = listOf(alice))
        val b1 = alice.makeTask(second.id)
        alice.tasks.setStatus(a2.id, TaskStatus.DONE)
        for (includeOldDone in listOf(false, true)) {
            val firstTasks = alice.tasks.tasks(first.id, includeOldDone)
            Verify.equal(
                firstTasks.map { it.id }.toSet(), setOf(a1.id, a2.id), "tasks of the first group ($includeOldDone)",
            )
            val secondTasks = alice.tasks.tasks(second.id, includeOldDone)
            Verify.equal(secondTasks.map { it.id }, listOf(b1.id), "tasks of the second group ($includeOldDone)")
            for (task in firstTasks + secondTasks) {
                Verify.equal(task.myAssignedAt, null, "group tasks have no myAssignedAt")
                Verify.equal(task.myAssignedBy, null, "group tasks have no myAssignedBy")
                Verify.equal(task.groupName, null, "group tasks have no groupName")
            }
        }
    },

    ContractScenario("reads.myTasks") { harness ->
        val alice = harness.user("Alice")
        val bob = harness.user("Bob")
        val first = alice.makeGroup("Un", joinedBy = listOf(bob))
        val second = alice.makeGroup("Deux", joinedBy = listOf(bob))
        val todo = alice.makeTask(first.id, assignees = listOf(bob), dueAt = Fixed.dueA)
        val done = alice.makeTask(second.id, assignees = listOf(bob, alice))
        bob.tasks.setStatus(done.id, TaskStatus.DONE)
        val notMine = alice.makeTask(first.id, assignees = listOf(alice))
        val selfAssigned = bob.makeTask(first.id, assignees = listOf(bob))

        val open = bob.tasks.myTasks(includeDone = false)
        Verify.equal(open.map { it.id }.toSet(), setOf(todo.id, selfAssigned.id), "open tasks assigned to bob")
        val all = bob.tasks.myTasks(includeDone = true)
        Verify.equal(
            all.map { it.id }.toSet(), setOf(todo.id, done.id, selfAssigned.id), "all tasks assigned to bob",
        )
        Verify.that(all.none { it.id == notMine.id }, "tasks not assigned to bob are excluded")

        val names = mapOf(first.id to first.name, second.id to second.name)
        val assigners = mapOf(todo.id to alice.id, done.id to alice.id, selfAssigned.id to bob.id)
        for (item in all) {
            Verify.equal(item.groupName, names[item.groupId], "groupName of ${item.title}")
            Verify.that(item.myAssignedAt != null, "myAssignedAt of ${item.title}")
            Verify.equal(item.myAssignedBy, assigners[item.id], "myAssignedBy of ${item.title}")
            val plain = bob.tasks.task(item.id)
            Verify.equal(item.withoutPersonalFields, plain, "myTasks item ${item.title} matches task(id)")
        }
        val doneItem = Verify.unwrap(all.firstOrNull { it.id == done.id }, "done task in myTasks")
        Verify.equal(doneItem.assigneeIds, sortedIds(listOf(alice, bob)), "all assignees are listed, sorted")
        Verify.equal(doneItem.status, TaskStatus.DONE, "status of the done task")
        val aliceOpen = alice.tasks.myTasks(includeDone = false)
        Verify.equal(aliceOpen.map { it.id }.toSet(), setOf(notMine.id), "alice's open tasks")
    },

    ContractScenario("reads.assignmentsSince") { harness ->
        val alice = harness.user("Alice")
        val bob = harness.user("Bob")
        val group = alice.makeGroup(joinedBy = listOf(bob))
        val first = alice.makeTask(group.id, "Premiere", assignees = listOf(bob), dueAt = Fixed.dueA)
        val own = bob.makeTask(group.id, assignees = listOf(bob))
        val second = alice.makeTask(group.id, "Seconde", assignees = listOf(alice, bob))

        val events = bob.tasks.assignments(Fixed.longAgo)
        Verify.equal(events.map { it.taskId }, listOf(first.id, second.id), "assignments by others, oldest first")
        Verify.that(events.none { it.taskId == own.id }, "self-assignments are excluded")
        val event = events[0]
        Verify.equal(event.groupId, group.id, "event groupId")
        Verify.equal(event.taskTitle, first.title, "event taskTitle")
        Verify.equal(event.groupName, group.name, "event groupName")
        Verify.equal(event.assignedBy, alice.id, "event assignedBy")
        Verify.equal(event.dueAt, Fixed.dueA, "event dueAt")
        Verify.that(events[0].assignedAt < events[1].assignedAt, "events ordered by assignedAt")

        val later = bob.tasks.assignments(events[0].assignedAt)
        Verify.equal(later.map { it.taskId }, listOf(second.id), "since is exclusive")
        val none = bob.tasks.assignments(events[1].assignedAt)
        Verify.that(none.isEmpty(), "nothing after the last assignment, got $none")
        val aliceEvents = alice.tasks.assignments(Fixed.longAgo)
        Verify.that(aliceEvents.isEmpty(), "alice only assigned herself, got $aliceEvents")
    },
)
