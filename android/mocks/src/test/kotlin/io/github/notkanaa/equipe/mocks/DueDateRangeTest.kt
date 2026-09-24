package io.github.notkanaa.equipe.mocks

import io.github.notkanaa.equipe.core.AppError
import io.github.notkanaa.equipe.core.InputValidation
import io.github.notkanaa.equipe.core.TaskDraft
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test
import java.time.Instant

/** SQL `tasks_due_at_range` / `invalid_due_at`: due dates must lie in [1970-01-01, 10000-01-01) UTC. Port of DueDateRangeTests.swift. */
class DueDateRangeTest {
    private val clock = MockClock(TestDates.start)
    private val lilas = DemoData.lilasGroupId

    /** Swift's `Date.distantPast` (0001-01-01). */
    private val distantPast: Instant = Instant.parse("0001-01-01T00:00:00Z")

    private val year10001: Instant = Instant.ofEpochSecond(253_402_300_800L + 366L * 86_400L)

    @Test
    fun sharedRuleBoundaries() {
        assertNull(InputValidation.dueDate(null))
        assertEquals(Instant.EPOCH, InputValidation.dueDate(Instant.EPOCH))
        assertInvalid(Instant.ofEpochSecond(-1))
        val lastSecond = Instant.ofEpochSecond(253_402_300_799L) // 9999-12-31T23:59:59Z
        assertEquals(lastSecond, InputValidation.dueDate(lastSecond))
        assertInvalid(Instant.ofEpochSecond(253_402_300_800L))
        assertInvalid(year10001)
        assertInvalid(distantPast)
    }

    private fun assertInvalid(date: Instant) {
        try {
            InputValidation.dueDate(date)
        } catch (error: AppError) {
            assertEquals("$date", AppError.InvalidInput, error)
            return
        }
        throw AssertionError("$date must be refused")
    }

    @Test
    fun mockRejectsOutOfRangeDueDatesLikeSQL() = runTest {
        val backend = InMemoryBackend.demo(now = clock.provider)
        val camille = backend.services(DemoData.camille.id)
        assertThrowsAppError(AppError.InvalidInput) {
            camille.tasks.create(lilas, TaskDraft(title = "Trop loin", dueAt = year10001))
        }
        // Title and details are validated first, like the SQL trigger.
        assertThrowsAppError(AppError.InvalidTitle) {
            camille.tasks.create(lilas, TaskDraft(title = " ", dueAt = distantPast))
        }
        val task = camille.tasks.create(lilas, TaskDraft(title = "Dans les temps", dueAt = clock.now()))
        val draft = TaskDraft(task).copy(dueAt = Instant.ofEpochSecond(-86_400L))
        assertThrowsAppError(AppError.InvalidInput) { camille.tasks.update(task.id, draft) }
        assertEquals("a rejected edit changes nothing", task.dueAt, camille.tasks.task(task.id).dueAt)
    }
}
