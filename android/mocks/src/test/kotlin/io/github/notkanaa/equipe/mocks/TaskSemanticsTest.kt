package io.github.notkanaa.equipe.mocks

import io.github.notkanaa.equipe.core.Limits
import io.github.notkanaa.equipe.core.TaskDraft
import io.github.notkanaa.equipe.core.TaskStatus
import io.github.notkanaa.equipe.core.uuidString
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.UUID
import kotlin.time.Duration.Companion.days
import kotlin.time.Duration.Companion.seconds

/** Mock-specific task semantics that need an injected clock. Port of TaskSemanticsTests.swift. */
class TaskSemanticsTest {
    private val clock = MockClock(TestDates.start)

    @Test
    fun oldDoneTasksAreHiddenUnlessRequested() = runTest {
        val backend = InMemoryBackend.demo(now = clock.provider)
        val camille = backend.services(DemoData.camille.id)
        val task = camille.tasks.create(
            DemoData.lilasGroupId, TaskDraft(title = "Arroser les plantes", assigneeIds = setOf(DemoData.camille.id)),
        )
        val done = camille.tasks.setStatus(task.id, TaskStatus.DONE)
        assertEquals(clock.peek(), done.completedAt)

        suspend fun visible(includeOldDone: Boolean): Boolean =
            camille.tasks.tasks(DemoData.lilasGroupId, includeOldDone).any { it.id == task.id }

        clock.advance(Limits.oldDoneTaskDays.days)
        assertTrue("completed exactly 30 days ago: kept (gte)", visible(includeOldDone = false))
        clock.advance(1.seconds)
        assertFalse(visible(includeOldDone = false))
        assertTrue(visible(includeOldDone = true))
        // Other reads are not filtered by age.
        assertEquals(TaskStatus.DONE, camille.tasks.task(task.id).status)
        assertTrue(camille.tasks.myTasks(includeDone = true).any { it.id == task.id })
        assertFalse(camille.tasks.myTasks(includeDone = false).any { it.id == task.id })
        // The demo task completed yesterday is now old too; open tasks are never hidden.
        val recent = camille.tasks.tasks(DemoData.lilasGroupId, includeOldDone = false)
        assertFalse(recent.any { it.id == DemoData.TaskIds.nettoyerCuisine })
        assertTrue(recent.any { it.id == DemoData.TaskIds.reparerFuite })

        camille.tasks.setStatus(task.id, TaskStatus.IN_PROGRESS)
        assertTrue(visible(includeOldDone = false))
    }

    @Test
    fun completedAtIsKeptWhenAlreadyDone() = runTest {
        val backend = InMemoryBackend.demo(now = clock.provider)
        val camille = backend.services(DemoData.camille.id)
        val task = camille.tasks.create(DemoData.lilasGroupId, TaskDraft(title = "Ranger"))
        val done = camille.tasks.setStatus(task.id, TaskStatus.DONE)
        clock.advance(60.seconds)
        val again = camille.tasks.setStatus(task.id, TaskStatus.DONE)
        assertEquals(done.completedAt, again.completedAt)
        assertEquals(done.updatedAt, again.updatedAt) // nothing changed: SQL keeps updated_at
    }

    @Test
    fun timestampsFollowTheInjectedClock() = runTest {
        val backend = InMemoryBackend.demo(now = clock.provider)
        val camille = backend.services(DemoData.camille.id)
        clock.advance(1.seconds) // the demo groups were last active at the seed time
        val start = clock.peek()
        val task = camille.tasks.create(
            DemoData.sportGroupId, TaskDraft(title = "Tracer les lignes", assigneeIds = setOf(DemoData.lucas.id)),
        )
        assertEquals(start, task.createdAt)
        assertEquals(start, task.updatedAt)
        val groups = camille.groups.myGroups()
        assertEquals(DemoData.sportGroupId, groups.first().id) // bumped to now: most recently active
        assertEquals(start, groups.first().group.lastActivityAt)

        clock.advance(10.seconds)
        val lucas = backend.services(DemoData.lucas.id)
        val events = lucas.tasks.assignments(start.minusSeconds(1))
        assertEquals(listOf(task.id), events.map { it.taskId })
        assertEquals(start, events.first().assignedAt)
        assertEquals(DemoData.camille.id, events.first().assignedBy)
    }

    @Test
    fun assignmentsWithTheSameTimestampAreOrderedDeterministically() = runTest {
        val backend = InMemoryBackend.demo(now = clock.provider)
        val camille = backend.services(DemoData.camille.id)
        val ids = ArrayList<UUID>()
        for (title in listOf("Un", "Deux", "Trois")) {
            val task = camille.tasks.create(
                DemoData.lilasGroupId, TaskDraft(title = title, assigneeIds = setOf(DemoData.ines.id)),
            )
            ids.add(task.id)
        }
        val ines = backend.services(DemoData.ines.id)
        val events = ines.tasks.assignments(clock.peek().minusSeconds(1))
        assertEquals(ids.sortedBy { it.uuidString }, events.map { it.taskId })
    }
}
