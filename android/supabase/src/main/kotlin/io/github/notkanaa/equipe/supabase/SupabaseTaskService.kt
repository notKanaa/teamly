package io.github.notkanaa.equipe.supabase

import io.github.notkanaa.equipe.core.AppError
import io.github.notkanaa.equipe.core.AssignmentEvent
import io.github.notkanaa.equipe.core.TaskDraft
import io.github.notkanaa.equipe.core.TaskItem
import io.github.notkanaa.equipe.core.TaskService
import io.github.notkanaa.equipe.core.TaskStatus
import kotlinx.serialization.json.JsonElement
import java.time.Instant
import java.util.UUID

/** [TaskService] on the task RPCs and PostgREST reads (docs/CONTRACTS.md §1, §3, §4). Port of SupabaseTaskService.swift. */
internal class SupabaseTaskService(private val context: SupabaseContext) : TaskService {
    private val rest get() = context.rest

    /**
     * Unless [includeOldDone]: `or=(status.neq.done,completed_at.gte.<now − 30 × 86 400 s>)`. Non-members read an empty
     * list (RLS). Tasks with a status or priority unknown to this client (added by a later migration) are left out.
     */
    override suspend fun tasks(groupId: UUID, includeOldDone: Boolean): List<TaskItem> {
        val now = context.now()
        val rows = rest.fetchRows(TaskRow::decode) { RestQuery.groupTasks(groupId, includeOldDone, now) }
        return rows.map { it.item() }.sortedWith(TaskRow.creationOrder)
    }

    /** Tasks with a status or priority unknown to this client are left out, as in [tasks]. */
    override suspend fun myTasks(includeDone: Boolean): List<TaskItem> {
        val rows = rest.fetchRows(TaskRow::decode) { RestQuery.myTasks(it.userId, includeDone) }
        return rows.map { it.myTaskItem }.sortedWith(TaskRow.creationOrder)
    }

    /** 0 rows (unknown or not visible) → [AppError.NotFound]; an enum value unknown to this client → `Unknown`. */
    override suspend fun task(id: UUID): TaskItem {
        val rows = rest.fetchAll(TaskRow::decode) { RestQuery.task(id) }
        return rows.firstOrNull()?.item() ?: throw AppError.NotFound
    }

    /** `create_task` returns a bare `tasks` row; its assignees are exactly the (validated) draft's. */
    override suspend fun create(groupId: UUID, draft: TaskDraft): TaskItem {
        val fields = TaskFields(draft)
        val row = rest.fetch(::taskRow) { RestQuery.rpc("create_task", fields.params("p_group_id" to JsonValues.uuid(groupId))) }
        return row.item(assigneeIds = draft.assigneeIds)
    }

    /** `update_task` (full edit, atomic) replaces the assignees by the draft's. */
    override suspend fun update(taskId: UUID, draft: TaskDraft): TaskItem {
        val fields = TaskFields(draft)
        val row = rest.fetch(::taskRow) { RestQuery.rpc("update_task", fields.params("p_task_id" to JsonValues.uuid(taskId))) }
        return row.item(assigneeIds = draft.assigneeIds)
    }

    /**
     * `set_task_status` returns a bare `tasks` row: the assignees come from a read of the task, so the result equals a
     * later [task].
     */
    override suspend fun setStatus(taskId: UUID, status: TaskStatus): TaskItem {
        val row = rest.fetch(::taskRow) {
            RestQuery.rpc(
                "set_task_status",
                mapOf("p_task_id" to JsonValues.uuid(taskId), "p_status" to JsonValues.string(status.rawValue)),
            )
        }
        val assignees = try {
            task(taskId).assigneeIds
        } catch (error: AppError.NotFound) {
            emptyList() // deleted (or hidden) right after the change
        }
        return row.item(assigneeIds = assignees)
    }

    override suspend fun delete(taskId: UUID) {
        rest.send { RestQuery.rpc("delete_task", mapOf("p_task_id" to JsonValues.uuid(taskId))) }
    }

    /** Exclusive [since] sent with microseconds; oldest first (then task id for equal instants). */
    override suspend fun assignments(since: Instant): List<AssignmentEvent> {
        val rows = rest.fetchAll(AssignmentRow::decode) { RestQuery.assignments(it.userId, since) }
        return rows.mapNotNull { it.event }.sortedWith(AssignmentRow.order)
    }

    private fun taskRow(element: JsonElement): TaskRow = TaskRow.decode(element.asObject("task"))
}
