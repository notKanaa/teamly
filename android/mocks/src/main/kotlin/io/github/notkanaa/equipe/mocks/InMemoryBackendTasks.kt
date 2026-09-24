package io.github.notkanaa.equipe.mocks

import io.github.notkanaa.equipe.core.AppError
import io.github.notkanaa.equipe.core.AssignmentEvent
import io.github.notkanaa.equipe.core.Limits
import io.github.notkanaa.equipe.core.TaskDraft
import io.github.notkanaa.equipe.core.TaskItem
import io.github.notkanaa.equipe.core.TaskStatus
import io.github.notkanaa.equipe.core.uuidString
import java.time.Instant
import java.util.UUID

// Tasks and assignees (docs/CONTRACTS.md §2, §4).

// region Reads

/**
 * Tasks of a group (empty for non-members, like RLS). Unless [includeOldDone], done tasks completed before
 * `now - Limits.oldDoneTaskDays` are omitted (`completed_at.gte.<now-30d>` keeps the boundary).
 */
internal fun InMemoryBackend.tasks(clientId: UUID, groupId: UUID, includeOldDone: Boolean): List<TaskItem> =
    read(clientId) { data, me ->
        if (!data.isMember(me, groupId)) return@read emptyList()
        val cutoff = now().minusSeconds(Limits.oldDoneTaskDays.toLong() * 86_400L)
        data.tasks.values
            .filter { task ->
                when {
                    task.groupId != groupId -> false
                    includeOldDone || task.status != TaskStatus.DONE -> true
                    else -> task.completedAt != null && task.completedAt >= cutoff
                }
            }
            .sortedWith(TaskRecord.creationOrder)
            .map { data.taskItem(it) }
    }

/**
 * Tasks assigned to the caller, with `myAssignedAt`, `myAssignedBy` and `groupName`. Unless [includeDone], done
 * tasks are omitted.
 */
internal fun InMemoryBackend.myTasks(clientId: UUID, includeDone: Boolean): List<TaskItem> =
    read(clientId) { data, me ->
        data.tasks.values
            .filter { task -> data.assignees[task.id]?.get(me) != null && (includeDone || task.status != TaskStatus.DONE) }
            .sortedWith(TaskRecord.creationOrder)
            .map { task ->
                val mine = data.assignees[task.id]?.get(me)
                data.taskItem(task).copy(
                    myAssignedAt = mine?.assignedAt,
                    myAssignedBy = mine?.assignedBy,
                    groupName = data.groups[task.groupId]?.name,
                )
            }
    }

/** One task; [AppError.NotFound] when it does not exist or is not visible. */
internal fun InMemoryBackend.task(clientId: UUID, taskId: UUID): TaskItem = read(clientId) { data, me ->
    val task = data.visibleTask(taskId, me) ?: throw AppError.NotFound
    data.taskItem(task)
}

/** Assignments of the caller made by someone else (or by a deleted user) strictly after [since], oldest first. */
internal fun InMemoryBackend.assignments(clientId: UUID, since: Instant): List<AssignmentEvent> =
    read(clientId) { data, me ->
        data.assignees.values
            .mapNotNull { it[me] }
            .filter { it.assignedAt > since && it.assignedBy != me }
            .sortedWith(compareBy<AssigneeRecord> { it.assignedAt }.thenBy { it.taskId.uuidString })
            .mapNotNull { row ->
                val task = data.tasks[row.taskId] ?: return@mapNotNull null
                val group = data.groups[row.groupId] ?: return@mapNotNull null
                AssignmentEvent(
                    taskId = task.id,
                    groupId = group.id,
                    taskTitle = task.title,
                    groupName = group.name,
                    assignedBy = row.assignedBy,
                    assignedAt = row.assignedAt,
                    dueAt = task.dueAt,
                )
            }
    }

// endregion

// region RPCs

/** `create_task`: members only ([AppError.Forbidden] otherwise), atomic insert of the task and its assignees. */
internal fun InMemoryBackend.createTask(clientId: UUID, groupId: UUID, draft: TaskDraft): TaskItem =
    write(clientId) { transaction, me ->
        if (!transaction.data.isMember(me, groupId)) throw AppError.Forbidden
        val title = InputRules.title(draft.title)
        val details = InputRules.details(draft.details)
        val dueAt = InputRules.dueDate(draft.dueAt)
        InputRules.assignees(draft.assigneeIds, groupId, transaction.data)
        val task = TaskRecord(
            id = UUID.randomUUID(),
            groupId = groupId,
            title = title,
            details = details,
            status = TaskStatus.TODO,
            priority = draft.priority,
            dueAt = dueAt,
            createdBy = me,
            createdAt = transaction.now,
            updatedAt = transaction.now,
            completedAt = null,
        )
        transaction.data.tasks[task.id] = task
        transaction.bump(groupId)
        for (userId in draft.assigneeIds.sortedByUuidString()) {
            transaction.insertAssignee(taskId = task.id, groupId = groupId, userId = userId, assignedBy = me)
        }
        transaction.data.taskItem(task)
    }

/**
 * `update_task`: full edit (fields + assignees), admin or creator only. A null due date clears it.
 * The row is always updated (group bump), `updatedAt` only moves when a field changes.
 */
internal fun InMemoryBackend.updateTask(clientId: UUID, taskId: UUID, draft: TaskDraft): TaskItem =
    write(clientId) { transaction, me ->
        val stored = transaction.data.visibleTask(taskId, me) ?: throw AppError.NotFound
        if (!transaction.data.canEdit(stored, me)) throw AppError.Forbidden
        val title = InputRules.title(draft.title)
        val details = InputRules.details(draft.details)
        val dueAt = InputRules.dueDate(draft.dueAt)
        InputRules.assignees(draft.assigneeIds, stored.groupId, transaction.data)
        val task = stored.copy(title = title, details = details, dueAt = dueAt, priority = draft.priority)
            .touched(stored, transaction.now)
        transaction.data.tasks[task.id] = task
        transaction.bump(task.groupId)
        transaction.replaceAssignees(task, draft.assigneeIds, me)
        transaction.data.taskItem(task)
    }

/**
 * `set_task_status`: admin, creator or assignee. `completed_at` is set when the task becomes done (kept if it
 * already was) and cleared otherwise; `updatedAt` only moves when the status changes.
 */
internal fun InMemoryBackend.setStatus(clientId: UUID, taskId: UUID, status: TaskStatus): TaskItem =
    write(clientId) { transaction, me ->
        val stored = transaction.data.visibleTask(taskId, me) ?: throw AppError.NotFound
        if (!transaction.data.canChangeStatus(stored, me)) throw AppError.Forbidden
        val completedAt = when {
            status != TaskStatus.DONE -> null
            stored.status != TaskStatus.DONE -> transaction.now
            else -> stored.completedAt
        }
        val task = stored.copy(status = status, completedAt = completedAt).touched(stored, transaction.now)
        transaction.data.tasks[task.id] = task
        transaction.bump(task.groupId)
        transaction.data.taskItem(task)
    }

/** `delete_task`: admin or creator only; cascades to assignees. */
internal fun InMemoryBackend.deleteTask(clientId: UUID, taskId: UUID) {
    write(clientId) { transaction, me ->
        val task = transaction.data.visibleTask(taskId, me) ?: throw AppError.NotFound
        if (!transaction.data.canEdit(task, me)) throw AppError.Forbidden
        transaction.data.tasks.remove(task.id)
        transaction.data.assignees.remove(task.id)
        transaction.bump(task.groupId)
    }
}

// endregion
