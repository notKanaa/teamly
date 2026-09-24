package io.github.notkanaa.equipe.supabase

import io.github.notkanaa.equipe.core.AppError
import io.github.notkanaa.equipe.core.AssignmentEvent
import io.github.notkanaa.equipe.core.GroupSummary
import io.github.notkanaa.equipe.core.JoinResult
import io.github.notkanaa.equipe.core.MemberRole
import io.github.notkanaa.equipe.core.Membership
import io.github.notkanaa.equipe.core.TaskItem
import io.github.notkanaa.equipe.core.TaskPriority
import io.github.notkanaa.equipe.core.TaskStatus
import io.github.notkanaa.equipe.core.TeamGroup
import io.github.notkanaa.equipe.core.UserProfile
import io.github.notkanaa.equipe.core.UuidStringOrder
import io.github.notkanaa.equipe.core.uuidString
import kotlinx.serialization.json.JsonObject
import java.time.Instant
import java.util.UUID

// JSON rows returned by PostgREST for the reads and RPCs of docs/CONTRACTS.md §4 (port of Rows.swift). Column names
// are the SQL ones; embedded resources use the aliases of the `select` parameters (`group`, `profile`, `assignees`,
// `mine`, `task`). Fields are decoded in the order of the Swift declarations, so that a row both malformed and holding
// an unknown enum value fails (or is skipped) exactly like on iOS.

/** `public.groups` row (`create_group`, `rename_group`, embedded `group:groups(*)`). */
internal data class GroupRow(
    val id: UUID,
    val name: String,
    val createdBy: UUID?,
    val createdAt: Instant,
    val lastActivityAt: Instant,
) {
    val teamGroup: TeamGroup get() = TeamGroup(id, name, createdBy, createdAt, lastActivityAt)

    companion object {
        fun decode(json: JsonObject) = GroupRow(
            id = json.requiredUuid("id"),
            name = json.requiredString("name"),
            createdBy = json.optionalUuid("created_by"),
            createdAt = json.requiredInstant("created_at"),
            lastActivityAt = json.requiredInstant("last_activity_at"),
        )
    }
}

/** `group_members?select=role,group:groups(*)`. */
internal data class MyGroupRow(val role: MemberRole, val group: GroupRow) {
    val summary: GroupSummary get() = GroupSummary(group.teamGroup, role)

    companion object {
        fun decode(json: JsonObject): MyGroupRow {
            val role = json.known("role", "member_role", MemberRole::fromRawValue)
            val group = GroupRow.decode(json["group"]?.asObject("group") ?: throw MalformedAnswer("group is missing"))
            return MyGroupRow(role, group)
        }
    }
}

/** `profiles?select=id,display_name` (also the embedded `profile:profiles(id,display_name)`). */
internal data class ProfileRow(val id: UUID, val displayName: String) {
    val profile: UserProfile get() = UserProfile(id, displayName)

    companion object {
        fun decode(json: JsonObject) = ProfileRow(json.requiredUuid("id"), json.requiredString("display_name"))
    }
}

/** `group_members?select=user_id,role,joined_at,profile:profiles(id,display_name)`. */
internal data class MemberRow(val userId: UUID, val role: MemberRole, val joinedAt: Instant, val profile: ProfileRow?) {
    fun membership(groupId: UUID): Membership =
        Membership(groupId, UserProfile(userId, profile?.displayName ?: ""), role, joinedAt)

    companion object {
        fun decode(json: JsonObject): MemberRow {
            val userId = json.requiredUuid("user_id")
            val role = json.known("role", "member_role", MemberRole::fromRawValue)
            val joinedAt = json.requiredInstant("joined_at")
            val profile = json.optionalObject("profile")?.let(ProfileRow::decode)
            return MemberRow(userId, role, joinedAt, profile)
        }
    }
}

/** `group_invites?select=code`. */
internal data class InviteRow(val code: String) {
    companion object {
        fun decode(json: JsonObject) = InviteRow(json.requiredString("code"))
    }
}

/** `push_subscriptions?select=topic`. */
internal data class PushTopicRow(val topic: String) {
    companion object {
        fun decode(json: JsonObject) = PushTopicRow(json.requiredString("topic"))
    }
}

/** `join_group_by_code` result: `{status, group_id, group_name}`. */
internal data class JoinRow(val status: String, val groupId: UUID?, val groupName: String?) {
    /** The join result; `invalid_code` → [AppError.InvalidCode]. */
    fun result(): JoinResult = when (status) {
        "joined", "already_member" -> {
            if (groupId == null || groupName == null) throw RestDecoding.unexpectedAnswer()
            JoinResult(groupId, groupName, alreadyMember = status == "already_member")
        }
        "invalid_code" -> throw AppError.InvalidCode
        else -> throw RestDecoding.unexpectedAnswer()
    }

    companion object {
        fun decode(json: JsonObject) = JoinRow(
            status = json.requiredString("status"),
            groupId = json.optionalUuid("group_id"),
            groupName = json.optionalString("group_name"),
        )
    }
}

/** `{assigned_at, assigned_by, user_id}` of the embedded `mine:task_assignees!inner(assigned_at,assigned_by,user_id)`. */
internal data class MyAssignmentRow(
    val assignedAt: Instant,
    /** NULL when the assigner deleted their account. */
    val assignedBy: UUID?,
    val userId: UUID,
) {
    companion object {
        fun decode(json: JsonObject) = MyAssignmentRow(
            assignedAt = json.requiredInstant("assigned_at"),
            assignedBy = json.optionalUuid("assigned_by"),
            userId = json.requiredUuid("user_id"),
        )
    }
}

/** `public.tasks` row, bare (RPC results) or with the embedded resources of the task reads. */
internal data class TaskRow(
    val id: UUID,
    val groupId: UUID,
    val title: String,
    val details: String?,
    val status: TaskStatus,
    val priority: TaskPriority,
    val dueAt: Instant?,
    val createdBy: UUID?,
    val createdAt: Instant,
    val updatedAt: Instant,
    val completedAt: Instant?,
    /** `assignees:task_assignees(user_id)` (absent from RPC results). */
    val assignees: List<UUID>?,
    /** `mine:task_assignees!inner(assigned_at,assigned_by,user_id)` (`myTasks` only). */
    val mine: List<MyAssignmentRow>?,
    /** `group:groups(name)` (`myTasks` only). */
    val groupName: String?,
) {
    /** The task; `assigneeIds` defaults to the embedded assignees, sorted by `uuidString`. */
    fun item(assigneeIds: Collection<UUID>? = null): TaskItem = TaskItem(
        id = id,
        groupId = groupId,
        title = title,
        details = details,
        status = status,
        priority = priority,
        dueAt = dueAt,
        createdBy = createdBy,
        createdAt = createdAt,
        updatedAt = updatedAt,
        completedAt = completedAt,
        assigneeIds = sorted(assigneeIds ?: assignees.orEmpty()),
    )

    /** `myTasks` item: also `myAssignedAt`, `myAssignedBy` and `groupName`. */
    val myTaskItem: TaskItem
        get() = item().copy(
            myAssignedAt = mine?.firstOrNull()?.assignedAt,
            myAssignedBy = mine?.firstOrNull()?.assignedBy,
            groupName = groupName,
        )

    companion object {
        fun decode(json: JsonObject) = TaskRow(
            id = json.requiredUuid("id"),
            groupId = json.requiredUuid("group_id"),
            title = json.requiredString("title"),
            details = json.optionalString("details"),
            status = json.known("status", "task_status", TaskStatus::fromRawValue),
            priority = json.known("priority", "task_priority", TaskPriority::fromRawValue),
            dueAt = json.optionalInstant("due_at"),
            createdBy = json.optionalUuid("created_by"),
            createdAt = json.requiredInstant("created_at"),
            updatedAt = json.requiredInstant("updated_at"),
            completedAt = json.optionalInstant("completed_at"),
            assignees = json.optionalArray("assignees") { it.requiredUuid("user_id") },
            mine = json.optionalArray("mine", MyAssignmentRow::decode),
            groupName = json.optionalObject("group")?.requiredString("name"),
        )

        /** Distinct ids sorted by `uuidString` (never by `UUID.compareTo`). */
        fun sorted(ids: Collection<UUID>): List<UUID> = ids.toSet().sortedWith(UuidStringOrder)

        /** Deterministic order for task lists (the server order is unspecified; view models sort with `TaskSort`). */
        val creationOrder: Comparator<TaskItem> = Comparator { lhs, rhs ->
            val byCreation = lhs.createdAt.compareTo(rhs.createdAt)
            if (byCreation != 0) byCreation else lhs.id.uuidString.compareTo(rhs.id.uuidString)
        }
    }
}

/** `task_assignees?select=task_id,group_id,assigned_by,assigned_at,task:tasks(title,due_at,group:groups(name))`. */
internal data class AssignmentRow(
    val taskId: UUID,
    val groupId: UUID,
    val assignedBy: UUID?,
    val assignedAt: Instant,
    val task: EmbeddedTask?,
) {
    data class EmbeddedTask(val title: String, val dueAt: Instant?, val groupName: String?)

    /** The event; null when the task is not visible (embedded resource missing). */
    val event: AssignmentEvent?
        get() {
            val task = task ?: return null
            return AssignmentEvent(
                taskId = taskId,
                groupId = groupId,
                taskTitle = task.title,
                groupName = task.groupName ?: "",
                assignedBy = assignedBy,
                assignedAt = assignedAt,
                dueAt = task.dueAt,
            )
        }

    companion object {
        fun decode(json: JsonObject) = AssignmentRow(
            taskId = json.requiredUuid("task_id"),
            groupId = json.requiredUuid("group_id"),
            assignedBy = json.optionalUuid("assigned_by"),
            assignedAt = json.requiredInstant("assigned_at"),
            task = json.optionalObject("task")?.let { task ->
                EmbeddedTask(
                    title = task.requiredString("title"),
                    dueAt = task.optionalInstant("due_at"),
                    groupName = task.optionalObject("group")?.requiredString("name"),
                )
            },
        )

        /** Oldest first; equal instants by task id (`uuidString`). */
        val order: Comparator<AssignmentEvent> = Comparator { lhs, rhs ->
            val byTime = lhs.assignedAt.compareTo(rhs.assignedAt)
            if (byTime != 0) byTime else lhs.taskId.uuidString.compareTo(rhs.taskId.uuidString)
        }
    }
}
