package io.github.notkanaa.equipe.core.logic

import io.github.notkanaa.equipe.core.AppCalendar
import io.github.notkanaa.equipe.core.AppError
import io.github.notkanaa.equipe.core.AssignmentEvent
import io.github.notkanaa.equipe.core.LocalNotification
import io.github.notkanaa.equipe.core.NotificationAuthorization
import io.github.notkanaa.equipe.core.NotificationScheduler
import io.github.notkanaa.equipe.core.NowProvider
import io.github.notkanaa.equipe.core.RealtimeEvent
import io.github.notkanaa.equipe.core.RealtimeService
import io.github.notkanaa.equipe.core.TaskDraft
import io.github.notkanaa.equipe.core.TaskItem
import io.github.notkanaa.equipe.core.TaskPriority
import io.github.notkanaa.equipe.core.TaskService
import io.github.notkanaa.equipe.core.TaskStatus
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.flow
import java.time.Instant
import java.time.ZoneId
import java.time.ZonedDateTime
import java.util.UUID
import java.util.concurrent.atomic.AtomicInteger
import kotlin.time.Duration

// Test doubles and fixtures of the logic suites (port of Tests/TeamTasksCoreTests/Logic/LogicTestSupport.swift).
// Swift's manual test clock is replaced by kotlinx-coroutines-test's virtual time (runTest, advanceTimeBy,
// runCurrent); `LogicSleepers` counts the pending waits like `LogicTestClock.sleeperCount`.

// region Fixtures

object LogicFixtures {
    val paris: ZoneId = ZoneId.of("Europe/Paris")
    val parisCalendar: AppCalendar = AppCalendar.frenchGregorian(paris)

    val me: UUID = UUID.fromString("00000000-0000-0000-0000-00000000000A")
    val other: UUID = UUID.fromString("00000000-0000-0000-0000-00000000000B")
    val groupA: UUID = UUID.fromString("00000000-0000-0000-0000-0000000000A1")
    val groupB: UUID = UUID.fromString("00000000-0000-0000-0000-0000000000B2")

    /** A date in Europe/Paris. */
    fun date(year: Int, month: Int, day: Int, hour: Int = 0, minute: Int = 0, second: Int = 0): Instant =
        ZonedDateTime.of(year, month, day, hour, minute, second, 0, paris).toInstant()

    /** Deterministic UUID from a small number. */
    fun uuid(number: Int): UUID =
        UUID.fromString("10000000-0000-0000-0000-" + Integer.toHexString(number).padStart(12, '0'))

    fun task(
        number: Int,
        title: String? = null,
        group: UUID = groupA,
        status: TaskStatus = TaskStatus.TODO,
        priority: TaskPriority = TaskPriority.MEDIUM,
        due: Instant? = null,
        createdAt: Instant = date(2026, 1, 1),
        completedAt: Instant? = null,
        assignees: List<UUID> = listOf(me),
        groupName: String? = "Coloc' rue des Lilas",
    ): TaskItem = TaskItem(
        id = uuid(number),
        groupId = group,
        title = title ?: "Tâche $number",
        status = status,
        priority = priority,
        dueAt = due,
        createdBy = other,
        createdAt = createdAt,
        updatedAt = createdAt,
        completedAt = if (status == TaskStatus.DONE) completedAt ?: createdAt else null,
        assigneeIds = assignees,
        groupName = groupName,
    )
}

// endregion

// region Waiting

/** Counts the coroutines currently waiting in a `sleep` (Swift `LogicTestClock.sleeperCount`); time stays virtual. */
class LogicSleepers {
    private val active = AtomicInteger()

    val count: Int get() = active.get()

    val sleep: suspend (Duration) -> Unit = { duration ->
        active.incrementAndGet()
        try {
            delay(duration)
        } finally {
            active.decrementAndGet()
        }
    }
}

// endregion

// region Notification scheduler

/** Thrown by [LogicFakeScheduler.add] for its failing ids. */
class LogicSchedulingFailure : Exception("échec simulé")

class LogicFakeScheduler(
    authorization: NotificationAuthorization = NotificationAuthorization.AUTHORIZED,
) : NotificationScheduler {
    private val lock = Any()
    private var authorizationValue = authorization
    private val pendingById = HashMap<String, LocalNotification>()
    private val addedLog = ArrayList<LocalNotification>()
    private val removeLog = ArrayList<List<String>>()
    private var failing: Set<String> = emptySet()
    private var checks = 0

    var authorization: NotificationAuthorization
        get() = synchronized(lock) { authorizationValue }
        set(value) = synchronized(lock) { authorizationValue = value }

    /** Ids whose `add` throws. */
    var failingIds: Set<String>
        get() = synchronized(lock) { failing }
        set(value) = synchronized(lock) { failing = value }

    /** Pending (scheduled, not delivered) notifications by id. */
    val pending: Map<String, LocalNotification> get() = synchronized(lock) { HashMap(pendingById) }
    val pendingIds: List<String> get() = synchronized(lock) { pendingById.keys.sorted() }

    /** Every successful `add`, in order. */
    val added: List<LocalNotification> get() = synchronized(lock) { addedLog.toList() }
    val removeCalls: List<List<String>> get() = synchronized(lock) { removeLog.toList() }
    val authorizationChecks: Int get() = synchronized(lock) { checks }

    /** Simulates an already-pending request (e.g. scheduled by a previous launch). */
    fun seedPending(notification: LocalNotification) {
        synchronized(lock) { pendingById[notification.id] = notification }
    }

    fun resetCallLog() {
        synchronized(lock) {
            addedLog.clear()
            removeLog.clear()
        }
    }

    override suspend fun authorizationStatus(): NotificationAuthorization = synchronized(lock) {
        checks += 1
        authorizationValue
    }

    override suspend fun requestAuthorization(): Boolean =
        synchronized(lock) { authorizationValue == NotificationAuthorization.AUTHORIZED }

    override suspend fun pendingIdentifiers(prefix: String): List<String> =
        synchronized(lock) { pendingById.keys.filter { it.startsWith(prefix) }.sorted() }

    override suspend fun add(notification: LocalNotification) {
        synchronized(lock) {
            if (notification.id in failing) throw LogicSchedulingFailure()
            addedLog.add(notification)
            // "Deliver now" requests are shown immediately and never stay pending.
            if (notification.fireDate != null) {
                pendingById[notification.id] = notification
            }
        }
    }

    override suspend fun removePending(ids: List<String>) {
        synchronized(lock) {
            removeLog.add(ids.toList())
            for (id in ids) pendingById.remove(id)
        }
    }

    override suspend fun setBadge(count: Int) {}
}

/**
 * Scheduler whose n-th `add` call (1-based) can be held until the test opens it, to reproduce interleavings of
 * concurrent callers. A held request is registered when released (like a late platform call).
 */
class LogicGatedScheduler(private val gatedCalls: Set<Int>) : NotificationScheduler {
    private val lock = Any()
    private val pendingById = HashMap<String, LocalNotification>()
    private var addCalls = 0
    private val waiting = HashMap<Int, CompletableDeferred<Unit>>()

    val pending: Map<String, LocalNotification> get() = synchronized(lock) { HashMap(pendingById) }

    /** Calls currently held. */
    val waitingCalls: Set<Int> get() = synchronized(lock) { waiting.keys.toSet() }
    val addCallCount: Int get() = synchronized(lock) { addCalls }

    /** Releases the held call [call]. */
    fun open(call: Int) {
        val gate = synchronized(lock) { waiting.remove(call) }
        gate?.complete(Unit)
    }

    override suspend fun authorizationStatus(): NotificationAuthorization = NotificationAuthorization.AUTHORIZED

    override suspend fun requestAuthorization(): Boolean = true

    override suspend fun pendingIdentifiers(prefix: String): List<String> =
        synchronized(lock) { pendingById.keys.filter { it.startsWith(prefix) }.sorted() }

    override suspend fun add(notification: LocalNotification) {
        val gate = synchronized(lock) {
            addCalls += 1
            if (addCalls in gatedCalls) CompletableDeferred<Unit>().also { waiting[addCalls] = it } else null
        }
        gate?.await()
        synchronized(lock) { pendingById[notification.id] = notification }
    }

    override suspend fun removePending(ids: List<String>) {
        synchronized(lock) {
            for (id in ids) pendingById.remove(id)
        }
    }

    override suspend fun setBadge(count: Int) {}
}

// endregion

// region Task service

class LogicFakeTaskService : TaskService {
    private val lock = Any()
    private val tasksById = HashMap<UUID, TaskItem>()
    private var events: List<AssignmentEvent> = emptyList()
    private var error: AppError? = null
    private val lookupLog = ArrayList<UUID>()
    private val sinceLog = ArrayList<Instant>()

    fun put(task: TaskItem) {
        synchronized(lock) { tasksById[task.id] = task }
    }

    fun removeTask(id: UUID) {
        synchronized(lock) { tasksById.remove(id) }
    }

    /**
     * Server-side assignment rows returned by `assignments(since)` (filtered on `assignedAt > since` only, so tests can
     * check that the notifier also ignores self-assignments).
     */
    var assignmentEvents: List<AssignmentEvent>
        get() = synchronized(lock) { events }
        set(value) = synchronized(lock) { events = value.toList() }

    var assignmentsError: AppError?
        get() = synchronized(lock) { error }
        set(value) = synchronized(lock) { error = value }

    val lookups: List<UUID> get() = synchronized(lock) { lookupLog.toList() }
    val sinceCalls: List<Instant> get() = synchronized(lock) { sinceLog.toList() }

    override suspend fun task(id: UUID): TaskItem = synchronized(lock) {
        lookupLog.add(id)
        tasksById[id] ?: throw AppError.NotFound
    }

    override suspend fun assignments(since: Instant): List<AssignmentEvent> = synchronized(lock) {
        sinceLog.add(since)
        error?.let { throw it }
        events.filter { it.assignedAt > since }.sortedBy { it.assignedAt }
    }

    override suspend fun tasks(groupId: UUID, includeOldDone: Boolean): List<TaskItem> = unused()

    override suspend fun myTasks(includeDone: Boolean): List<TaskItem> = unused()

    override suspend fun create(groupId: UUID, draft: TaskDraft): TaskItem = unused()

    override suspend fun update(taskId: UUID, draft: TaskDraft): TaskItem = unused()

    override suspend fun setStatus(taskId: UUID, status: TaskStatus): TaskItem = unused()

    override suspend fun delete(taskId: UUID): Unit = unused()

    private fun unused(): Nothing = throw AppError.Unknown("non utilisé")
}

// endregion

// region Realtime service

/**
 * Cold fake of the realtime service: collecting [events] registers a subscription, leaving the collection
 * (completion, failure or cancellation) terminates it.
 */
class LogicFakeRealtime : RealtimeService {
    private class Subscription(val userId: UUID, val groupIds: List<UUID>) {
        val channel = Channel<RealtimeEvent>(Channel.UNLIMITED)

        @Volatile
        var terminated = false
    }

    private val lock = Any()
    private val subscriptions = ArrayList<Subscription>()

    override fun events(userId: UUID, groupIds: List<UUID>): Flow<RealtimeEvent> = flow {
        val subscription = Subscription(userId, groupIds.toList())
        synchronized(lock) { subscriptions.add(subscription) }
        try {
            for (event in subscription.channel) {
                emit(event)
            }
        } finally {
            subscription.terminated = true
            subscription.channel.close()
        }
    }

    val subscriptionCount: Int get() = synchronized(lock) { subscriptions.size }

    fun groupIds(index: Int): List<UUID> = synchronized(lock) { subscriptions[index].groupIds }

    fun userId(index: Int): UUID = synchronized(lock) { subscriptions[index].userId }

    fun isTerminated(index: Int): Boolean = synchronized(lock) { subscriptions[index].terminated }

    /** Sends an event on the latest subscription (dropped when it is terminated). */
    fun send(event: RealtimeEvent) {
        latest()?.channel?.trySend(event)
    }

    /** Ends the latest stream from the server side (connection lost). */
    fun finishLatest() {
        latest()?.channel?.close()
    }

    /** Fails the latest stream (e.g. a network error surfaced by the client library). */
    fun failLatest(error: Throwable) {
        latest()?.channel?.close(error)
    }

    private fun latest(): Subscription? = synchronized(lock) { subscriptions.lastOrNull() }
}

// endregion

// region Group ids provider

class LogicGroupIdsSource(ids: List<UUID>) {
    private val lock = Any()
    private var idsValue = ids
    private var callCount = 0
    private var failing = false

    var ids: List<UUID>
        get() = synchronized(lock) { idsValue }
        set(value) = synchronized(lock) { idsValue = value }

    var fails: Boolean
        get() = synchronized(lock) { failing }
        set(value) = synchronized(lock) { failing = value }

    val calls: Int get() = synchronized(lock) { callCount }

    fun fetch(): List<UUID> = synchronized(lock) {
        callCount += 1
        if (failing) throw AppError.Network
        idsValue
    }
}

/** Collects forwarded assignments. */
class LogicAssignmentSink {
    private val lock = Any()
    private val log = ArrayList<RealtimeAssignment>()

    val received: List<RealtimeAssignment> get() = synchronized(lock) { log.toList() }

    fun receive(assignment: RealtimeAssignment) {
        synchronized(lock) { log.add(assignment) }
    }
}

/** Mutable "now" shared with the code under test. */
class LogicNow(value: Instant) {
    @Volatile
    var value: Instant = value

    val provider: NowProvider = { this.value }
}

// endregion
