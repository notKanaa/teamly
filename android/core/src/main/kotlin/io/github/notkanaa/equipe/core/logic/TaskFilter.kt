package io.github.notkanaa.equipe.core.logic

import io.github.notkanaa.equipe.core.TaskItem
import io.github.notkanaa.equipe.core.TaskStatus
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import java.time.Instant
import java.util.UUID

// Port of TeamTasksCore/Logic/TaskFilter.swift.

/** True when the task is not done and its due date is strictly before [now]. */
fun TaskItem.isOverdue(now: Instant): Boolean {
    if (status == TaskStatus.DONE) return false
    val due = dueAt ?: return false
    return due < now
}

/** True when [userId] is one of the task's assignees. */
fun TaskItem.isAssignedTo(userId: UUID): Boolean = assigneeIds.contains(userId)

/**
 * Status criterion of a task list ("Toutes", "À faire", "En cours", "Terminées", "Non terminées").
 * [rawValue] is the Swift raw value, also the JSON value.
 */
@Serializable
enum class TaskStatusFilter(val rawValue: String, val label: String) {
    @SerialName("all")
    ALL("all", "Toutes"),

    @SerialName("todo")
    TODO("todo", "À faire"),

    @SerialName("inProgress")
    IN_PROGRESS("inProgress", "En cours"),

    @SerialName("done")
    DONE("done", "Terminées"),

    /** `TODO` or `IN_PROGRESS`. */
    @SerialName("notDone")
    NOT_DONE("notDone", "Non terminées"),
    ;

    val id: String get() = rawValue

    fun matches(status: TaskStatus): Boolean = when (this) {
        ALL -> true
        TODO -> status == TaskStatus.TODO
        IN_PROGRESS -> status == TaskStatus.IN_PROGRESS
        DONE -> status == TaskStatus.DONE
        NOT_DONE -> status != TaskStatus.DONE
    }

    companion object {
        /** The filter whose raw value is [rawValue], or null. */
        fun fromRawValue(rawValue: String): TaskStatusFilter? = entries.firstOrNull { it.rawValue == rawValue }
    }
}

/**
 * Filter of a task list (group screen, "Mes tâches"). All criteria are combined with AND.
 * Pure value type: [apply] keeps the input order (sort separately with [TaskSort]).
 */
@Serializable
data class TaskFilter(
    val status: TaskStatusFilter = TaskStatusFilter.ALL,
    /** Only tasks assigned to the current user. */
    val onlyAssignedToMe: Boolean = false,
    /** Only overdue tasks (not done, due date in the past). */
    val onlyOverdue: Boolean = false,
) {
    /** Number of criteria that differ from [ALL] (for a "Filtres (2)" badge). */
    val activeCriteriaCount: Int
        get() = (if (status == TaskStatusFilter.ALL) 0 else 1) + (if (onlyAssignedToMe) 1 else 0) +
            (if (onlyOverdue) 1 else 0)

    /** True when at least one criterion is set. */
    val isActive: Boolean get() = activeCriteriaCount > 0

    /**
     * @param userId the current user; when null, "assigned to me" matches nothing.
     * @param now reference date for "overdue".
     */
    fun matches(task: TaskItem, userId: UUID?, now: Instant): Boolean {
        if (!status.matches(task.status)) return false
        if (onlyAssignedToMe && (userId == null || !task.isAssignedTo(userId))) return false
        if (onlyOverdue && !task.isOverdue(now)) return false
        return true
    }

    /** Tasks matching the filter, in their original order. */
    fun apply(tasks: List<TaskItem>, userId: UUID?, now: Instant): List<TaskItem> =
        tasks.filter { matches(it, userId, now) }

    companion object {
        /** Shows everything. */
        val ALL: TaskFilter = TaskFilter()
    }
}
