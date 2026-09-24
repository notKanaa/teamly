package io.github.notkanaa.equipe.core.logic

import io.github.notkanaa.equipe.core.InMemoryKeyValueStore
import io.github.notkanaa.equipe.core.NotificationAuthorization
import io.github.notkanaa.equipe.core.PlatformServices
import io.github.notkanaa.equipe.core.uuidString
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.async
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.time.Instant
import io.github.notkanaa.equipe.core.logic.LogicFixtures as F

/** Port of the ReminderSynchronizerTests suite of Logic/ReminderTests.swift. */
@OptIn(ExperimentalCoroutinesApi::class)
class ReminderSynchronizerTest {
    private val now: Instant = F.date(2026, 9, 24, 12, 0)

    private fun makeSynchronizer(scheduler: LogicFakeScheduler, store: InMemoryKeyValueStore): ReminderSynchronizer {
        val date = now
        return ReminderSynchronizer(scheduler, store, F.parisCalendar, now = { date })
    }

    @Test
    fun usesTheStoredLeadTime() = runTest {
        val scheduler = LogicFakeScheduler()
        val store = InMemoryKeyValueStore()
        val synchronizer = makeSynchronizer(scheduler, store)
        val tasks = listOf(F.task(1, due = F.date(2026, 9, 26, 10, 0)))

        synchronizer.synchronize(tasks, F.me)
        assertEquals(listOf(F.date(2026, 9, 26, 9, 0)), scheduler.pending.values.map { it.fireDate })

        ReminderLeadTime.ONE_DAY.save(store)
        val result = synchronizer.synchronize(tasks, F.me)
        assertEquals(1, result.replaced.size)
        assertEquals(listOf(F.date(2026, 9, 25, 10, 0)), scheduler.pending.values.map { it.fireDate })
    }

    @Test
    fun oneDayReminderAlreadyPassedIsNotScheduled() = runTest {
        val scheduler = LogicFakeScheduler()
        val store = InMemoryKeyValueStore()
        ReminderLeadTime.ONE_DAY.save(store)
        val result = makeSynchronizer(scheduler, store).synchronize(
            listOf(F.task(1, due = F.date(2026, 9, 25, 10, 0))), // fire date: 24/09 10:00 < now (12:00)
            F.me,
        )
        assertTrue(result.isNoOp)
        assertTrue(scheduler.pendingIds.isEmpty())
    }

    @Test
    fun offRemovesEverything() = runTest {
        val scheduler = LogicFakeScheduler()
        val store = InMemoryKeyValueStore()
        val synchronizer = makeSynchronizer(scheduler, store)
        val tasks = listOf(F.task(1, due = F.date(2026, 9, 25, 10, 0)), F.task(2, due = F.date(2026, 9, 26, 10, 0)))
        synchronizer.synchronize(tasks, F.me)
        assertEquals(2, scheduler.pendingIds.size)

        ReminderLeadTime.OFF.save(store)
        val result = synchronizer.synchronize(tasks, F.me)
        assertEquals(2, result.removed.size)
        assertTrue(scheduler.pendingIds.isEmpty())
    }

    @Test
    fun deniedRemovesPendingReminders() = notAuthorizedRemovesPendingReminders(NotificationAuthorization.DENIED)

    @Test
    fun notDeterminedRemovesPendingReminders() = notAuthorizedRemovesPendingReminders(NotificationAuthorization.NOT_DETERMINED)

    private fun notAuthorizedRemovesPendingReminders(status: NotificationAuthorization) = runTest {
        val scheduler = LogicFakeScheduler()
        val store = InMemoryKeyValueStore()
        val synchronizer = makeSynchronizer(scheduler, store)
        val tasks = listOf(F.task(1, due = F.date(2026, 9, 25, 10, 0)))
        synchronizer.synchronize(tasks, F.me)
        assertEquals(1, scheduler.pendingIds.size)

        scheduler.authorization = status
        synchronizer.synchronize(tasks, F.me)
        assertTrue(scheduler.pendingIds.isEmpty())
    }

    @Test
    fun capRollsForwardAsRemindersFire() = runTest {
        val scheduler = LogicFakeScheduler()
        val clock = LogicNow(now)
        val synchronizer = ReminderSynchronizer(scheduler, InMemoryKeyValueStore(), F.parisCalendar, clock.provider)
        // Task k fires at now + 3600 + 60·k (1 h before its due date).
        val start = now
        val tasks = (1..61).map { F.task(it, due = start.plusSeconds(7200L + it * 60L)) }
        val first = synchronizer.synchronize(tasks, F.me)
        assertEquals(60, first.added.size)
        assertEquals(60, scheduler.pendingIds.size)
        assertFalse(scheduler.pendingIds.any { it.contains(F.uuid(61).uuidString) })

        // Task 1's reminder is delivered (no longer pending) and time passes: task 61 takes the free slot.
        val delivered = ReminderPlanner.identifier(F.uuid(1), tasks[0].dueAt!!)
        scheduler.removePending(listOf(delivered))
        clock.value = start.plusSeconds(3600L + 61L)
        val second = synchronizer.synchronize(tasks, F.me)
        assertEquals(listOf(ReminderPlanner.identifier(F.uuid(61), tasks[60].dueAt!!)), second.added)
        assertTrue(second.removed.isEmpty())
        assertEquals(59, second.unchanged)
        assertEquals(60, scheduler.pendingIds.size)
    }

    @Test
    fun removeAllClearsReminders() = runTest {
        val scheduler = LogicFakeScheduler()
        val synchronizer = makeSynchronizer(scheduler, InMemoryKeyValueStore())
        synchronizer.synchronize(listOf(F.task(1, due = F.date(2026, 9, 25, 10, 0))), F.me)
        synchronizer.removeAll()
        assertTrue(scheduler.pendingIds.isEmpty())
    }

    /**
     * Sign-out (`removeAll`) while a "Mes tâches" reload is still scheduling: the in-flight request that the platform
     * registers late must not stay pending.
     */
    @Test
    fun removeAllDuringAnInFlightSynchronizeLeavesNoReminder() = runTest {
        val scheduler = LogicGatedScheduler(gatedCalls = setOf(1))
        val date = now
        val synchronizer = ReminderSynchronizer(scheduler, InMemoryKeyValueStore(), F.parisCalendar, now = { date })
        val tasks = listOf(F.task(1, title = "Payer le loyer", due = F.date(2026, 9, 25, 10, 0)))
        val inFlight = async { synchronizer.synchronize(tasks, F.me) }
        runCurrent()
        assertEquals("first add held", setOf(1), scheduler.waitingCalls)

        synchronizer.removeAll()
        scheduler.open(1)
        inFlight.await()

        assertTrue(
            "still pending after sign-out: ${scheduler.pending.values.map { it.body }}",
            scheduler.pending.isEmpty(),
        )
        // A later synchronization works normally.
        synchronizer.synchronize(tasks, F.me)
        assertEquals(1, scheduler.pending.size)
    }

    /**
     * Lead time changed (1 h → 15 min) while a reload is still scheduling: the two synchronizations must not
     * interleave, otherwise the stored fingerprints stop describing the pending requests and later synchronizations
     * never repair them.
     */
    @Test
    fun overlappingSynchronizationsConverge() = runTest {
        val scheduler = LogicGatedScheduler(gatedCalls = setOf(2, 5))
        val store = InMemoryKeyValueStore()
        val date = now
        val synchronizer = ReminderSynchronizer(scheduler, store, F.parisCalendar, now = { date })
        val t1 = F.task(1, due = F.date(2026, 9, 24, 15, 0))
        val t2 = F.task(2, due = F.date(2026, 9, 24, 16, 0))
        val t3 = F.task(3, due = F.date(2026, 9, 24, 17, 0))

        ReminderLeadTime.ONE_HOUR.save(store)
        val first = async { synchronizer.synchronize(listOf(t1, t2), F.me) }
        runCurrent()
        assertEquals("first synchronization held on its 2nd add", setOf(2), scheduler.waitingCalls)

        ReminderLeadTime.FIFTEEN_MINUTES.save(store)
        val second = async { synchronizer.synchronize(listOf(t1, t2, t3), F.me) }
        runCurrent()
        assertEquals("the second synchronization waits for the first", 2, scheduler.addCallCount)
        scheduler.open(2)
        first.await()
        runCurrent()
        assertEquals("5th add held", setOf(5), scheduler.waitingCalls)
        scheduler.open(5)
        second.await()

        synchronizer.synchronize(listOf(t1, t2, t3), F.me)
        synchronizer.synchronize(listOf(t1, t2, t3), F.me)
        val expected = listOf(
            t1 to F.date(2026, 9, 24, 14, 45),
            t2 to F.date(2026, 9, 24, 15, 45),
            t3 to F.date(2026, 9, 24, 16, 45),
        )
        for ((task, fire) in expected) {
            val id = ReminderPlanner.identifier(task.id, task.dueAt!!)
            assertEquals("${task.title} fires at ${scheduler.pending[id]?.fireDate}", fire, scheduler.pending[id]?.fireDate)
        }
    }

    @Test
    fun platformInitializerUsesPlatformServices() = runTest {
        val scheduler = LogicFakeScheduler()
        val date = now
        val platform = PlatformServices(
            notifications = scheduler,
            store = InMemoryKeyValueStore(),
            now = { date },
            calendar = F.parisCalendar,
        )
        val synchronizer = ReminderSynchronizer(platform)
        synchronizer.synchronize(listOf(F.task(1, due = F.date(2026, 9, 25, 10, 0))), F.me)
        assertEquals(1, scheduler.pendingIds.size)
        assertEquals(F.paris, synchronizer.planner.calendar.zone)
    }
}
