package io.github.notkanaa.equipe.core.logic

import io.github.notkanaa.equipe.core.AppError
import io.github.notkanaa.equipe.core.InMemoryKeyValueStore
import io.github.notkanaa.equipe.core.RealtimeEvent
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.Job
import kotlinx.coroutines.cancel
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.UnconfinedTestDispatcher
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.IOException
import java.util.UUID
import kotlin.time.Duration
import kotlin.time.Duration.Companion.milliseconds
import kotlin.time.Duration.Companion.seconds
import io.github.notkanaa.equipe.core.logic.LogicFixtures as F
import io.github.notkanaa.equipe.core.logic.RealtimeCoordinator.BumpKey as Key

/**
 * Port of the RealtimeCoordinatorTests suite of Logic/RealtimeCoordinatorTests.swift. Swift's manual clock is replaced
 * by virtual time: every coroutine of the coordinator runs in the test's `backgroundScope`, `runCurrent()` lets the
 * already-scheduled work run (Swift `LogicWait`), `advance` moves the virtual clock (Swift `clock.advance(by:)`).
 */
@OptIn(ExperimentalCoroutinesApi::class)
class RealtimeCoordinatorTest {
    private val realtime = LogicFakeRealtime()
    private val feed = ChangeFeed()
    private val sleepers = LogicSleepers()
    private val groups = LogicGroupIdsSource(listOf(F.groupA))
    private val sink = LogicAssignmentSink()

    private fun TestScope.makeCoordinator(
        scope: CoroutineScope = backgroundScope,
        debounce: Duration = RealtimeCoordinator.DEFAULT_DEBOUNCE,
        onAssigned: AssignmentHandler? = { sink.receive(it) },
    ): RealtimeCoordinator = RealtimeCoordinator(
        realtime = realtime,
        userId = F.me,
        feed = feed,
        scope = scope,
        groupIdsProvider = { groups.fetch() },
        debounce = debounce,
        retryDelay = RealtimeCoordinator.DEFAULT_RETRY_DELAY,
        onAssigned = onAssigned,
        sleep = sleepers.sleep,
    )

    /** Starts a coordinator and lets it subscribe. */
    private fun TestScope.started(groupIds: List<UUID>? = null): RealtimeCoordinator {
        val coordinator = makeCoordinator()
        coordinator.start(groupIds)
        runCurrent()
        assertEquals("first subscription", 1, realtime.subscriptionCount)
        return coordinator
    }

    /** Sends events on the current subscription and lets the coordinator handle them. */
    private fun TestScope.send(coordinator: RealtimeCoordinator, vararg events: RealtimeEvent) {
        val target = coordinator.handledEventCount + events.size
        for (event in events) realtime.send(event)
        runCurrent()
        assertEquals("${events.size} handled event(s)", target, coordinator.handledEventCount)
    }

    /** Moves the virtual clock forward and runs what became due. */
    private fun TestScope.advance(duration: Duration) {
        advanceTimeBy(duration)
        runCurrent()
    }

    // region Subscription

    @Test
    fun subscribesWithTheProvidedGroupIds() = runTest {
        groups.ids = listOf(F.groupB, F.groupA, F.groupB)
        val coordinator = started()
        assertEquals(F.me, realtime.userId(0))
        assertEquals(setOf(F.groupA, F.groupB), realtime.groupIds(0).toSet())
        // Deduplicated and sorted by uuidString.
        assertEquals(listOf(F.groupA, F.groupB), realtime.groupIds(0))
        assertEquals(realtime.groupIds(0), coordinator.subscribedGroupIds)
        assertTrue(coordinator.isRunning)
        assertEquals(1, groups.calls)
        coordinator.stop()
    }

    @Test
    fun initialGroupIdsSkipTheProvider() = runTest {
        val coordinator = started(groupIds = listOf(F.groupB))
        assertEquals(listOf(F.groupB), realtime.groupIds(0))
        assertEquals(0, groups.calls)
        coordinator.stop()
    }

    @Test
    fun startIsIdempotent() = runTest {
        val coordinator = started()
        coordinator.start()
        runCurrent()
        assertEquals(1, realtime.subscriptionCount)
        coordinator.stop()
    }

    @Test
    fun failingProviderSubscribesWithoutGroups() = runTest {
        groups.fails = true
        val coordinator = started()
        assertTrue(realtime.groupIds(0).isEmpty())
        coordinator.stop()
    }

    // endregion

    // region Mapping and debounce

    @Test
    fun connectedBumpsAllImmediately() = runTest {
        val coordinator = started()
        send(coordinator, RealtimeEvent.Connected)
        assertEquals(1, feed.allRevision.value)
        assertEquals(1, feed.membershipsRevision.value)
        assertEquals(1, feed.myTasksRevision.value)
        assertEquals(0, sleepers.count)
        coordinator.stop()
    }

    @Test
    fun groupActivityIsDebouncedPerKey() = runTest {
        val coordinator = started()
        send(
            coordinator,
            RealtimeEvent.GroupActivity(F.groupA),
            RealtimeEvent.GroupActivity(F.groupA),
            RealtimeEvent.GroupActivity(F.groupB),
            RealtimeEvent.GroupActivity(F.groupA),
        )
        assertEquals(setOf(Key.Group(F.groupA), Key.Group(F.groupB), Key.MyTasks), coordinator.pendingBumpKeys)
        assertEquals("3 debounce timers", 3, sleepers.count)
        assertEquals(0, feed.groupRevision(F.groupA))
        assertEquals(0, feed.myTasksRevision.value)

        advance(299.milliseconds)
        assertEquals(0, feed.groupRevision(F.groupA))
        assertEquals(0, feed.groupRevision(F.groupB))
        assertEquals(0, feed.myTasksRevision.value)

        advance(1.milliseconds)
        assertTrue("coalesced bumps", coordinator.pendingBumpKeys.isEmpty())
        assertEquals(1, feed.groupRevision(F.groupA))
        assertEquals(1, feed.groupRevision(F.groupB))
        assertEquals(1, feed.myTasksRevision.value)
        assertEquals(0, feed.membershipsRevision.value)
        coordinator.stop()
    }

    @Test
    fun aNewWindowOpensAfterAFlush() = runTest {
        val coordinator = started()
        send(coordinator, RealtimeEvent.GroupActivity(F.groupA))
        assertEquals(2, sleepers.count)
        advance(300.milliseconds)
        assertEquals(1, feed.groupRevision(F.groupA))
        assertEquals(1, feed.myTasksRevision.value)

        send(coordinator, RealtimeEvent.GroupActivity(F.groupA))
        assertEquals("new timers", 2, sleepers.count)
        assertEquals(1, feed.groupRevision(F.groupA))
        advance(300.milliseconds)
        assertEquals(2, feed.groupRevision(F.groupA))
        assertEquals(2, feed.myTasksRevision.value)
        coordinator.stop()
    }

    @Test
    fun burstLongerThanTheWindowBumpsAtMostOncePerWindow() = runTest {
        val coordinator = started()
        send(coordinator, RealtimeEvent.GroupActivity(F.groupA))
        assertEquals(2, sleepers.count)
        advance(200.milliseconds)
        send(coordinator, RealtimeEvent.GroupActivity(F.groupA)) // coalesced into the open window
        advance(100.milliseconds)
        assertTrue("flush", coordinator.pendingBumpKeys.isEmpty())
        assertEquals(1, feed.groupRevision(F.groupA))
        coordinator.stop()
    }

    @Test
    fun connectedSupersedesPendingBumps() = runTest {
        val coordinator = started()
        send(coordinator, RealtimeEvent.GroupActivity(F.groupA), RealtimeEvent.MembershipsChanged)
        assertEquals(3, sleepers.count)
        send(coordinator, RealtimeEvent.Connected)
        assertEquals("timers cancelled", 0, sleepers.count)
        assertTrue(coordinator.pendingBumpKeys.isEmpty())
        advance(1.seconds)
        assertEquals(1, feed.groupRevision(F.groupA))
        assertEquals(1, feed.membershipsRevision.value)
        assertEquals(1, feed.myTasksRevision.value)
        coordinator.stop()
    }

    @Test
    fun reconnectBumpsAllEveryTime() = runTest {
        val coordinator = started()
        send(coordinator, RealtimeEvent.Connected)
        send(coordinator, RealtimeEvent.Connected)
        assertEquals(2, feed.allRevision.value)
        assertEquals(2, feed.groupRevision(F.groupB))
        coordinator.stop()
    }

    /** A zero debounce (view-model tests) bumps as soon as the event is handled. */
    @Test
    fun zeroDebounceBumpsRightAway() = runTest {
        val coordinator = makeCoordinator(debounce = Duration.ZERO)
        coordinator.start()
        runCurrent()
        send(coordinator, RealtimeEvent.GroupActivity(F.groupA), RealtimeEvent.MembershipsChanged)
        assertEquals(1, feed.groupRevision(F.groupA))
        assertEquals(1, feed.membershipsRevision.value)
        assertEquals(1, feed.myTasksRevision.value)
        assertTrue(coordinator.pendingBumpKeys.isEmpty())
        coordinator.stop()
    }

    // endregion

    // region Memberships

    @Test
    fun membershipsChangeWithSameGroupsKeepsTheSubscription() = runTest {
        val coordinator = started()
        send(coordinator, RealtimeEvent.MembershipsChanged)
        assertEquals("provider refreshed", 2, groups.calls)
        assertEquals(2, sleepers.count)
        advance(300.milliseconds)
        assertEquals(1, feed.membershipsRevision.value)
        assertEquals(1, feed.myTasksRevision.value)
        assertEquals(1, realtime.subscriptionCount)
        assertFalse(realtime.isTerminated(0))
        assertEquals(0, feed.allRevision.value)
        coordinator.stop()
    }

    @Test
    fun membershipsChangeResubscribesWithFreshGroupIds() = runTest {
        val coordinator = started()
        groups.ids = listOf(F.groupA, F.groupB)
        send(coordinator, RealtimeEvent.MembershipsChanged)
        assertEquals("resubscription", 2, realtime.subscriptionCount)
        assertEquals(setOf(F.groupA, F.groupB), realtime.groupIds(1).toSet())
        assertEquals(realtime.groupIds(1), coordinator.subscribedGroupIds)
        assertTrue("old stream terminated", realtime.isTerminated(0))
        assertFalse(realtime.isTerminated(1))

        // The new subscription emits Connected: one bumpAll covers the pending debounced bumps.
        send(coordinator, RealtimeEvent.Connected)
        assertEquals(1, feed.allRevision.value)
        assertEquals("timers cancelled", 0, sleepers.count)
        advance(1.seconds)
        assertEquals(1, feed.membershipsRevision.value)
        assertEquals(1, feed.myTasksRevision.value)

        // Events of the new subscription are handled.
        send(coordinator, RealtimeEvent.GroupActivity(F.groupB))
        assertEquals(2, sleepers.count)
        advance(300.milliseconds)
        assertEquals(2, feed.groupRevision(F.groupB))
        coordinator.stop()
    }

    @Test
    fun membershipsChangeWithFailingProviderKeepsTheSubscription() = runTest {
        val coordinator = started()
        groups.fails = true
        send(coordinator, RealtimeEvent.MembershipsChanged)
        assertEquals("provider called", 2, groups.calls)
        send(coordinator, RealtimeEvent.GroupActivity(F.groupA))
        assertEquals(1, realtime.subscriptionCount)
        assertFalse(realtime.isTerminated(0))
        assertTrue(coordinator.groupIdsAreStale)
        coordinator.stop()
        assertFalse(coordinator.groupIdsAreStale)
    }

    // endregion

    // region Stale group ids (the Supabase stream never ends by itself)

    /**
     * Cold start offline: the first fetch fails, the channel is subscribed without groups; the `Connected` of the
     * reconnected socket fetches them again.
     */
    @Test
    fun failedInitialFetchIsRetriedOnConnected() = runTest {
        groups.fails = true
        val coordinator = started()
        assertTrue(realtime.groupIds(0).isEmpty())
        assertTrue(coordinator.groupIdsAreStale)

        groups.fails = false
        send(coordinator, RealtimeEvent.Connected)
        assertEquals(1, feed.allRevision.value)
        assertEquals("resubscribed with the groups", 2, realtime.subscriptionCount)
        assertEquals(listOf(F.groupA), realtime.groupIds(1))
        assertEquals(listOf(F.groupA), coordinator.subscribedGroupIds)
        assertFalse(coordinator.groupIdsAreStale)
        assertTrue("old stream terminated", realtime.isTerminated(0))
        assertEquals("retry timer cancelled", 0, sleepers.count)

        // The new subscription's first `Connected` does not fetch again (its ids are fresh).
        send(coordinator, RealtimeEvent.Connected)
        assertEquals(2, groups.calls)
        assertEquals(2, realtime.subscriptionCount)
        coordinator.stop()
    }

    /** A membership change missed while the socket was down: every reconnection fetches the group ids again. */
    @Test
    fun reconnectionFetchesTheGroupIdsAgain() = runTest {
        val coordinator = started()
        send(coordinator, RealtimeEvent.Connected)
        assertEquals("the first Connected of fresh ids does not fetch", 1, groups.calls)

        groups.ids = listOf(F.groupA, F.groupB)
        send(coordinator, RealtimeEvent.Connected)
        assertEquals("resubscribed", 2, realtime.subscriptionCount)
        assertEquals(2, groups.calls)
        assertEquals(setOf(F.groupA, F.groupB), realtime.groupIds(1).toSet())
        assertEquals(2, feed.allRevision.value)
        coordinator.stop()
    }

    @Test
    fun reconnectionWithTheSameGroupsKeepsTheSubscription() = runTest {
        val coordinator = started()
        send(coordinator, RealtimeEvent.Connected, RealtimeEvent.Connected)
        assertEquals("provider called", 2, groups.calls)
        assertEquals(1, realtime.subscriptionCount)
        assertFalse(realtime.isTerminated(0))
        coordinator.stop()
    }

    /** A failed fetch is retried after `retryDelay`, doubled after each failure, without waiting for an event. */
    @Test
    fun failedRefreshIsRetriedWithBackoff() = runTest {
        val coordinator = started()
        groups.fails = true
        groups.ids = listOf(F.groupA, F.groupB)
        send(coordinator, RealtimeEvent.MembershipsChanged)
        assertEquals("refresh failed", 2, groups.calls)
        assertTrue(coordinator.groupIdsAreStale)
        assertEquals("debounce timers and retry timer", 3, sleepers.count)
        advance(300.milliseconds)
        assertEquals(1, feed.membershipsRevision.value)
        assertEquals(1, sleepers.count)

        advance(4_699.milliseconds)
        assertEquals(2, groups.calls)
        advance(1.milliseconds)
        assertEquals("first retry (5 s)", 3, groups.calls)
        assertEquals("second retry timer", 1, sleepers.count)

        groups.fails = false
        advance(9.seconds)
        assertEquals(3, groups.calls)
        advance(1.seconds)
        assertEquals("second retry (10 s) resubscribes", 2, realtime.subscriptionCount)
        assertEquals(setOf(F.groupA, F.groupB), realtime.groupIds(1).toSet())
        assertFalse(coordinator.groupIdsAreStale)
        assertEquals("no timer left", 0, sleepers.count)
        coordinator.stop()
    }

    /** The retry delay doubles up to 60 s. */
    @Test
    fun retryDelayIsCappedAtOneMinute() = runTest {
        groups.fails = true
        val coordinator = started()
        // Initial fetch failed: retries after 5, 10, 20, 40, then 60 s (capped), 60 s…
        var calls = 1
        for (wait in listOf(5, 10, 20, 40, 60, 60).map { it.seconds }) {
            advance(wait - 1.milliseconds)
            assertEquals("before the $wait wait ends", calls, groups.calls)
            advance(1.milliseconds)
            calls += 1
            assertEquals("after $wait", calls, groups.calls)
        }
        coordinator.stop()
    }

    @Test
    fun refreshGroupIdsResubscribesOnlyWhenTheyChanged() = runTest {
        val coordinator = started()
        coordinator.refreshGroupIds()
        runCurrent()
        assertEquals("provider called", 2, groups.calls)
        assertEquals(1, realtime.subscriptionCount)

        groups.ids = listOf(F.groupB)
        coordinator.refreshGroupIds()
        runCurrent()
        assertEquals("resubscribed", 2, realtime.subscriptionCount)
        assertEquals(listOf(F.groupB), realtime.groupIds(1))
        coordinator.stop()

        coordinator.refreshGroupIds()
        runCurrent()
        assertEquals("no fetch once stopped", 3, groups.calls)
    }

    @Test
    fun concurrentRefreshRequestsAreCoalesced() = runTest {
        val coordinator = started()
        coordinator.refreshGroupIds()
        coordinator.refreshGroupIds()
        coordinator.refreshGroupIds()
        runCurrent()
        // One refresh, plus one more for the requests received while it was running.
        assertEquals(3, groups.calls)
        assertEquals(1, realtime.subscriptionCount)
        coordinator.stop()
    }

    @Test
    fun stopCancelsTheRetryTimer() = runTest {
        groups.fails = true
        val coordinator = started()
        assertEquals("retry timer", 1, sleepers.count)
        coordinator.stop()
        runCurrent()
        assertEquals("timer cancelled", 0, sleepers.count)
        advance(60.seconds)
        assertEquals(1, groups.calls)
    }

    // endregion

    // region Assignments

    @Test
    fun assignedIsForwardedInOrderAndBumpsMyTasks() = runTest {
        val coordinator = started()
        val first = RealtimeAssignment(F.uuid(1), F.groupA, F.other)
        val second = RealtimeAssignment(F.uuid(2), F.groupB, null)
        send(
            coordinator,
            RealtimeEvent.Assigned(first.taskId, first.groupId, first.assignedBy),
            RealtimeEvent.Assigned(second.taskId, second.groupId, second.assignedBy),
        )
        assertEquals("forwarded", listOf(first, second), sink.received)
        assertEquals(setOf(Key.MyTasks), coordinator.pendingBumpKeys)
        assertEquals(1, sleepers.count)
        advance(300.milliseconds)
        assertEquals(1, feed.myTasksRevision.value)
        assertEquals(0, feed.groupRevision(F.groupA))
        coordinator.stop()
    }

    @Test
    fun assignmentsReachTheNotifier() = runTest {
        val tasks = LogicFakeTaskService()
        val scheduler = LogicFakeScheduler()
        val date = F.date(2026, 9, 24, 12, 0)
        val notifier = AssignmentNotifier(F.me, tasks, scheduler, InMemoryKeyValueStore(), now = { date })
        tasks.put(F.task(1, title = "Faire les courses"))
        val coordinator = makeCoordinator(onAssigned = { notifier.handleRealtime(it) })
        coordinator.start()
        runCurrent()
        assertEquals("subscription", 1, realtime.subscriptionCount)
        realtime.send(RealtimeEvent.Assigned(F.uuid(1), F.groupA, F.other))
        realtime.send(RealtimeEvent.Assigned(F.uuid(1), F.groupA, F.me))
        runCurrent()
        assertEquals(listOf("Faire les courses — Coloc' rue des Lilas"), scheduler.added.map { it.body })
        coordinator.stop()
    }

    /** A failing handler does not stop the forwarding of the next assignments. */
    @Test
    fun failingHandlerKeepsForwarding() = runTest {
        val received = ArrayList<RealtimeAssignment>()
        val coordinator = makeCoordinator(onAssigned = { assignment ->
            received.add(assignment)
            if (assignment.taskId == F.uuid(1)) throw AppError.Network
        })
        coordinator.start()
        runCurrent()
        send(
            coordinator,
            RealtimeEvent.Assigned(F.uuid(1), F.groupA, F.other),
            RealtimeEvent.Assigned(F.uuid(2), F.groupA, F.other),
        )
        assertEquals(listOf(F.uuid(1), F.uuid(2)), received.map { it.taskId })
        coordinator.stop()
    }

    // endregion

    // region Lifecycle

    @Test
    fun stopEndsTheStreamAndDropsPendingBumps() = runTest {
        val coordinator = started()
        send(coordinator, RealtimeEvent.GroupActivity(F.groupA))
        assertEquals(2, sleepers.count)

        coordinator.stop()
        assertFalse(coordinator.isRunning)
        assertTrue(coordinator.subscribedGroupIds.isEmpty())
        runCurrent()
        assertTrue("stream terminated", realtime.isTerminated(0))
        assertEquals("timers cancelled", 0, sleepers.count)

        val handled = coordinator.handledEventCount
        realtime.send(RealtimeEvent.Connected)
        advance(10.seconds)
        assertEquals(handled, coordinator.handledEventCount)
        assertEquals(0, feed.allRevision.value)
        assertEquals(0, feed.groupRevision(F.groupA))
        assertEquals(1, realtime.subscriptionCount)
    }

    @Test
    fun canRestartAfterStop() = runTest {
        val coordinator = started()
        coordinator.stop()
        coordinator.start()
        runCurrent()
        assertEquals("second subscription", 2, realtime.subscriptionCount)
        send(coordinator, RealtimeEvent.Connected)
        assertEquals(1, feed.allRevision.value)
        coordinator.stop()
    }

    @Test
    fun stopBeforeTheFirstSubscriptionIsSafe() = runTest {
        val coordinator = makeCoordinator()
        coordinator.start()
        coordinator.stop()
        runCurrent()
        assertEquals(0, realtime.subscriptionCount)
        assertFalse(coordinator.isRunning)
    }

    /** Swift: releasing the coordinator ends the stream. Kotlin: cancelling its scope does. */
    @Test
    fun cancellingTheScopeEndsTheStream() = runTest {
        val scope = CoroutineScope(backgroundScope.coroutineContext + Job(backgroundScope.coroutineContext[Job]))
        val coordinator = makeCoordinator(scope = scope)
        coordinator.start()
        runCurrent()
        assertEquals("subscription", 1, realtime.subscriptionCount)
        send(coordinator, RealtimeEvent.GroupActivity(F.groupA))
        assertEquals(2, sleepers.count)

        scope.cancel()
        runCurrent()
        assertTrue("stream terminated", realtime.isTerminated(0))
        assertFalse(coordinator.isRunning)
        advance(1.seconds)
        assertEquals(0, feed.groupRevision(F.groupA))
    }

    @Test
    fun streamEndedByTheServerIsRetriedAfterTheDelay() = runTest {
        val coordinator = started()
        groups.ids = listOf(F.groupB)
        realtime.finishLatest()
        runCurrent()
        assertEquals("retry timer", 1, sleepers.count)
        assertEquals(1, realtime.subscriptionCount)

        advance(4.seconds)
        assertEquals(1, realtime.subscriptionCount)

        advance(1.seconds)
        assertEquals("resubscribed", 2, realtime.subscriptionCount)
        assertEquals(listOf(F.groupB), realtime.groupIds(1))
        send(coordinator, RealtimeEvent.Connected)
        assertEquals(1, feed.allRevision.value)
        coordinator.stop()
    }

    /** A Kotlin flow can fail (network error of the client library): handled like its end. */
    @Test
    fun failedStreamIsRetriedAfterTheDelay() = runTest {
        val coordinator = started()
        realtime.failLatest(IOException("socket closed"))
        runCurrent()
        assertTrue(realtime.isTerminated(0))
        assertEquals("retry timer", 1, sleepers.count)
        assertTrue(coordinator.isRunning)
        advance(5.seconds)
        assertEquals("resubscribed", 2, realtime.subscriptionCount)
        assertEquals(listOf(F.groupA), realtime.groupIds(1))
        coordinator.stop()
    }

    /**
     * Feed collectors on an unconfined dispatcher run inside the bump: they may call back into the coordinator
     * without deadlock or corrupted state (no foreign code runs under the coordinator's lock).
     */
    @Test
    fun feedCollectorsMayCallBackIntoTheCoordinator() = runTest {
        val coordinator = started()
        backgroundScope.launch(UnconfinedTestDispatcher(testScheduler)) {
            feed.allRevision.first { it == 1 }
            coordinator.stop()
        }
        send(coordinator, RealtimeEvent.Connected)
        assertFalse(coordinator.isRunning)
        runCurrent()
        assertTrue(realtime.isTerminated(0))
        coordinator.start()
        runCurrent()
        assertEquals(2, realtime.subscriptionCount)
        assertTrue(coordinator.isRunning)
        coordinator.stop()
    }

    // endregion
}
