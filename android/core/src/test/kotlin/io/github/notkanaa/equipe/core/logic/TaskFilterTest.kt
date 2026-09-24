package io.github.notkanaa.equipe.core.logic

import io.github.notkanaa.equipe.core.TaskItem
import io.github.notkanaa.equipe.core.TaskStatus
import kotlinx.serialization.json.Json
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.time.Instant
import java.util.UUID
import io.github.notkanaa.equipe.core.logic.LogicFixtures as F

/** Port of the TaskFilterTests suite of Logic/TaskFilterSortTests.swift. */
class TaskFilterTest {
    private val now: Instant = F.date(2026, 9, 24, 12, 0)

    private val tasks: List<TaskItem> = listOf(
        F.task(1, status = TaskStatus.TODO, due = F.date(2026, 9, 23), assignees = listOf(F.me)), // overdue, mine
        F.task(2, status = TaskStatus.IN_PROGRESS, due = F.date(2026, 9, 25), assignees = listOf(F.other)),
        F.task(3, status = TaskStatus.DONE, due = F.date(2026, 9, 20), assignees = listOf(F.me)), // done: never overdue
        F.task(4, status = TaskStatus.TODO, due = null, assignees = emptyList()),
        F.task(5, status = TaskStatus.IN_PROGRESS, due = F.date(2026, 9, 24, 11, 59), assignees = listOf(F.me, F.other)),
    )

    private fun ids(filter: TaskFilter, userId: UUID? = F.me): List<Int> =
        filter.apply(tasks, userId, now).map { task -> tasks.indexOf(task) + 1 }

    @Test
    fun defaultFilterKeepsEverythingInOrder() {
        assertEquals(listOf(1, 2, 3, 4, 5), ids(TaskFilter.ALL))
        assertFalse(TaskFilter.ALL.isActive)
        assertEquals(0, TaskFilter.ALL.activeCriteriaCount)
        assertEquals(TaskFilter(), TaskFilter.ALL)
    }

    @Test
    fun statusFilters() {
        assertEquals(listOf(1, 4), ids(TaskFilter(status = TaskStatusFilter.TODO)))
        assertEquals(listOf(2, 5), ids(TaskFilter(status = TaskStatusFilter.IN_PROGRESS)))
        assertEquals(listOf(3), ids(TaskFilter(status = TaskStatusFilter.DONE)))
        assertEquals(listOf(1, 2, 4, 5), ids(TaskFilter(status = TaskStatusFilter.NOT_DONE)))
    }

    @Test
    fun assignedToMe() {
        assertEquals(listOf(1, 3, 5), ids(TaskFilter(onlyAssignedToMe = true)))
        assertEquals(emptyList<Int>(), ids(TaskFilter(onlyAssignedToMe = true), userId = null))
    }

    @Test
    fun overdue() {
        assertEquals(listOf(1, 5), ids(TaskFilter(onlyOverdue = true)))
    }

    @Test
    fun overdueBoundaryIsStrict() {
        val dueNow = F.task(9, due = now)
        assertFalse(dueNow.isOverdue(now))
        assertTrue(dueNow.isOverdue(now.plusMillis(1)))
        assertFalse(F.task(10, due = null).isOverdue(now))
        assertFalse(F.task(11, status = TaskStatus.DONE, due = F.date(2020, 1, 1)).isOverdue(now))
    }

    @Test
    fun criteriaCombine() {
        val filter = TaskFilter(status = TaskStatusFilter.IN_PROGRESS, onlyAssignedToMe = true, onlyOverdue = true)
        assertEquals(listOf(5), ids(filter))
        assertEquals(3, filter.activeCriteriaCount)
        assertTrue(filter.isActive)
    }

    @Test
    fun frenchLabels() {
        assertEquals(
            listOf("Toutes", "À faire", "En cours", "Terminées", "Non terminées"),
            TaskStatusFilter.entries.map { it.label },
        )
        assertEquals(listOf("all", "todo", "inProgress", "done", "notDone"), TaskStatusFilter.entries.map { it.id })
        assertEquals(TaskStatusFilter.NOT_DONE, TaskStatusFilter.fromRawValue("notDone"))
    }

    @Test
    fun codableRoundTrip() {
        val filter = TaskFilter(status = TaskStatusFilter.NOT_DONE, onlyAssignedToMe = true, onlyOverdue = false)
        val json = Json.encodeToString(TaskFilter.serializer(), filter)
        assertEquals(filter, Json.decodeFromString(TaskFilter.serializer(), json))
        // Swift's raw values, as in the iOS app.
        assertTrue(json, json.contains("\"notDone\""))
    }

    @Test
    fun isAssignedTo() {
        assertTrue(F.task(1, assignees = listOf(F.other, F.me)).isAssignedTo(F.me))
        assertFalse(F.task(2, assignees = listOf(F.other)).isAssignedTo(F.me))
    }
}
