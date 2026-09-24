package io.github.notkanaa.equipe.core

import java.util.UUID

/**
 * Client-side mirror of the server permission matrix (docs/CONTRACTS.md §2).
 * The server (RLS + triggers) is the source of truth; this only drives what the UI offers.
 * `role` is the current user's role in the task's group; null means "not a member" (no rights).
 */
object TaskPermissions {
    fun canView(role: MemberRole?): Boolean = role != null

    fun canCreate(role: MemberRole?): Boolean = role != null

    /** Edit title, details, priority, due date and assignees. */
    fun canEdit(task: TaskItem, userId: UUID, role: MemberRole?): Boolean {
        if (role == null) return false
        return role == MemberRole.ADMIN || task.createdBy == userId
    }

    fun canChangeStatus(task: TaskItem, userId: UUID, role: MemberRole?): Boolean {
        if (role == null) return false
        return canEdit(task, userId, role) || userId in task.assigneeIds
    }

    fun canDelete(task: TaskItem, userId: UUID, role: MemberRole?): Boolean = canEdit(task, userId, role)
}

object GroupPermissions {
    fun canRename(role: MemberRole?): Boolean = role == MemberRole.ADMIN

    fun canDelete(role: MemberRole?): Boolean = role == MemberRole.ADMIN

    fun canSeeInviteCode(role: MemberRole?): Boolean = role == MemberRole.ADMIN

    fun canManageMembers(role: MemberRole?): Boolean = role == MemberRole.ADMIN

    fun canLeave(role: MemberRole?): Boolean = role != null
}
