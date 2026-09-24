package io.github.notkanaa.equipe.core.logic

import io.github.notkanaa.equipe.core.AppCalendar
import io.github.notkanaa.equipe.core.KeyValueStore
import io.github.notkanaa.equipe.core.LocalNotification
import io.github.notkanaa.equipe.core.NotificationAuthorization
import io.github.notkanaa.equipe.core.NotificationScheduler
import io.github.notkanaa.equipe.core.NowProvider
import io.github.notkanaa.equipe.core.PlatformServices
import io.github.notkanaa.equipe.core.TaskItem
import io.github.notkanaa.equipe.core.compareLikeSwift
import io.github.notkanaa.equipe.core.setValue
import io.github.notkanaa.equipe.core.value
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import java.math.BigDecimal
import java.math.RoundingMode
import java.util.UUID
import java.util.concurrent.atomic.AtomicInteger
import kotlin.coroutines.cancellation.CancellationException

// Port of TeamTasksCore/Logic/ReminderReconciler.swift (ReminderReconciler, ReminderSynchronizer, StableHash).

/** What [ReminderReconciler.apply] changed. */
data class ReminderReconciliation(
    /** Ids scheduled for the first time. */
    val added: List<String> = emptyList(),
    /** Ids already pending whose content or fire date changed (removed, then added again). */
    val replaced: List<String> = emptyList(),
    /** Pending ids no longer desired (task done, unassigned, deleted, due date changed, reminders off…). */
    val removed: List<String> = emptyList(),
    /** Ids whose scheduling failed; retried by the next `apply`. */
    val failed: List<String> = emptyList(),
    /** Desired reminders already pending with the same content. */
    val unchanged: Int = 0,
) {
    /** True when nothing had to be scheduled or removed. */
    val isNoOp: Boolean get() = added.isEmpty() && replaced.isEmpty() && removed.isEmpty() && failed.isEmpty()
}

/**
 * Makes the pending `due-` notifications match a desired set (from [ReminderPlanner]) through [NotificationScheduler].
 * Idempotent: applying the same set twice does nothing the second time.
 *
 * Notifications other than `due-` ones are never touched. Because a reminder's id only encodes the task and its due
 * date, a fingerprint of every scheduled reminder (content + fire date) is kept in the [KeyValueStore] (under
 * [FINGERPRINTS_KEY]), so that a lead-time change or a renamed task replaces the pending request.
 */
class ReminderReconciler(
    private val scheduler: NotificationScheduler,
    private val store: KeyValueStore,
) {
    suspend fun apply(desired: List<LocalNotification>): ReminderReconciliation = apply(desired) { true }

    /**
     * Same as `apply(desired)`, but stops as soon as [isCurrent] returns false (checked before and after every
     * scheduling call): a superseded application schedules nothing more, withdraws the request it has just scheduled
     * (the platform may register it after a concurrent removal) and leaves the stored fingerprints untouched.
     */
    internal suspend fun apply(
        desired: List<LocalNotification>,
        isCurrent: suspend () -> Boolean,
    ): ReminderReconciliation {
        val prefix = ReminderPlanner.IDENTIFIER_PREFIX
        val unique = ArrayList<LocalNotification>()
        val desiredIds = HashSet<String>()
        for (notification in desired) {
            if (notification.id.startsWith(prefix) && desiredIds.add(notification.id)) {
                unique.add(notification)
            }
        }

        val pending = scheduler.pendingIdentifiers(prefix).toSet()
        val stored: Map<String, String> = store.value<Map<String, String>>(FINGERPRINTS_KEY) ?: emptyMap()
        val added = ArrayList<String>()
        val replaced = ArrayList<String>()
        val failed = ArrayList<String>()
        var unchanged = 0
        val toAdd = ArrayList<PlannedAdd>()

        for (notification in unique) {
            val fingerprint = fingerprint(notification)
            if (pending.contains(notification.id)) {
                if (stored[notification.id] == fingerprint) {
                    unchanged += 1
                } else {
                    toAdd.add(PlannedAdd(notification, fingerprint, isReplacement = true))
                }
            } else {
                toAdd.add(PlannedAdd(notification, fingerprint, isReplacement = false))
            }
        }

        val removed = pending.filter { it !in desiredIds }.sortedWith(::compareLikeSwift)
        fun result() = ReminderReconciliation(added.toList(), replaced.toList(), removed, failed.toList(), unchanged)

        val toRemove = removed + toAdd.filter { it.isReplacement }.map { it.notification.id }
        if (toRemove.isNotEmpty()) {
            scheduler.removePending(toRemove)
        }

        val fingerprints = HashMap(stored.filterKeys { it in desiredIds && it in pending })
        for (item in toAdd) {
            if (!isCurrent()) return result()
            try {
                scheduler.add(item.notification)
            } catch (error: CancellationException) {
                throw error
            } catch (error: Exception) {
                fingerprints.remove(item.notification.id)
                failed.add(item.notification.id)
                continue
            }
            if (!isCurrent()) {
                scheduler.removePending(listOf(item.notification.id))
                return result()
            }
            fingerprints[item.notification.id] = item.fingerprint
            if (item.isReplacement) {
                replaced.add(item.notification.id)
            } else {
                added.add(item.notification.id)
            }
        }

        if (!isCurrent()) return result()
        if (fingerprints != stored) {
            store.setValue<Map<String, String>>(FINGERPRINTS_KEY, fingerprints)
        }
        return result()
    }

    private class PlannedAdd(
        val notification: LocalNotification,
        val fingerprint: String,
        val isReplacement: Boolean,
    )

    companion object {
        /** [KeyValueStore] key of the `{id: fingerprint}` map. */
        const val FINGERPRINTS_KEY: String = "reminders.fingerprints"

        /** Unit separator between the fingerprint's parts. */
        private val SEPARATOR: String = Char(0x1F).toString()

        /** Stable (process-independent) fingerprint of everything a reminder displays or when it fires. */
        internal fun fingerprint(notification: LocalNotification): String {
            val fireMillis = notification.fireDate?.let { date ->
                // Swift: Int64((timeIntervalSince1970 * 1000).rounded()), i.e. to nearest, ties away from zero.
                BigDecimal.valueOf(date.epochSecond).scaleByPowerOfTen(3)
                    .add(BigDecimal.valueOf(date.nano.toLong()).scaleByPowerOfTen(-6))
                    .setScale(0, RoundingMode.HALF_UP)
                    .toLong()
                    .toString()
            } ?: "-"
            val userInfo = notification.userInfo.entries
                .sortedWith { lhs, rhs -> compareLikeSwift(lhs.key, rhs.key) }
                .map { "${it.key}=${it.value}" }
            val parts = listOf(notification.title, notification.body, fireMillis, notification.threadId ?: "-") + userInfo
            return StableHash.fnv1a64Hex(parts.joinToString(SEPARATOR))
        }
    }
}

/**
 * Plans and applies the due-date reminders in one call (app launch, "Mes tâches" reload, lead time change, background
 * refresh). Reads the lead time from the store; when notifications are not authorized, every pending reminder is
 * removed (they would not be shown anyway).
 *
 * Create one instance and share it app-wide: synchronizations run one at a time, in call order (they would otherwise
 * interleave their scheduling calls and leave fingerprints that no longer describe the pending requests), and
 * [removeAll] supersedes every synchronization started before it, even one still waiting for the platform: that one
 * schedules nothing more and withdraws what it has just scheduled.
 *
 * Swift actor → class whose synchronizations are serialized by a (fair) [Mutex]; thread-safe.
 */
class ReminderSynchronizer(
    private val scheduler: NotificationScheduler,
    private val store: KeyValueStore,
    calendar: AppCalendar,
    private val now: NowProvider,
    maxPending: Int = ReminderPlanner.DEFAULT_MAX_PENDING,
) {
    constructor(platform: PlatformServices) : this(
        scheduler = platform.notifications,
        store = platform.store,
        calendar = platform.calendar,
        now = platform.now,
    )

    val planner: ReminderPlanner = ReminderPlanner(calendar, maxPending)
    private val reconciler = ReminderReconciler(scheduler, store)

    /** Bumped by [removeAll]. */
    private val epoch = AtomicInteger(0)
    private val mutex = Mutex()

    /**
     * Reconciles the pending reminders with [myTasks] (tasks assigned to [userId]). Waits for the synchronization in
     * progress, then reads the lead time; does nothing if [removeAll] was called since.
     * Only call it with a successfully loaded list (an empty list after a network error would remove every reminder).
     */
    suspend fun synchronize(myTasks: List<TaskItem>, userId: UUID): ReminderReconciliation {
        val started = epoch.get()
        return mutex.withLock {
            if (epoch.get() != started) return@withLock ReminderReconciliation()
            val leadTime = ReminderLeadTime.load(store)
            val authorized = scheduler.authorizationStatus() == NotificationAuthorization.AUTHORIZED
            val desired = if (authorized) planner.plan(myTasks, userId, leadTime, now()) else emptyList()
            reconciler.apply(desired) { epoch.get() == started }
        }
    }

    /**
     * Removes every pending reminder (sign-out, account deletion). Does not wait for a synchronization in progress (it
     * may be blocked in the platform): that one is superseded and withdraws its late requests.
     */
    suspend fun removeAll(): ReminderReconciliation {
        epoch.incrementAndGet()
        return reconciler.apply(emptyList())
    }
}

/** FNV-1a 64-bit hash: stable across processes and platforms (unlike `hashCode`). */
internal object StableHash {
    fun fnv1a64Hex(text: String): String {
        var hash = 0xcbf29ce484222325UL
        for (byte in text.encodeToByteArray()) {
            hash = hash xor byte.toUByte().toULong()
            hash *= 0x100000001b3UL
        }
        return hash.toString(16).padStart(16, '0')
    }
}
