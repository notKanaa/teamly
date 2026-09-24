package io.github.notkanaa.equipe.core.logic

import io.github.notkanaa.equipe.core.AppError
import io.github.notkanaa.equipe.core.AssignmentEvent
import io.github.notkanaa.equipe.core.InMemoryKeyValueStore
import io.github.notkanaa.equipe.core.NotificationAuthorization
import io.github.notkanaa.equipe.core.uuidString
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import java.time.Instant
import java.util.UUID
import io.github.notkanaa.equipe.core.logic.LogicFixtures as F

/** Port of Logic/AssignmentNotifierTests.swift. */
class AssignmentNotifierTest {
    private val tasks = LogicFakeTaskService()
    private val scheduler = LogicFakeScheduler()
    private val store = InMemoryKeyValueStore()
    private val clock = LogicNow(F.date(2026, 9, 24, 12, 0))

    private fun makeNotifier(
        userId: UUID = F.me,
        groupName: GroupNameResolver = { null },
        rememberedLimit: Int = AssignmentNotifier.DEFAULT_REMEMBERED_LIMIT,
    ): AssignmentNotifier = AssignmentNotifier(
        userId = userId,
        tasks = tasks,
        scheduler = scheduler,
        store = store,
        now = clock.provider,
        groupName = groupName,
        rememberedLimit = rememberedLimit,
    )

    private fun event(
        number: Int,
        at: Instant,
        by: UUID? = F.other,
        group: UUID = F.groupA,
        groupName: String = "Coloc' rue des Lilas",
    ): AssignmentEvent = AssignmentEvent(
        taskId = F.uuid(number),
        groupId = group,
        taskTitle = "Tâche $number",
        groupName = groupName,
        assignedBy = by,
        assignedAt = at,
        dueAt = null,
    )

    private fun realtime(number: Int, by: UUID? = F.other): RealtimeAssignment =
        RealtimeAssignment(F.uuid(number), F.groupA, by)

    /** Initializes the cursor to the current fake date. */
    private suspend fun initializedNotifier(): AssignmentNotifier {
        val notifier = makeNotifier()
        notifier.catchUp()
        return notifier
    }

    private fun assignedId(number: Int): String = "assigned-${F.uuid(number).uuidString}"

    // region Catch-up

    /** History is not notified; the cursor is the latest existing assignment (a server timestamp). */
    @Test
    fun firstCatchUpOnlyInitializesTheCursor() = runTest {
        val history = clock.value.minusSeconds(3600)
        tasks.assignmentEvents = listOf(event(2, history.minusSeconds(60)), event(1, history))
        val notifier = makeNotifier()
        val posted = notifier.catchUp()
        assertTrue(posted.isEmpty())
        assertEquals(listOf(clock.value.minus(AssignmentNotifier.INITIAL_LOOKBACK)), tasks.sinceCalls)
        assertEquals(history, notifier.cursor)
        assertTrue(scheduler.added.isEmpty())

        // The next catch-up re-reads the overlap before the cursor: history stays silent.
        clock.value = clock.value.plusSeconds(60)
        assertTrue(notifier.catchUp().isEmpty())
        assertEquals(history.minus(AssignmentNotifier.CATCH_UP_OVERLAP), tasks.sinceCalls.last())
        assertTrue(scheduler.added.isEmpty())
    }

    /**
     * Without any assignment yet, the cursor is the start of the lookback period: everything assigned later is new,
     * whatever the device clock says.
     */
    @Test
    fun firstCatchUpWithoutHistoryStartsAtTheLookback() = runTest {
        val notifier = makeNotifier()
        notifier.catchUp()
        assertEquals(clock.value.minus(AssignmentNotifier.INITIAL_LOOKBACK), notifier.cursor)
    }

    @Test
    fun upToFiveAssignmentsAreNotifiedIndividually() = runTest {
        val notifier = initializedNotifier()
        val start = clock.value
        val cursor = notifier.cursor!!
        tasks.assignmentEvents = (1..5).map { event(it, start.plusSeconds(it.toLong())) }
        clock.value = start.plusSeconds(60)

        val posted = notifier.catchUp()
        assertEquals(cursor.minus(AssignmentNotifier.CATCH_UP_OVERLAP), tasks.sinceCalls.last())
        assertEquals(5, posted.size)
        assertEquals((1..5).map { assignedId(it) }, posted.map { it.id })
        val first = posted.first()
        assertEquals("Nouvelle tâche", first.title)
        assertEquals("Tâche 1 — Coloc' rue des Lilas", first.body)
        assertNull(first.fireDate)
        assertEquals(mapOf("taskId" to F.uuid(1).uuidString, "groupId" to F.groupA.uuidString), first.userInfo)
        assertEquals(F.groupA.uuidString, first.threadId)
        assertEquals(posted, scheduler.added)
        assertEquals(start.plusSeconds(5), notifier.cursor)

        // Nothing new: the next catch-up re-reads the overlap before the new cursor and posts nothing.
        val again = notifier.catchUp()
        assertTrue(again.isEmpty())
        assertEquals(start.plusSeconds(5).minus(AssignmentNotifier.CATCH_UP_OVERLAP), tasks.sinceCalls.last())
    }

    @Test
    fun sixAssignmentsGiveASingleSummary() = runTest {
        val notifier = initializedNotifier()
        val start = clock.value
        tasks.assignmentEvents = (1..6).map { event(it, start.plusSeconds(it.toLong())) }
        clock.value = start.plusSeconds(120)

        val posted = notifier.catchUp()
        assertEquals(1, posted.size)
        val summary = posted.first()
        assertEquals("summary-${ReminderPlanner.epochSeconds(clock.value)}", summary.id)
        assertEquals(AssignmentNotifier.summaryIdentifier(clock.value), summary.id)
        assertEquals("Nouvelles tâches", summary.title)
        assertEquals("6 nouvelles tâches assignées", summary.body)
        assertNull(summary.fireDate)
        assertEquals(mapOf("groupId" to F.groupA.uuidString), summary.userInfo)
        assertEquals(F.groupA.uuidString, summary.threadId)
        assertEquals((1..6).map { F.uuid(it) }.toSet(), notifier.rememberedTaskIds.toSet())

        // The summarized tasks are not notified again by realtime.
        tasks.put(F.task(3))
        assertTrue(notifier.handleRealtime(realtime(3)).isEmpty())
    }

    @Test
    fun summaryAcrossGroupsHasNoRoutingInfo() = runTest {
        val notifier = initializedNotifier()
        val start = clock.value
        tasks.assignmentEvents = (1..7).map {
            event(it, start.plusSeconds(it.toLong()), group = if (it % 2 == 0) F.groupA else F.groupB)
        }
        val posted = notifier.catchUp()
        assertEquals(1, posted.size)
        assertEquals("7 nouvelles tâches assignées", posted.first().body)
        assertEquals(emptyMap<String, String>(), posted.first().userInfo)
        assertNull(posted.first().threadId)
    }

    @Test
    fun alreadyNotifiedAssignmentsDoNotCountTowardsTheSummary() = runTest {
        val notifier = initializedNotifier()
        val start = clock.value
        for (number in 1..2) {
            tasks.put(F.task(number))
            notifier.handleRealtime(realtime(number))
        }
        assertEquals(2, scheduler.added.size)
        tasks.assignmentEvents = (1..7).map { event(it, start.plusSeconds(it.toLong())) }

        val posted = notifier.catchUp()
        assertEquals((3..7).map { assignedId(it) }, posted.map { it.id })
    }

    @Test
    fun selfAssignmentsAreIgnoredButAdvanceTheCursor() = runTest {
        val notifier = initializedNotifier()
        val start = clock.value
        tasks.assignmentEvents = listOf(
            event(1, start.plusSeconds(1), by = F.me),
            event(2, start.plusSeconds(2), by = F.me),
        )
        val posted = notifier.catchUp()
        assertTrue(posted.isEmpty())
        assertTrue(scheduler.added.isEmpty())
        assertEquals(start.plusSeconds(2), notifier.cursor)

        tasks.put(F.task(3))
        assertTrue(notifier.handleRealtime(realtime(3, by = F.me)).isEmpty())
        assertTrue(tasks.lookups.isEmpty())
    }

    @Test
    fun assignmentByADeletedAccountIsNotified() = runTest {
        val notifier = initializedNotifier()
        tasks.assignmentEvents = listOf(event(1, clock.value.plusSeconds(1), by = null))
        assertEquals(1, notifier.catchUp().size)

        tasks.put(F.task(2))
        assertEquals(1, notifier.handleRealtime(realtime(2, by = null)).size)
    }

    @Test
    fun catchUpErrorKeepsTheCursor() = runTest {
        val notifier = initializedNotifier()
        val cursor = notifier.cursor
        tasks.assignmentsError = AppError.Network
        try {
            notifier.catchUp()
            fail("expected AppError.Network")
        } catch (error: AppError) {
            assertEquals(AppError.Network, error)
        }
        assertEquals(cursor, notifier.cursor)

        tasks.assignmentsError = null
        tasks.assignmentEvents = listOf(event(1, clock.value.plusSeconds(1)))
        assertEquals(1, notifier.catchUp().size)
    }

    /**
     * Device clock 10 minutes ahead of the server: the cursor must come from server data, not from the device date,
     * or assignments made during the skew window are never caught up.
     */
    @Test
    fun deviceClockAheadDoesNotLoseAssignmentsAfterTheFirstCatchUp() = runTest {
        val serverNow = clock.value
        clock.value = serverNow.plusSeconds(600)
        val notifier = initializedNotifier()

        // Server 12:02: an assignment while the app is in background.
        tasks.assignmentEvents = listOf(event(1, serverNow.plusSeconds(120)))
        clock.value = clock.value.plusSeconds(3600)
        val posted = notifier.catchUp()
        assertEquals(listOf(assignedId(1)), posted.map { it.id })
    }

    /**
     * `assigned_at` is the transaction START time: a row can become visible after a newer one that catch-up already
     * handled. It must still be notified (once).
     */
    @Test
    fun assignmentCommittedAfterANewerOneIsNotified() = runTest {
        val notifier = initializedNotifier()
        val start = clock.value
        clock.value = start.plusSeconds(2)
        tasks.assignmentEvents = listOf(event(2, start.plusMillis(1_020)))
        assertEquals(1, notifier.catchUp().size)

        tasks.assignmentEvents = tasks.assignmentEvents + event(1, start.plusMillis(1_000))
        clock.value = start.plusSeconds(60)
        val posted = notifier.catchUp()
        assertEquals(listOf(assignedId(1)), posted.map { it.id })
        assertTrue(notifier.catchUp().isEmpty())
        assertEquals(2, scheduler.added.size)
    }

    /** A transient `add` failure during catch-up is retried by the next catch-up. */
    @Test
    fun failedCatchUpPostIsRetried() = runTest {
        val notifier = initializedNotifier()
        val start = clock.value
        tasks.assignmentEvents = listOf(event(1, start.plusSeconds(1)), event(2, start.plusSeconds(2)))
        scheduler.failingIds = setOf(assignedId(1))
        clock.value = start.plusSeconds(10)
        assertEquals(listOf(assignedId(2)), notifier.catchUp().map { it.id })

        scheduler.failingIds = emptySet()
        clock.value = start.plusSeconds(20)
        assertEquals(listOf(assignedId(1)), notifier.catchUp().map { it.id })
        assertTrue(notifier.catchUp().isEmpty())
    }

    @Test
    fun failedSummaryIsRetried() = runTest {
        val notifier = initializedNotifier()
        val start = clock.value
        tasks.assignmentEvents = (1..6).map { event(it, start.plusSeconds(it.toLong())) }
        clock.value = start.plusSeconds(10)
        scheduler.failingIds = setOf(AssignmentNotifier.summaryIdentifier(clock.value))
        assertTrue(notifier.catchUp().isEmpty())

        clock.value = start.plusSeconds(20)
        val posted = notifier.catchUp()
        assertEquals(listOf("6 nouvelles tâches assignées"), posted.map { it.body })
        assertTrue(notifier.catchUp().isEmpty())
    }

    // endregion

    // region Realtime

    @Test
    fun realtimeLooksUpTheTask() = runTest {
        val notifier = makeNotifier()
        tasks.put(F.task(1, title = "Sortir les poubelles"))
        val posted = notifier.handleRealtime(realtime(1))
        assertEquals(listOf(F.uuid(1)), tasks.lookups)
        assertEquals(1, posted.size)
        val notification = posted.first()
        assertEquals(assignedId(1), notification.id)
        assertEquals(AssignmentNotifier.individualIdentifier(F.uuid(1)), notification.id)
        assertEquals("Nouvelle tâche", notification.title)
        assertEquals("Sortir les poubelles — Coloc' rue des Lilas", notification.body)
        assertEquals(mapOf("taskId" to F.uuid(1).uuidString, "groupId" to F.groupA.uuidString), notification.userInfo)
        assertNull(notification.fireDate)
    }

    @Test
    fun realtimeResolvesTheGroupNameWhenTheTaskHasNone() = runTest {
        val resolved = makeNotifier(groupName = { id -> if (id == F.groupA) "Projet Asso Sport" else null })
        tasks.put(F.task(1, title = "Réserver le gymnase", groupName = null))
        assertEquals("Réserver le gymnase — Projet Asso Sport", resolved.handleRealtime(realtime(1)).first().body)

        val unresolved = makeNotifier(userId = F.me)
        tasks.put(F.task(2, title = "Créer l'affiche", group = F.groupB, groupName = null))
        val posted = unresolved.handleRealtime(RealtimeAssignment(F.uuid(2), F.groupB, F.other))
        assertEquals("Créer l'affiche", posted.first().body)
    }

    /** Kotlin resolvers can throw: a failure counts as "no name", the assignment is still notified. */
    @Test
    fun failingGroupNameResolverStillNotifies() = runTest {
        val notifier = makeNotifier(groupName = { throw AppError.Network })
        tasks.put(F.task(1, title = "Réserver le gymnase", groupName = null))
        assertEquals(listOf("Réserver le gymnase"), notifier.handleRealtime(realtime(1)).map { it.body })
    }

    @Test
    fun realtimeDuplicateDeliveryIsNotifiedOnce() = runTest {
        val notifier = makeNotifier()
        tasks.put(F.task(1))
        assertEquals(1, notifier.handleRealtime(realtime(1)).size)
        assertTrue(notifier.handleRealtime(realtime(1)).isEmpty())
        assertEquals(1, scheduler.added.size)
    }

    @Test
    fun realtimeThenCatchUpIsNotifiedOnce() = runTest {
        val notifier = initializedNotifier()
        tasks.put(F.task(1))
        clock.value = clock.value.plusSeconds(10)
        assertEquals(1, notifier.handleRealtime(realtime(1)).size)

        // The server timestamp may even be slightly after the device's notification date (clock skew).
        tasks.assignmentEvents = listOf(event(1, clock.value.plusSeconds(2)))
        clock.value = clock.value.plusSeconds(600)
        assertTrue(notifier.catchUp().isEmpty())
        assertEquals(1, scheduler.added.size)
        assertEquals(tasks.assignmentEvents[0].assignedAt, notifier.cursor)
    }

    @Test
    fun catchUpThenRealtimeIsNotifiedOnce() = runTest {
        val notifier = initializedNotifier()
        tasks.put(F.task(1))
        tasks.assignmentEvents = listOf(event(1, clock.value.plusSeconds(1)))
        clock.value = clock.value.plusSeconds(2)
        assertEquals(1, notifier.catchUp().size)

        clock.value = clock.value.plusSeconds(1)
        assertTrue(notifier.handleRealtime(realtime(1)).isEmpty())
        assertTrue(tasks.lookups.isEmpty())
        assertEquals(1, scheduler.added.size)
    }

    /** Really concurrent callers (threads of `Dispatchers.Default`): the mutex serializes them. */
    @Test
    fun concurrentRealtimeAndCatchUpNotifyOnce() = runBlocking {
        repeat(20) {
            val tasks = LogicFakeTaskService()
            val scheduler = LogicFakeScheduler()
            val clock = LogicNow(F.date(2026, 9, 24, 12, 0))
            val notifier = AssignmentNotifier(F.me, tasks, scheduler, InMemoryKeyValueStore(), now = clock.provider)
            notifier.catchUp()
            tasks.put(F.task(1))
            tasks.assignmentEvents = listOf(event(1, clock.value.plusSeconds(1)))
            clock.value = clock.value.plusSeconds(2)

            val fromRealtime = async(Dispatchers.Default) { notifier.handleRealtime(realtime(1)) }
            val fromCatchUp = async(Dispatchers.Default) { notifier.catchUp() }
            assertEquals(1, fromRealtime.await().size + fromCatchUp.await().size)
            assertEquals(1, scheduler.added.size)
        }
    }

    @Test
    fun failedLookupIsLeftToCatchUp() = runTest {
        val notifier = initializedNotifier()
        // The task is not readable yet (or the network failed): nothing is posted nor remembered…
        assertTrue(notifier.handleRealtime(realtime(1)).isEmpty())
        assertTrue(notifier.rememberedTaskIds.isEmpty())
        // …so the next catch-up notifies it.
        tasks.assignmentEvents = listOf(event(1, clock.value.plusSeconds(1)))
        assertEquals(1, notifier.catchUp().size)
    }

    @Test
    fun realtimeForATaskNoLongerAssignedToMeIsSkipped() = runTest {
        val notifier = makeNotifier()
        tasks.put(F.task(1, assignees = listOf(F.other)))
        assertTrue(notifier.handleRealtime(realtime(1)).isEmpty())
    }

    @Test
    fun reassignmentIsNotifiedAgain() = runTest {
        val notifier = initializedNotifier()
        val start = clock.value
        tasks.assignmentEvents = listOf(event(1, start.plusSeconds(1)))
        assertEquals(1, notifier.catchUp().size)

        // Unassigned then assigned again later: a newer assignedAt.
        tasks.assignmentEvents = listOf(event(1, start.plusSeconds(3600)))
        clock.value = start.plusSeconds(3601)
        assertEquals(1, notifier.catchUp().size)
        assertEquals(2, scheduler.added.size)

        // Realtime reassignment long after the previous notification.
        clock.value = clock.value.plus(AssignmentNotifier.REALTIME_DEDUP_WINDOW).plusSeconds(1)
        tasks.put(F.task(1))
        assertEquals(1, notifier.handleRealtime(realtime(1)).size)
    }

    // endregion

    // region Authorization

    @Test
    fun notAuthorizedPostsNothingButAdvancesTheCursor() = runTest {
        val notifier = initializedNotifier()
        val start = clock.value
        scheduler.authorization = NotificationAuthorization.DENIED
        tasks.assignmentEvents = (1..3).map { event(it, start.plusSeconds(it.toLong())) }

        assertTrue(notifier.catchUp().isEmpty())
        assertEquals(start.plusSeconds(3), notifier.cursor)
        assertTrue(scheduler.added.isEmpty())

        tasks.put(F.task(9))
        assertTrue(notifier.handleRealtime(realtime(9)).isEmpty())
        assertTrue(tasks.lookups.isEmpty())

        // Once authorized, only newer assignments are notified.
        scheduler.authorization = NotificationAuthorization.AUTHORIZED
        tasks.assignmentEvents = tasks.assignmentEvents + event(4, start.plusSeconds(4))
        val posted = notifier.catchUp()
        assertEquals(listOf(assignedId(4)), posted.map { it.id })
    }

    @Test
    fun notDeterminedIsTreatedAsNotGranted() = runTest {
        val notifier = initializedNotifier()
        scheduler.authorization = NotificationAuthorization.NOT_DETERMINED
        tasks.assignmentEvents = listOf(event(1, clock.value.plusSeconds(1)))
        assertTrue(notifier.catchUp().isEmpty())
        assertTrue(scheduler.added.isEmpty())
    }

    // endregion

    // region Persistence

    @Test
    fun rememberedSetIsBounded() = runTest {
        val notifier = makeNotifier(rememberedLimit = 3)
        for (number in 1..5) {
            tasks.put(F.task(number))
            notifier.handleRealtime(realtime(number))
        }
        assertEquals(listOf(F.uuid(3), F.uuid(4), F.uuid(5)), notifier.rememberedTaskIds)
    }

    @Test
    fun stateSurvivesANewInstance() = runTest {
        val first = initializedNotifier()
        tasks.put(F.task(1))
        assertEquals(1, first.handleRealtime(realtime(1)).size)
        val cursor = first.cursor

        val second = makeNotifier()
        assertEquals(cursor, second.cursor)
        assertEquals(listOf(F.uuid(1)), second.rememberedTaskIds)
        assertTrue(second.handleRealtime(realtime(1)).isEmpty())
        assertNotNull(store.data(AssignmentNotifier.storageKey(F.me)))
    }

    @Test
    fun stateIsPerUser() = runTest {
        val mine = initializedNotifier()
        tasks.put(F.task(1, assignees = listOf(F.me, F.other)))
        assertEquals(1, mine.handleRealtime(realtime(1)).size)

        val theirs = makeNotifier(userId = F.other)
        assertNull(theirs.cursor)
        assertTrue(theirs.rememberedTaskIds.isEmpty())
        val posted = theirs.handleRealtime(RealtimeAssignment(F.uuid(1), F.groupA, F.me))
        assertEquals(1, posted.size)
    }

    @Test
    fun resetForgetsEverything() = runTest {
        val notifier = initializedNotifier()
        tasks.put(F.task(1))
        notifier.handleRealtime(realtime(1))
        notifier.reset()
        assertNull(notifier.cursor)
        assertTrue(notifier.rememberedTaskIds.isEmpty())
    }

    @Test
    fun failedPostIsNotRemembered() = runTest {
        val notifier = makeNotifier()
        tasks.put(F.task(1))
        scheduler.failingIds = setOf(assignedId(1))
        assertTrue(notifier.handleRealtime(realtime(1)).isEmpty())
        assertTrue(notifier.rememberedTaskIds.isEmpty())
        scheduler.failingIds = emptySet()
        assertEquals(1, notifier.handleRealtime(realtime(1)).size)
    }

    /** One JSON entry per user under the iOS key; timestamps keep their full precision. */
    @Test
    fun stateIsStoredAsJsonUnderTheSwiftKey() = runTest {
        val notifier = initializedNotifier()
        tasks.put(F.task(1))
        notifier.handleRealtime(realtime(1))
        assertEquals("assignments.state.00000000-0000-0000-0000-00000000000A", AssignmentNotifier.storageKey(F.me))
        val json = store.data(AssignmentNotifier.storageKey(F.me))?.decodeToString()
        assertEquals(
            "{\"cursor\":\"2026-09-17T10:00:00Z\",\"notified\":[{\"taskId\":\"10000000-0000-0000-0000-000000000001\"," +
                "\"notifiedAt\":\"2026-09-24T10:00:00Z\"}]}",
            json,
        )

        val precise = clock.value.plusNanos(123_456_789)
        tasks.assignmentEvents = listOf(event(2, precise))
        notifier.catchUp()
        assertEquals(precise, makeNotifier().cursor)
    }

    // endregion
}
