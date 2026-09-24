package io.github.notkanaa.equipe.core.logic

import io.github.notkanaa.equipe.core.KeyValueStore
import io.github.notkanaa.equipe.core.LocalNotification
import io.github.notkanaa.equipe.core.NotificationAuthorization
import io.github.notkanaa.equipe.core.NotificationScheduler
import io.github.notkanaa.equipe.core.NowProvider
import io.github.notkanaa.equipe.core.TaskItem
import io.github.notkanaa.equipe.core.TaskService
import io.github.notkanaa.equipe.core.setValue
import io.github.notkanaa.equipe.core.uuidString
import io.github.notkanaa.equipe.core.value
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.serialization.Serializable
import java.time.Duration
import java.time.Instant
import java.util.UUID
import kotlin.coroutines.cancellation.CancellationException

// Port of TeamTasksCore/Logic/AssignmentNotifier.swift.

/** A `RealtimeEvent.Assigned` signal, forwarded by [RealtimeCoordinator] to [AssignmentNotifier]. */
data class RealtimeAssignment(
    val taskId: UUID,
    val groupId: UUID,
    /** Who assigned the task (null when that account was deleted). */
    val assignedBy: UUID?,
)

/** Resolves a group's name for a notification body (e.g. from `GroupService.myGroups()`). */
typealias GroupNameResolver = suspend (groupId: UUID) -> String?

/**
 * Turns "a task was assigned to me" into local notifications, from two sources:
 * - realtime ([handleRealtime]): `RealtimeEvent.Assigned` + a lookup through `TaskService.task(id)`;
 * - catch-up ([catchUp]): `TaskService.assignments(since)` from a persisted cursor (app launch, foreground, background
 *   refresh).
 *
 * The same assignment seen by both sources is notified once: the notifier persists, per user, the cursor (latest
 * `assignedAt` handled by catch-up) and a bounded list of already-handled tasks. Assignments made by the current user
 * are ignored. Up to `maxIndividual` new assignments produce one `assigned-<taskId>` notification each; more produce a
 * single `summary-<epochSeconds>` notification. When notifications are not authorized nothing is posted, but the
 * cursor still advances.
 *
 * The cursor only ever holds server timestamps (the device clock may be wrong). Every catch-up re-reads
 * [CATCH_UP_OVERLAP] before it, because `assigned_at` is the transaction start time: a row can become visible after a
 * newer one. Re-read rows are recognized by the remembered records. A notification whose posting failed holds the
 * cursor back, so the next catch-up retries it.
 *
 * Operations are serialized by a (fair) [Mutex]: a realtime lookup and a catch-up never interleave. Create one
 * instance per signed-in user per process.
 */
class AssignmentNotifier(
    private val userId: UUID,
    private val tasks: TaskService,
    private val scheduler: NotificationScheduler,
    private val store: KeyValueStore,
    private val now: NowProvider = { Instant.now() },
    private val groupName: GroupNameResolver = { null },
    maxIndividual: Int = DEFAULT_MAX_INDIVIDUAL,
    rememberedLimit: Int = DEFAULT_REMEMBERED_LIMIT,
) {
    private val maxIndividual: Int = maxOf(0, maxIndividual)
    private val rememberedLimit: Int = maxOf(1, rememberedLimit)
    private val mutex = Mutex()

    /** Persisted state (one [KeyValueStore] entry per user, JSON). */
    @Serializable
    internal data class State(
        /** Latest `assignedAt` handled by catch-up. */
        @Serializable(with = InstantIsoSerializer::class)
        var cursor: Instant? = null,
        /**
         * Notified tasks, and tasks skipped as history or while notifications were not authorized.
         * Oldest first, at most `rememberedLimit` entries.
         */
        val notified: MutableList<Record> = ArrayList(),
    )

    @Serializable
    internal data class Record(
        @Serializable(with = UuidStringSerializer::class)
        val taskId: UUID,
        /** Server assignment date when known (catch-up), null for a realtime notification. */
        @Serializable(with = InstantIsoSerializer::class)
        val assignedAt: Instant? = null,
        /** Device date of the notification. */
        @Serializable(with = InstantIsoSerializer::class)
        val notifiedAt: Instant,
    )

    private class Item(
        val taskId: UUID,
        val groupId: UUID,
        val title: String,
        val groupName: String?,
        val assignedAt: Instant?,
    )

    /** Latest `assignedAt` handled by catch-up (null before the first catch-up). */
    val cursor: Instant? get() = loadState().cursor

    /**
     * Ids of the tasks remembered as already handled (notified, or skipped as history or while notifications were not
     * authorized), oldest first.
     */
    val rememberedTaskIds: List<UUID> get() = loadState().notified.map { it.taskId }

    /** Forgets the cursor and the remembered notifications (sign-out, account deletion). */
    suspend fun reset() {
        mutex.withLock {
            store.set(storageKey(userId), null)
        }
    }

    // region Realtime

    /**
     * Handles a realtime assignment. Returns the notifications posted.
     * Best effort: when the task cannot be read (deleted, network error) nothing is remembered, so the next catch-up
     * still notifies it.
     */
    suspend fun handleRealtime(assignment: RealtimeAssignment): List<LocalNotification> {
        if (assignment.assignedBy == userId) return emptyList()
        return mutex.withLock {
            val state = loadState()
            val date = now()
            // A realtime event is a new INSERT: it duplicates a remembered notification only when that one was posted
            // moments ago (same assignment seen by catch-up, or a duplicated delivery). An older record means the task
            // was unassigned and assigned again.
            val record = state.notified.lastOrNull { it.taskId == assignment.taskId }
            if (record != null && date < record.notifiedAt.plus(REALTIME_DEDUP_WINDOW)) {
                return@withLock emptyList()
            }
            if (scheduler.authorizationStatus() != NotificationAuthorization.AUTHORIZED) return@withLock emptyList()
            val task = lookUp(assignment.taskId)
            if (task == null || !task.isAssignedTo(userId)) return@withLock emptyList()
            val name = task.groupName ?: resolveGroupName(task.groupId)
            val item = Item(task.id, task.groupId, task.title, name, assignedAt = null)
            val outcome = post(listOf(item), state)
            saveState(state)
            outcome.posted
        }
    }

    private suspend fun lookUp(taskId: UUID): TaskItem? = try {
        tasks.task(taskId)
    } catch (error: CancellationException) {
        throw error
    } catch (error: Exception) {
        null
    }

    /** The resolver's name; its failure counts as "no name" (the Swift resolver cannot throw). */
    private suspend fun resolveGroupName(groupId: UUID): String? = try {
        groupName(groupId)
    } catch (error: CancellationException) {
        throw error
    } catch (error: Exception) {
        null
    }

    // endregion

    // region Catch-up

    /**
     * Fetches the assignments made since the cursor and notifies the new ones. Returns the notifications posted.
     * The first call only initializes the cursor (history is not notified): to the latest assignment of the last
     * [INITIAL_LOOKBACK], or to the start of that period when there is none.
     * Throws the [TaskService] error; the cursor is then unchanged.
     */
    suspend fun catchUp(): List<LocalNotification> = mutex.withLock {
        val state = loadState()
        val cursor = state.cursor
        if (cursor == null) {
            val start = now().minus(INITIAL_LOOKBACK)
            val history = tasks.assignments(start).sortedBy { it.assignedAt }
            val latest = maxOf(start, history.lastOrNull()?.assignedAt ?: start)
            val date = now()
            for (event in history) {
                if (event.assignedAt > latest.minus(CATCH_UP_OVERLAP)) {
                    remember(event.taskId, event.assignedAt, date, state)
                }
            }
            state.cursor = latest
            saveState(state)
            return@withLock emptyList()
        }

        val events = tasks.assignments(cursor.minus(CATCH_UP_OVERLAP)).sortedBy { it.assignedAt }
        val items = ArrayList<Item>()
        val batchTaskIds = HashSet<UUID>()
        for (event in events) {
            if (event.assignedBy == userId) continue
            if (!batchTaskIds.add(event.taskId)) continue
            val index = state.notified.indexOfLast { it.taskId == event.taskId }
            if (index >= 0) {
                val record = state.notified[index]
                val known = record.assignedAt
                val isDuplicate = if (known != null) {
                    event.assignedAt <= known
                } else {
                    event.assignedAt <= record.notifiedAt.plus(REALTIME_DEDUP_WINDOW)
                }
                if (isDuplicate) {
                    state.notified[index] = record.copy(assignedAt = maxOf(known ?: event.assignedAt, event.assignedAt))
                    continue
                }
            }
            items.add(Item(event.taskId, event.groupId, event.taskTitle, event.groupName, event.assignedAt))
        }

        var newCursor = maxOf(cursor, events.lastOrNull()?.assignedAt ?: cursor)
        val outcome = post(items, state)
        if (!outcome.authorized) {
            // Not notified, but handled: the next (overlapping) catch-up must not notify them either.
            val date = now()
            val threshold = newCursor.minus(CATCH_UP_OVERLAP)
            for (item in items) {
                val assignedAt = item.assignedAt ?: continue
                if (assignedAt > threshold) {
                    remember(item.taskId, assignedAt, date, state)
                }
            }
        }
        // Retried by the next catch-up, which re-reads from the cursor minus the overlap.
        val oldestFailure = outcome.failed.mapNotNull { it.assignedAt }.minOrNull()
        if (oldestFailure != null) {
            newCursor = minOf(newCursor, oldestFailure)
        }
        state.cursor = newCursor
        saveState(state)
        outcome.posted
    }

    // endregion

    // region Posting

    private class PostOutcome(
        val posted: MutableList<LocalNotification> = ArrayList(),
        /** Items whose notification could not be added. */
        val failed: MutableList<Item> = ArrayList(),
        val authorized: Boolean = true,
    )

    /** Posts [items] and remembers the posted ones in [state]. */
    private suspend fun post(items: List<Item>, state: State): PostOutcome {
        if (items.isEmpty()) return PostOutcome()
        if (scheduler.authorizationStatus() != NotificationAuthorization.AUTHORIZED) {
            return PostOutcome(authorized = false)
        }
        val date = now()

        val isSummary = items.size > maxIndividual
        val notifications: List<LocalNotification> = if (isSummary) {
            val groupIds = items.map { it.groupId }.toSet()
            val singleGroup = if (groupIds.size == 1) groupIds.first() else null
            listOf(
                LocalNotification(
                    id = summaryIdentifier(date),
                    title = SUMMARY_TITLE,
                    body = "${items.size} nouvelles tâches assignées",
                    fireDate = null,
                    userInfo = if (singleGroup != null) mapOf("groupId" to singleGroup.uuidString) else emptyMap(),
                    threadId = singleGroup?.uuidString,
                ),
            )
        } else {
            items.map { item ->
                val name = item.groupName
                LocalNotification(
                    id = individualIdentifier(item.taskId),
                    title = INDIVIDUAL_TITLE,
                    body = if (name.isNullOrEmpty()) item.title else "${item.title} — $name",
                    fireDate = null,
                    userInfo = mapOf("taskId" to item.taskId.uuidString, "groupId" to item.groupId.uuidString),
                    threadId = item.groupId.uuidString,
                )
            }
        }

        val outcome = PostOutcome()
        for (notification in notifications) {
            try {
                scheduler.add(notification)
                outcome.posted.add(notification)
            } catch (error: CancellationException) {
                throw error
            } catch (error: Exception) {
                continue
            }
        }

        val postedIds = outcome.posted.map { it.id }.toSet()
        for (item in items) {
            val id = if (isSummary) notifications[0].id else individualIdentifier(item.taskId)
            if (postedIds.contains(id)) {
                remember(item.taskId, item.assignedAt, date, state)
            } else {
                outcome.failed.add(item)
            }
        }
        return outcome
    }

    private fun remember(taskId: UUID, assignedAt: Instant?, date: Instant, state: State) {
        state.notified.removeAll { it.taskId == taskId }
        state.notified.add(Record(taskId, assignedAt, date))
        val excess = state.notified.size - rememberedLimit
        if (excess > 0) {
            state.notified.subList(0, excess).clear()
        }
    }

    // endregion

    // region Persistence

    private fun loadState(): State = store.value<State>(storageKey(userId)) ?: State()

    private fun saveState(state: State) {
        store.setValue(storageKey(userId), state)
    }

    // endregion

    companion object {
        const val DEFAULT_MAX_INDIVIDUAL: Int = 5
        const val DEFAULT_REMEMBERED_LIMIT: Int = 200

        /**
         * Dedup window around a remembered notification:
         * - a catch-up assignment of a task notified through realtime (server `assignedAt` unknown) is a duplicate
         *   when assigned no later than this after the notification (absorbs device/server clock skew);
         * - a realtime signal for a task notified less than this long ago is a duplicate (same assignment already seen
         *   by catch-up, or a repeated delivery); an older one is a re-assignment.
         */
        val REALTIME_DEDUP_WINDOW: Duration = Duration.ofMinutes(5)

        /**
         * How far back the first catch-up looks for existing assignments (history, never notified): the latest one
         * becomes the cursor.
         */
        val INITIAL_LOOKBACK: Duration = Duration.ofDays(7)

        /** How much every catch-up re-reads before the cursor (a transaction that started earlier can commit later). */
        val CATCH_UP_OVERLAP: Duration = Duration.ofMinutes(2)

        const val INDIVIDUAL_TITLE: String = "Nouvelle tâche"
        const val SUMMARY_TITLE: String = "Nouvelles tâches"

        /** [KeyValueStore] key of a user's state. */
        fun storageKey(userId: UUID): String = "assignments.state.${userId.uuidString}"

        fun individualIdentifier(taskId: UUID): String = "assigned-${taskId.uuidString}"

        fun summaryIdentifier(date: Instant): String = "summary-${ReminderPlanner.epochSeconds(date)}"
    }
}
