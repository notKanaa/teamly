package io.github.notkanaa.equipe.core.logic

import io.github.notkanaa.equipe.core.RealtimeEvent
import io.github.notkanaa.equipe.core.RealtimeService
import io.github.notkanaa.equipe.core.UuidStringOrder
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Job
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.delay
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.flow.collect
import kotlinx.coroutines.flow.takeWhile
import kotlinx.coroutines.launch
import java.util.UUID
import kotlin.time.Duration
import kotlin.time.Duration.Companion.milliseconds
import kotlin.time.Duration.Companion.seconds

// Port of TeamTasksCore/Logic/RealtimeCoordinator.swift.

/** Returns the ids of the current user's groups (e.g. from `GroupService.myGroups()`). */
typealias GroupIdsProvider = suspend () -> List<UUID>

/** Receives the `RealtimeEvent.Assigned` signals, in order (typically [AssignmentNotifier.handleRealtime]). */
typealias AssignmentHandler = suspend (RealtimeAssignment) -> Unit

/**
 * Consumes [RealtimeService.events] and turns the change signals into [ChangeFeed] bumps.
 *
 * - [RealtimeEvent.Connected] (first subscription and every reconnection) → `bumpAll()` immediately; pending debounced
 *   bumps are dropped since they are covered. On a reconnection (a later `Connected` of the same subscription), or while
 *   the group ids are stale, the group ids are fetched again: a membership change may have been missed while the
 *   socket was down.
 * - [RealtimeEvent.GroupActivity] → bump of the group and of "Mes tâches" (an edit, a status change or an unassignment in
 *   the group may affect my tasks; unassignments only surface as group activity).
 * - [RealtimeEvent.MembershipsChanged] → `bumpMemberships()` + `bumpMyTasks()`, then the group ids are fetched again.
 * - [RealtimeEvent.Assigned] → `bumpMyTasks()` and the signal is forwarded, in order, to `onAssigned` (typically
 *   [AssignmentNotifier.handleRealtime]), without blocking the event loop.
 *
 * Every fetch of the group ids ([refreshGroupIds]) re-subscribes the channel when the ids changed. A failed fetch leaves
 * the ids stale ([groupIdsAreStale]): it is retried on the next `Connected` and after `retryDelay`, doubled after each
 * failure up to [MAX_GROUP_IDS_RETRY_DELAY]. Without this, a cold start offline (or a failed fetch after joining a
 * group) would leave groups without live updates for the whole session, since the Supabase stream never ends by itself.
 *
 * Bumps are debounced per key (each group, memberships, my tasks): the first signal of a key opens a window of
 * `debounce` (300 ms by default) and every signal of that key received during the window is coalesced into one bump at
 * its end, so a burst never delays a reload by more than `debounce`. Waits use [delay], so tests run on virtual time
 * (kotlinx-coroutines-test).
 *
 * If the stream ends on its own (or fails), the coordinator re-subscribes after `retryDelay`. [stop] cancels
 * everything and ends the stream. Cancelling [scope] does too (the Swift coordinator stops when it is released); the
 * coordinator cannot be restarted in a cancelled scope.
 *
 * Every coroutine runs in [scope] (typically the signed-in session's scope on the main dispatcher). The state is
 * guarded by a lock, so [start], [stop] and [refreshGroupIds] may be called from any thread; no foreign code (feed
 * collectors, coroutine bodies, cancellation handlers of the realtime flow, the assignment handler) ever runs while
 * the lock is held, even with an immediate or unconfined dispatcher.
 *
 * @param groupIds fetches the current group ids (initial subscription unless given to [start], after
 *   `MembershipsChanged`, on reconnection and while they are stale).
 * @param onAssigned receives every `Assigned` signal, in order; its failures are ignored.
 */
class RealtimeCoordinator internal constructor(
    private val realtime: RealtimeService,
    private val userId: UUID,
    private val feed: ChangeFeed,
    private val scope: CoroutineScope,
    private val groupIdsProvider: GroupIdsProvider,
    debounce: Duration,
    retryDelay: Duration,
    private val onAssigned: AssignmentHandler?,
    /** Every wait (debounce, retries); tests wrap [delay] to count the pending timers, like Swift's test clock. */
    private val sleep: suspend (Duration) -> Unit,
) {
    constructor(
        realtime: RealtimeService,
        userId: UUID,
        feed: ChangeFeed,
        scope: CoroutineScope,
        groupIds: GroupIdsProvider,
        debounce: Duration = DEFAULT_DEBOUNCE,
        retryDelay: Duration = DEFAULT_RETRY_DELAY,
        onAssigned: AssignmentHandler? = null,
    ) : this(realtime, userId, feed, scope, groupIds, debounce, retryDelay, onAssigned, { delay(it) })

    /** Debounce key. */
    internal sealed interface BumpKey {
        data class Group(val groupId: UUID) : BumpKey

        data object Memberships : BumpKey

        data object MyTasks : BumpKey
    }

    private class PendingBump(val token: Int, val job: Job)

    /** Side effects decided under the lock, run in order once it is released. */
    private class Effects {
        private val actions = ArrayList<() -> Unit>()

        fun add(action: () -> Unit) {
            actions.add(action)
        }

        fun run() {
            for (action in actions) action()
        }
    }

    private val debounce: Duration = debounce.coerceAtLeast(Duration.ZERO)
    private val retryDelay: Duration = retryDelay.coerceAtLeast(Duration.ZERO)
    private val lock = Any()

    private var runJob: Job? = null
    private var handlerJob: Job? = null
    private var handlerChannel: Channel<RealtimeAssignment>? = null
    private var refreshJob: Job? = null

    /** A refresh was requested while one was running: run another one when it ends. */
    private var refreshRequested = false
    private var groupIdsRetryJob: Job? = null
    private var groupIdsFailures = 0
    private val pendingBumps = HashMap<BumpKey, PendingBump>()

    /** Changes on every [start] and [stop]: work of an earlier run never acts on a later one. */
    private var runId = 0

    /** Changes on every subscription (and on [stop]): events of a replaced subscription are ignored. */
    private var generation = 0
    private var nextToken = 0

    /** The current subscription already received `Connected`: the next one is a reconnection. */
    private var connectedOnCurrentSubscription = false

    /** Group ids of the current subscription (sorted by [UuidStringOrder]), empty when stopped. */
    @Volatile
    var subscribedGroupIds: List<UUID> = emptyList()
        private set

    /**
     * True when the last fetch of the group ids failed: the subscription may miss some groups until a fetch succeeds
     * (retried on `Connected`, after a delay, and by [refreshGroupIds]).
     */
    @Volatile
    var groupIdsAreStale: Boolean = false
        private set

    /** Number of events handled (diagnostics and tests). */
    @Volatile
    var handledEventCount: Int = 0
        private set

    /** True between [start] and [stop] (false once [scope] is cancelled). */
    val isRunning: Boolean
        get() = synchronized(lock) {
            val job = runJob
            job != null && !job.isCancelled && !job.isCompleted
        }

    /** Keys with a debounced bump waiting for the end of its window (tests). */
    internal val pendingBumpKeys: Set<BumpKey> get() = synchronized(lock) { pendingBumps.keys.toSet() }

    // region Lifecycle

    /**
     * Starts listening. No-op when already running.
     * @param groupIds initial group ids if already known; otherwise the provider is called.
     */
    fun start(groupIds: List<UUID>? = null) {
        withState { effects ->
            if (runJob != null) return@withState
            runId += 1
            val handler = onAssigned
            if (handler != null) {
                val channel = Channel<RealtimeAssignment>(Channel.UNLIMITED)
                handlerChannel = channel
                val job = scope.launch(start = CoroutineStart.LAZY) {
                    for (assignment in channel) {
                        try {
                            handler(assignment)
                        } catch (error: Exception) {
                            currentCoroutineContext().ensureActive()
                        }
                    }
                }
                handlerJob = job
                effects.add { job.start() }
            }
            runSubscriptions(groupIds, effects)
        }
    }

    /**
     * Stops listening: ends the realtime stream, drops pending bumps and cancels the assignment handler.
     * [start] can be called again afterwards.
     */
    fun stop() {
        withState { effects ->
            runId += 1
            generation += 1
            val jobs = listOfNotNull(runJob, refreshJob, groupIdsRetryJob, handlerJob)
            val channel = handlerChannel
            runJob = null
            refreshJob = null
            refreshRequested = false
            groupIdsRetryJob = null
            groupIdsFailures = 0
            groupIdsAreStale = false
            handlerChannel = null
            handlerJob = null
            cancelPendingBumps(effects)
            subscribedGroupIds = emptyList()
            connectedOnCurrentSubscription = false
            effects.add {
                channel?.close()
                for (job in jobs) job.cancel()
            }
        }
    }

    /**
     * Fetches the group ids again and re-subscribes when they changed (e.g. on return to the foreground).
     * Concurrent requests are coalesced. No-op when stopped.
     */
    fun refreshGroupIds() {
        withState { effects -> requestRefresh(effects) }
    }

    /** Runs [block] under the lock, then the side effects it recorded, without the lock. */
    private fun <T> withState(block: (Effects) -> T): T {
        val effects = Effects()
        val result = synchronized(lock) { block(effects) }
        effects.run()
        return result
    }

    // endregion

    // region Subscription loop

    /** (Re)starts the subscription loop: with [initialGroupIds], or with ids fetched first. Under the lock. */
    private fun runSubscriptions(initialGroupIds: List<UUID>?, effects: Effects) {
        val previous = runJob
        generation += 1
        val currentGeneration = generation
        val currentRun = runId
        val job = scope.launch(start = CoroutineStart.LAZY) {
            var ids = initialGroupIds ?: fetchGroupIds(currentRun, fallback = emptyList())
            while (true) {
                ids = normalized(ids)
                if (!willSubscribe(ids, currentGeneration)) return@launch
                // Collecting subscribes; leaving the collection (end, failure or cancellation) unsubscribes.
                try {
                    realtime.events(userId, ids)
                        .takeWhile { event -> handle(event, currentGeneration) }
                        .collect()
                } catch (error: Exception) {
                    currentCoroutineContext().ensureActive()
                    // The stream failed: handled like its end, below.
                }

                // The stream ended by itself (or the subscription was replaced): retry later with fresh group ids.
                if (!isCurrentGeneration(currentGeneration)) return@launch
                sleep(retryDelay)
                ids = fetchGroupIds(currentRun, fallback = ids)
            }
        }
        runJob = job
        effects.add {
            previous?.cancel()
            job.start()
        }
    }

    private fun willSubscribe(groupIds: List<UUID>, expected: Int): Boolean = synchronized(lock) {
        if (expected != generation) {
            false
        } else {
            subscribedGroupIds = groupIds
            connectedOnCurrentSubscription = false
            true
        }
    }

    private fun isCurrentGeneration(expected: Int): Boolean = synchronized(lock) { expected == generation }

    // endregion

    // region Group ids

    /** Calls the provider; on failure returns [fallback] and marks the ids stale (retried later). */
    private suspend fun fetchGroupIds(run: Int, fallback: List<UUID>): List<UUID> {
        val ids = try {
            groupIdsProvider()
        } catch (error: Exception) {
            currentCoroutineContext().ensureActive()
            withState { effects -> if (run == runId) groupIdsDidFail(effects) }
            return fallback
        }
        withState { effects -> if (run == runId) groupIdsDidLoad(effects) }
        return ids
    }

    /** Starts a refresh, or asks the running one to fetch again when it ends. No-op when stopped. Under the lock. */
    private fun requestRefresh(effects: Effects) {
        if (runJob == null) return
        if (refreshJob != null) {
            refreshRequested = true
            return
        }
        refreshRequested = false
        val run = runId
        val job = scope.launch(start = CoroutineStart.LAZY) { performRefreshes(run) }
        refreshJob = job
        effects.add { job.start() }
    }

    private suspend fun performRefreshes(run: Int) {
        val job = currentCoroutineContext()[Job]
        while (true) {
            val fresh: List<UUID>? = try {
                groupIdsProvider()
            } catch (error: Exception) {
                currentCoroutineContext().ensureActive()
                null
            }
            val again = withState { effects ->
                if (run != runId) return@withState false
                if (fresh == null) {
                    groupIdsDidFail(effects)
                } else {
                    groupIdsDidLoad(effects)
                    val normalizedFresh = normalized(fresh)
                    if (normalizedFresh != subscribedGroupIds) {
                        runSubscriptions(normalizedFresh, effects)
                    }
                }
                if (refreshRequested && job?.isActive != false) {
                    refreshRequested = false
                    true
                } else {
                    refreshJob = null
                    false
                }
            }
            if (!again) return
        }
    }

    /** Under the lock. */
    private fun groupIdsDidLoad(effects: Effects) {
        groupIdsAreStale = false
        groupIdsFailures = 0
        val retry = groupIdsRetryJob ?: return
        groupIdsRetryJob = null
        effects.add { retry.cancel() }
    }

    /** Marks the ids stale and schedules one retry (`retryDelay`, doubled after each failure, capped). Under the lock. */
    private fun groupIdsDidFail(effects: Effects) {
        groupIdsAreStale = true
        groupIdsFailures += 1
        if (runJob == null || groupIdsRetryJob != null) return
        val exponent = minOf(groupIdsFailures - 1, 16)
        val wait = minOf(retryDelay * (1 shl exponent), maxOf(retryDelay, MAX_GROUP_IDS_RETRY_DELAY))
        val run = runId
        val job = scope.launch(start = CoroutineStart.LAZY) {
            sleep(wait)
            val self = currentCoroutineContext()[Job]
            withState { retryEffects ->
                if (runId == run && groupIdsRetryJob === self) {
                    groupIdsRetryJob = null
                    requestRefresh(retryEffects)
                }
            }
        }
        groupIdsRetryJob = job
        effects.add { job.start() }
    }

    // endregion

    // region Events

    /** Handles one event of the current subscription. Returns false when the subscription was replaced or stopped. */
    private fun handle(event: RealtimeEvent, expected: Int): Boolean = withState { effects ->
        if (expected != generation) return@withState false
        handledEventCount += 1
        when (event) {
            RealtimeEvent.Connected -> {
                cancelPendingBumps(effects)
                effects.add { feed.bumpAll() }
                val isReconnection = connectedOnCurrentSubscription
                connectedOnCurrentSubscription = true
                if (isReconnection || groupIdsAreStale) {
                    requestRefresh(effects)
                }
            }
            is RealtimeEvent.GroupActivity -> {
                scheduleBump(BumpKey.Group(event.groupId), effects)
                scheduleBump(BumpKey.MyTasks, effects)
            }
            RealtimeEvent.MembershipsChanged -> {
                scheduleBump(BumpKey.Memberships, effects)
                scheduleBump(BumpKey.MyTasks, effects)
                requestRefresh(effects)
            }
            is RealtimeEvent.Assigned -> {
                scheduleBump(BumpKey.MyTasks, effects)
                val channel = handlerChannel
                if (channel != null) {
                    val assignment = RealtimeAssignment(event.taskId, event.groupId, event.assignedBy)
                    effects.add { channel.trySend(assignment) }
                }
            }
        }
        true
    }

    // endregion

    // region Debounce

    /** Under the lock. */
    private fun scheduleBump(key: BumpKey, effects: Effects) {
        if (pendingBumps.containsKey(key)) return
        nextToken += 1
        val token = nextToken
        val job = scope.launch(start = CoroutineStart.LAZY) {
            sleep(debounce)
            fireBump(key, token)
        }
        pendingBumps[key] = PendingBump(token, job)
        effects.add { job.start() }
    }

    private fun fireBump(key: BumpKey, token: Int) {
        withState { effects ->
            val entry = pendingBumps[key]
            if (entry != null && entry.token == token) {
                pendingBumps.remove(key)
                effects.add {
                    when (key) {
                        is BumpKey.Group -> feed.bump(key.groupId)
                        BumpKey.Memberships -> feed.bumpMemberships()
                        BumpKey.MyTasks -> feed.bumpMyTasks()
                    }
                }
            }
        }
    }

    /** Under the lock. */
    private fun cancelPendingBumps(effects: Effects) {
        if (pendingBumps.isEmpty()) return
        val jobs = pendingBumps.values.map { it.job }
        pendingBumps.clear()
        effects.add { for (job in jobs) job.cancel() }
    }

    // endregion

    companion object {
        val DEFAULT_DEBOUNCE: Duration = 300.milliseconds
        val DEFAULT_RETRY_DELAY: Duration = 5.seconds

        /** Longest wait between two attempts to fetch stale group ids. */
        val MAX_GROUP_IDS_RETRY_DELAY: Duration = 60.seconds

        private fun normalized(ids: List<UUID>): List<UUID> = ids.toSet().sortedWith(UuidStringOrder)
    }
}
