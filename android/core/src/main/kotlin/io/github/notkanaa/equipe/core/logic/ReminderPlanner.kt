package io.github.notkanaa.equipe.core.logic

import io.github.notkanaa.equipe.core.AppCalendar
import io.github.notkanaa.equipe.core.LocalNotification
import io.github.notkanaa.equipe.core.TaskItem
import io.github.notkanaa.equipe.core.TaskStatus
import io.github.notkanaa.equipe.core.compareLikeSwift
import io.github.notkanaa.equipe.core.uuidString
import java.time.Instant
import java.util.UUID

// Port of TeamTasksCore/Logic/ReminderPlanner.swift.

/**
 * Computes the due-date reminders that should be pending (docs/CONTRACTS.md §7). Pure: no side effects.
 *
 * Rules: only tasks assigned to `userId`, not done, with a due date; the reminder fires at `dueAt - leadTime` and is
 * kept only if that date is strictly after `now`; at most [maxPending] reminders (iOS keeps 64 pending requests per
 * app), the soonest first. Apply the result with [ReminderReconciler].
 *
 * @param calendar time zone of the French wording in the body (and calendar for "1 jour avant").
 * @param maxPending cap on the number of reminders (negative values count as 0).
 */
class ReminderPlanner(
    val calendar: AppCalendar,
    maxPending: Int = DEFAULT_MAX_PENDING,
) {
    val maxPending: Int = maxOf(0, maxPending)

    /**
     * The desired reminders, sorted by fire date (then id), at most [maxPending].
     * @param tasks typically `TaskService.myTasks(includeDone = false)`; other tasks are ignored.
     * @param groupNames fallback group names when [TaskItem.groupName] is null or empty.
     */
    fun plan(
        tasks: List<TaskItem>,
        userId: UUID,
        leadTime: ReminderLeadTime,
        now: Instant,
        groupNames: Map<UUID, String> = emptyMap(),
    ): List<LocalNotification> {
        if (!leadTime.isEnabled || maxPending <= 0) return emptyList()
        val formatter = FrenchDateFormatter(calendar.zone)
        val seenTaskIds = HashSet<UUID>()
        val reminders = ArrayList<Pair<Instant, LocalNotification>>()

        for (task in tasks) {
            if (task.status == TaskStatus.DONE) continue
            val dueAt = task.dueAt ?: continue
            if (!task.isAssignedTo(userId)) continue
            if (!seenTaskIds.add(task.id)) continue
            val fireDate = leadTime.fireDate(dueAt, calendar) ?: continue
            if (fireDate <= now) continue

            val whenText = formatter.relativeDateTime(dueAt, fireDate)
            val groupName = listOfNotNull(task.groupName, groupNames[task.groupId]).firstOrNull { it.isNotEmpty() }
            val body = if (groupName != null) {
                "${task.title} — $groupName, $whenText"
            } else {
                "${task.title}, $whenText"
            }
            val notification = LocalNotification(
                id = identifier(task.id, dueAt),
                title = TITLE,
                body = body,
                fireDate = fireDate,
                userInfo = mapOf("taskId" to task.id.uuidString, "groupId" to task.groupId.uuidString),
                threadId = task.groupId.uuidString,
            )
            reminders.add(fireDate to notification)
        }

        return reminders
            .sortedWith { lhs, rhs ->
                val byDate = lhs.first.compareTo(rhs.first)
                if (byDate != 0) byDate else compareLikeSwift(lhs.second.id, rhs.second.id)
            }
            .take(maxPending)
            .map { it.second }
    }

    override fun equals(other: Any?): Boolean =
        other is ReminderPlanner && calendar == other.calendar && maxPending == other.maxPending

    override fun hashCode(): Int = 31 * calendar.hashCode() + maxPending

    override fun toString(): String = "ReminderPlanner(calendar=$calendar, maxPending=$maxPending)"

    companion object {
        /** Identifier prefix of every reminder. */
        const val IDENTIFIER_PREFIX: String = "due-"

        /** Default cap on pending reminders (leaves room below the iOS limit of 64 for other notifications). */
        const val DEFAULT_MAX_PENDING: Int = 60

        /** Title of every reminder. */
        const val TITLE: String = "Échéance proche"

        /**
         * `due-<taskId>-<dueEpochSeconds>`: the id changes when the due date changes, so the reconciler replaces the
         * reminder.
         */
        fun identifier(taskId: UUID, dueAt: Instant): String =
            "$IDENTIFIER_PREFIX${taskId.uuidString}-${epochSeconds(dueAt)}"

        /** Whole seconds since 1970 (rounded down). */
        fun epochSeconds(date: Instant): Long = date.epochSecond
    }
}
