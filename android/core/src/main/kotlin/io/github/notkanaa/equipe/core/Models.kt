package io.github.notkanaa.equipe.core

import java.time.Instant
import java.util.UUID

// Port of TeamTasksCore/Models/Models.swift. Timestamps are `java.time.Instant`, ids `java.util.UUID`.
// Semantics: docs/CONTRACTS.md.

// region Users

/** Authenticated account (from Supabase Auth). */
data class AuthUser(
    val id: UUID,
    val email: String?,
)

/** Public profile visible to co-members (`public.profiles`). */
data class UserProfile(
    val id: UUID,
    val displayName: String,
)

// endregion

// region Groups

/** Role of a member in a group (`member_role`); [rawValue] is the SQL / JSON value. */
enum class MemberRole(val rawValue: String) {
    ADMIN("admin"),
    MEMBER("member"),
    ;

    companion object {
        /** The role whose SQL value is [rawValue], or null for an unknown value. */
        fun fromRawValue(rawValue: String): MemberRole? = entries.firstOrNull { it.rawValue == rawValue }
    }
}

/**
 * A group of people sharing tasks (`public.groups`).
 * Named `TeamGroup` like on iOS (where `Group` clashes with SwiftUI).
 */
data class TeamGroup(
    val id: UUID,
    val name: String,
    val createdBy: UUID?,
    val createdAt: Instant,
    val lastActivityAt: Instant,
)

/** A group as seen by the current user, with their role in it. */
data class GroupSummary(
    val group: TeamGroup,
    val myRole: MemberRole,
) {
    val id: UUID get() = group.id
}

/** A member of a group (`public.group_members` joined with `public.profiles`). */
data class Membership(
    val groupId: UUID,
    val user: UserProfile,
    val role: MemberRole,
    val joinedAt: Instant,
) {
    val id: UUID get() = user.id
}

/** Result of joining a group with an invite code. An invalid code throws [AppError.InvalidCode]. */
data class JoinResult(
    val groupId: UUID,
    val groupName: String,
    val alreadyMember: Boolean,
)

// endregion

// region Tasks

/** Task status (`task_status`); [rawValue] is the SQL / JSON value. */
enum class TaskStatus(val rawValue: String) {
    TODO("todo"),
    IN_PROGRESS("in_progress"),
    DONE("done"),
    ;

    companion object {
        /** The status whose SQL value is [rawValue], or null for an unknown value. */
        fun fromRawValue(rawValue: String): TaskStatus? = entries.firstOrNull { it.rawValue == rawValue }
    }
}

/**
 * Task priority (`task_priority`); [rawValue] is the SQL / JSON value.
 * The natural order (`compareTo`) is the [rank] order: LOW < MEDIUM < HIGH.
 */
enum class TaskPriority(val rawValue: String, val rank: Int) {
    LOW("low", 0),
    MEDIUM("medium", 1),
    HIGH("high", 2),
    ;

    companion object {
        /** The priority whose SQL value is [rawValue], or null for an unknown value. */
        fun fromRawValue(rawValue: String): TaskPriority? = entries.firstOrNull { it.rawValue == rawValue }
    }
}

/**
 * A task of a group (`public.tasks` + its assignees).
 * Named `TaskItem` like on iOS (where `Task` clashes with Swift Concurrency).
 */
data class TaskItem(
    val id: UUID,
    val groupId: UUID,
    val title: String,
    val details: String? = null,
    val status: TaskStatus = TaskStatus.TODO,
    val priority: TaskPriority = TaskPriority.MEDIUM,
    val dueAt: Instant? = null,
    val createdBy: UUID?,
    val createdAt: Instant,
    val updatedAt: Instant,
    val completedAt: Instant? = null,
    /** User ids of the assignees, sorted by [uuidString] ([UuidStringOrder]). */
    val assigneeIds: List<UUID> = emptyList(),
    /** Only filled by [TaskService.myTasks]: when the current user was assigned (drives the "Nouveau" badge). */
    val myAssignedAt: Instant? = null,
    /** Only filled by [TaskService.myTasks]: the group's name, for display outside the group screen. */
    val groupName: String? = null,
    /**
     * Only filled by [TaskService.myTasks]: who assigned the current user (null: a deleted account, or not a
     * `myTasks` item). A self-assignment is never "Nouveau".
     */
    val myAssignedBy: UUID? = null,
)

/** Editable fields of a task (create / full edit). The status is changed separately with [TaskService.setStatus]. */
data class TaskDraft(
    val title: String = "",
    val details: String = "",
    val priority: TaskPriority = TaskPriority.MEDIUM,
    val dueAt: Instant? = null,
    val assigneeIds: Set<UUID> = emptySet(),
) {
    /** The draft of an existing task (null details become ""). */
    constructor(task: TaskItem) : this(
        title = task.title,
        details = task.details ?: "",
        priority = task.priority,
        dueAt = task.dueAt,
        assigneeIds = task.assigneeIds.toSet(),
    )
}

/** "A task was assigned to me": used for notifications and catch-up after background/offline periods. */
data class AssignmentEvent(
    val taskId: UUID,
    val groupId: UUID,
    val taskTitle: String,
    val groupName: String,
    val assignedBy: UUID?,
    val assignedAt: Instant,
    val dueAt: Instant?,
) {
    val id: UUID get() = taskId
}

// endregion

// region Auth

sealed interface AuthState {
    /** The signed-in user, or null. */
    val user: AuthUser? get() = null

    /** Session not yet restored (splash screen). */
    data object Unknown : AuthState

    data object SignedOut : AuthState

    data class SignedIn(override val user: AuthUser) : AuthState
}

enum class SignUpOutcome {
    /** Account created and session opened. */
    SIGNED_IN,

    /** Account created but the project requires e-mail confirmation first. */
    CONFIRMATION_REQUIRED,
}

// endregion

// region Realtime

sealed interface RealtimeEvent {
    /** Channel (re)connected: anything may have been missed, reload everything. */
    data object Connected : RealtimeEvent

    /** Something changed in this group (tasks, assignees, members or the group itself). */
    data class GroupActivity(val groupId: UUID) : RealtimeEvent

    /** The current user's memberships changed (joined, left, removed, role changed, group deleted). */
    data object MembershipsChanged : RealtimeEvent

    /** A task was assigned to the current user. */
    data class Assigned(val taskId: UUID, val groupId: UUID, val assignedBy: UUID?) : RealtimeEvent
}

// endregion
