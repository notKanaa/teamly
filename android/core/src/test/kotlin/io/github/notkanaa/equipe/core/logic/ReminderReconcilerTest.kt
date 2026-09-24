package io.github.notkanaa.equipe.core.logic

import io.github.notkanaa.equipe.core.InMemoryKeyValueStore
import io.github.notkanaa.equipe.core.LocalNotification
import io.github.notkanaa.equipe.core.TaskItem
import io.github.notkanaa.equipe.core.TaskStatus
import io.github.notkanaa.equipe.core.value
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.time.Instant
import io.github.notkanaa.equipe.core.logic.LogicFixtures as F

/** Port of the ReminderReconcilerTests suite of Logic/ReminderTests.swift. */
class ReminderReconcilerTest {
    private val planner = ReminderPlanner(F.parisCalendar)
    private val now: Instant = F.date(2026, 9, 24, 12, 0)

    private fun plan(tasks: List<TaskItem>, leadTime: ReminderLeadTime = ReminderLeadTime.ONE_HOUR): List<LocalNotification> =
        planner.plan(tasks, F.me, leadTime, now)

    @Test
    fun firstApplySchedulesEverything() = runTest {
        val scheduler = LogicFakeScheduler()
        val reconciler = ReminderReconciler(scheduler, InMemoryKeyValueStore())
        val desired = plan(listOf(F.task(1, due = F.date(2026, 9, 25, 10, 0)), F.task(2, due = F.date(2026, 9, 26, 10, 0))))
        val result = reconciler.apply(desired)
        assertEquals(desired.map { it.id }, result.added)
        assertTrue(result.removed.isEmpty() && result.replaced.isEmpty() && result.failed.isEmpty())
        assertEquals(desired.map { it.id }.sorted(), scheduler.pendingIds)
        assertEquals(desired[0], scheduler.pending[desired[0].id])
    }

    @Test
    fun applyIsIdempotent() = runTest {
        val scheduler = LogicFakeScheduler()
        val reconciler = ReminderReconciler(scheduler, InMemoryKeyValueStore())
        val desired = plan(listOf(F.task(1, due = F.date(2026, 9, 25, 10, 0)), F.task(2, due = F.date(2026, 9, 26, 10, 0))))
        reconciler.apply(desired)
        scheduler.resetCallLog()

        val second = reconciler.apply(desired)
        assertTrue(second.isNoOp)
        assertEquals(2, second.unchanged)
        assertTrue(scheduler.added.isEmpty())
        assertTrue(scheduler.removeCalls.isEmpty())
    }

    @Test
    fun dueDateChangeReplacesTheId() = runTest {
        val scheduler = LogicFakeScheduler()
        val reconciler = ReminderReconciler(scheduler, InMemoryKeyValueStore())
        val before = plan(listOf(F.task(1, due = F.date(2026, 9, 25, 10, 0))))
        reconciler.apply(before)

        val after = plan(listOf(F.task(1, due = F.date(2026, 9, 27, 18, 0))))
        assertNotEquals(before[0].id, after[0].id)
        val result = reconciler.apply(after)
        assertEquals(listOf(before[0].id), result.removed)
        assertEquals(listOf(after[0].id), result.added)
        assertEquals(listOf(after[0].id), scheduler.pendingIds)
    }

    @Test
    fun tasksNoLongerDesiredAreRemoved() = runTest {
        val scheduler = LogicFakeScheduler()
        val reconciler = ReminderReconciler(scheduler, InMemoryKeyValueStore())
        val tasks = listOf(F.task(1, due = F.date(2026, 9, 25, 10, 0)), F.task(2, due = F.date(2026, 9, 26, 10, 0)))
        val initial = plan(tasks)
        reconciler.apply(initial)

        // Task 2 is done now.
        val done = tasks[1].copy(status = TaskStatus.DONE)
        val result = reconciler.apply(plan(listOf(tasks[0], done)))
        assertEquals(listOf(initial[1].id), result.removed)
        assertTrue(result.added.isEmpty())
        assertEquals(listOf(initial[0].id), scheduler.pendingIds)
    }

    @Test
    fun leadTimeChangeReplacesPendingRequestsWithTheSameIds() = runTest {
        val scheduler = LogicFakeScheduler()
        val reconciler = ReminderReconciler(scheduler, InMemoryKeyValueStore())
        val tasks = listOf(F.task(1, due = F.date(2026, 9, 25, 10, 0)))
        reconciler.apply(plan(tasks, ReminderLeadTime.ONE_HOUR))
        scheduler.resetCallLog()

        val fifteen = plan(tasks, ReminderLeadTime.FIFTEEN_MINUTES)
        val result = reconciler.apply(fifteen)
        assertEquals(listOf(fifteen[0].id), result.replaced)
        assertTrue(result.added.isEmpty() && result.removed.isEmpty())
        assertEquals(listOf(listOf(fifteen[0].id)), scheduler.removeCalls)
        assertEquals(F.date(2026, 9, 25, 9, 45), scheduler.pending[fifteen[0].id]?.fireDate)

        val again = reconciler.apply(fifteen)
        assertTrue(again.isNoOp)
    }

    @Test
    fun renamedTaskIsReplaced() = runTest {
        val scheduler = LogicFakeScheduler()
        val reconciler = ReminderReconciler(scheduler, InMemoryKeyValueStore())
        reconciler.apply(plan(listOf(F.task(1, title = "Ancien titre", due = F.date(2026, 9, 25, 10, 0)))))
        val renamed = plan(listOf(F.task(1, title = "Nouveau titre", due = F.date(2026, 9, 25, 10, 0))))
        val result = reconciler.apply(renamed)
        assertEquals(listOf(renamed[0].id), result.replaced)
        assertTrue(scheduler.pending[renamed[0].id]?.body?.startsWith("Nouveau titre") == true)
    }

    @Test
    fun turningRemindersOffRemovesAllDueRequestsOnly() = runTest {
        val scheduler = LogicFakeScheduler()
        scheduler.seedPending(
            LocalNotification(id = "assigned-X", title = "Nouvelle tâche", body = "b", fireDate = now.plusSeconds(60)),
        )
        val reconciler = ReminderReconciler(scheduler, InMemoryKeyValueStore())
        val desired = plan(listOf(F.task(1, due = F.date(2026, 9, 25, 10, 0)), F.task(2, due = F.date(2026, 9, 26, 10, 0))))
        reconciler.apply(desired)

        val result = reconciler.apply(plan(listOf(F.task(1, due = F.date(2026, 9, 25, 10, 0))), ReminderLeadTime.OFF))
        assertEquals(desired.map { it.id }.sorted(), result.removed)
        assertEquals(listOf("assigned-X"), scheduler.pendingIds)
    }

    @Test
    fun unknownPendingRequestFromAPreviousInstallIsReplacedOnce() = runTest {
        val scheduler = LogicFakeScheduler()
        val desired = plan(listOf(F.task(1, due = F.date(2026, 9, 25, 10, 0))))
        scheduler.seedPending(desired[0])
        val store = InMemoryKeyValueStore()
        val reconciler = ReminderReconciler(scheduler, store)

        val first = reconciler.apply(desired)
        assertEquals(listOf(desired[0].id), first.replaced)
        val second = reconciler.apply(desired)
        assertTrue(second.isNoOp)
        // A new reconciler on the same store (next launch) sees the same state.
        val third = ReminderReconciler(scheduler, store).apply(desired)
        assertTrue(third.isNoOp)
    }

    @Test
    fun failedAddIsRetriedNextTime() = runTest {
        val scheduler = LogicFakeScheduler()
        val reconciler = ReminderReconciler(scheduler, InMemoryKeyValueStore())
        val desired = plan(listOf(F.task(1, due = F.date(2026, 9, 25, 10, 0)), F.task(2, due = F.date(2026, 9, 26, 10, 0))))
        scheduler.failingIds = setOf(desired[1].id)

        val first = reconciler.apply(desired)
        assertEquals(listOf(desired[0].id), first.added)
        assertEquals(listOf(desired[1].id), first.failed)
        assertEquals(listOf(desired[0].id), scheduler.pendingIds)

        scheduler.failingIds = emptySet()
        val second = reconciler.apply(desired)
        assertEquals(listOf(desired[1].id), second.added)
        assertEquals(1, second.unchanged)
        assertEquals(desired.map { it.id }.toSet(), scheduler.pendingIds.toSet())
    }

    @Test
    fun nonReminderIdsInTheDesiredSetAreIgnored() = runTest {
        val scheduler = LogicFakeScheduler()
        val reconciler = ReminderReconciler(scheduler, InMemoryKeyValueStore())
        val stray = LocalNotification(id = "assigned-1", title = "t", body = "b", fireDate = now.plusSeconds(60))
        val result = reconciler.apply(listOf(stray))
        assertTrue(result.isNoOp)
        assertTrue(scheduler.added.isEmpty())
    }

    @Test
    fun fingerprintIsStableAndContentSensitive() {
        val base = LocalNotification(
            id = "due-1-2",
            title = "Échéance proche",
            body = "b",
            fireDate = now,
            userInfo = mapOf("taskId" to "1", "groupId" to "2"),
            threadId = "2",
        )
        assertEquals(ReminderReconciler.fingerprint(base), ReminderReconciler.fingerprint(base.copy()))
        val moved = base.copy(fireDate = now.plusSeconds(1))
        assertNotEquals(ReminderReconciler.fingerprint(base), ReminderReconciler.fingerprint(moved))
        val reworded = base.copy(body = "c")
        assertNotEquals(ReminderReconciler.fingerprint(base), ReminderReconciler.fingerprint(reworded))
        // The userInfo order does not matter.
        val reordered = base.copy(userInfo = linkedMapOf("groupId" to "2", "taskId" to "1"))
        assertEquals(ReminderReconciler.fingerprint(base), ReminderReconciler.fingerprint(reordered))
        assertEquals("cbf29ce484222325", StableHash.fnv1a64Hex(""))
        assertEquals("af63dc4c8601ec8c", StableHash.fnv1a64Hex("a"))
    }

    /** The fingerprints live under the iOS key, as a JSON object `{id: fingerprint}`. */
    @Test
    fun fingerprintsAreStoredUnderTheSwiftKey() = runTest {
        val store = InMemoryKeyValueStore()
        val reconciler = ReminderReconciler(LogicFakeScheduler(), store)
        val desired = plan(listOf(F.task(1, due = F.date(2026, 9, 25, 10, 0))))
        reconciler.apply(desired)
        val stored = store.value<Map<String, String>>("reminders.fingerprints")
        assertEquals(mapOf(desired[0].id to ReminderReconciler.fingerprint(desired[0])), stored)
        assertEquals("reminders.fingerprints", ReminderReconciler.FINGERPRINTS_KEY)
    }
}
