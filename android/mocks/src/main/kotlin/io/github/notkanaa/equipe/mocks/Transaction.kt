package io.github.notkanaa.equipe.mocks

import io.github.notkanaa.equipe.core.MemberRole
import java.time.Instant
import java.util.UUID

/**
 * One write "transaction" on a copy of the data. It also records the change signals of docs/CONTRACTS.md §6
 * (at most one bump per group per transaction), applied by [finish].
 */
internal class Transaction(
    /** A private copy of the committed data: the backend commits it only if the whole write succeeds. */
    val data: BackendData,
    /** Like Postgres `now()`: one timestamp for the whole transaction. */
    val now: Instant,
) {
    /** Groups whose `last_activity_at` is bumped (tasks, assignees, members, rename). */
    private val bumpedGroups = HashSet<UUID>()

    /** Groups whose row is updated without a bump (e.g. `created_by` set to NULL): Realtime UPDATE only. */
    private val touchedGroups = HashSet<UUID>()

    /** Users whose `memberships_changed_at` is bumped. */
    private val membershipChangedUsers = HashSet<UUID>()

    /** Users whose profile row is updated for another reason (display name). */
    private val updatedProfiles = HashSet<UUID>()

    /** New `task_assignees` rows (Realtime INSERT), in insertion order. */
    val insertedAssignments = ArrayList<AssigneeRecord>()

    /** Groups that lost a member (safety-net heal trigger). */
    private val groupsThatLostMembers = HashSet<UUID>()

    // region Signals

    fun bump(groupId: UUID) {
        bumpedGroups.add(groupId)
    }

    fun touch(groupId: UUID) {
        touchedGroups.add(groupId)
    }

    fun membershipsChanged(userId: UUID) {
        membershipChangedUsers.add(userId)
    }

    fun profileUpdated(userId: UUID) {
        updatedProfiles.add(userId)
    }

    /** Users whose profile row was updated (→ Realtime `MembershipsChanged`). */
    val profileUpdates: Set<UUID>
        get() = (membershipChangedUsers + updatedProfiles).filterTo(HashSet()) { data.profiles[it] != null }

    /** Groups that emit a Realtime UPDATE (→ `GroupActivity`), in `uuidString` order. */
    val groupActivity: List<UUID>
        get() = (bumpedGroups + touchedGroups).filter { data.groups[it] != null }.sortedByUuidString()

    /** Runs the safety-net heal and applies the signal bumps. Called once, before commit. */
    fun finish() {
        healGroupsWithoutAdmin()
        for (groupId in bumpedGroups) {
            val group = data.groups[groupId] ?: continue
            data.groups[groupId] = group.copy(lastActivityAt = now)
        }
        for (userId in membershipChangedUsers) {
            val profile = data.profiles[userId] ?: continue
            data.profiles[userId] = profile.copy(membershipsChangedAt = now)
        }
    }

    // endregion

    // region Memberships

    fun insertMembership(groupId: UUID, userId: UUID, role: MemberRole) {
        data.members.getOrPut(groupId) { HashMap() }[userId] =
            MemberRecord(groupId = groupId, userId = userId, role = role, joinedAt = now)
        bump(groupId)
        membershipsChanged(userId)
    }

    /** Changes a role; an unchanged role writes nothing (no bump). */
    fun updateRole(groupId: UUID, userId: UUID, role: MemberRole) {
        val members = data.members[groupId] ?: return
        val current = members[userId] ?: return
        if (current.role == role) return
        members[userId] = current.copy(role = role)
        bump(groupId)
        membershipsChanged(userId)
    }

    /** Deletes a membership; the FK cascade deletes the user's assignments in that group. */
    fun deleteMembership(groupId: UUID, userId: UUID) {
        val members = data.members[groupId] ?: return
        if (members.remove(userId) == null) return
        if (members.isEmpty()) data.members.remove(groupId)
        for (taskId in data.taskIds(groupId)) {
            val rows = data.assignees[taskId] ?: continue
            if (rows.remove(userId) != null && rows.isEmpty()) data.assignees.remove(taskId)
        }
        bump(groupId)
        membershipsChanged(userId)
        groupsThatLostMembers.add(groupId)
    }

    /** Deletes a group and cascades to its invite, members, tasks and assignees. */
    fun deleteGroup(groupId: UUID) {
        data.members[groupId]?.keys?.forEach { membershipsChanged(it) }
        data.members.remove(groupId)
        for (taskId in data.taskIds(groupId)) {
            data.tasks.remove(taskId)
            data.assignees.remove(taskId)
        }
        data.invites.remove(groupId)
        data.groups.remove(groupId)
    }

    /** Safety net: a group with members but no admin gets its oldest member promoted. */
    private fun healGroupsWithoutAdmin() {
        for (groupId in groupsThatLostMembers.sortedByUuidString()) {
            if (data.groups[groupId] == null) continue
            val members = data.members[groupId] ?: continue
            if (members.isEmpty() || members.values.any { it.role == MemberRole.ADMIN }) continue
            val oldest = members.values.minWithOrNull(MemberRecord.seniority) ?: continue
            updateRole(groupId, oldest.userId, MemberRole.ADMIN)
        }
    }

    // endregion

    // region Assignees

    fun insertAssignee(taskId: UUID, groupId: UUID, userId: UUID, assignedBy: UUID?) {
        val row = AssigneeRecord(
            taskId = taskId, groupId = groupId, userId = userId, assignedBy = assignedBy, assignedAt = now,
        )
        data.assignees.getOrPut(taskId) { HashMap() }[userId] = row
        insertedAssignments.add(row)
        bump(groupId)
    }

    /**
     * `set_task_assignees`: keeps rows (and their metadata) of users still listed, deletes the others, inserts the
     * new ones with `assigned_by = me`.
     */
    fun replaceAssignees(task: TaskRecord, userIds: Set<UUID>, me: UUID) {
        val current = data.assignees[task.id]?.keys?.toSet() ?: emptySet()
        for (userId in current - userIds) {
            data.assignees[task.id]?.remove(userId)
            bump(task.groupId)
        }
        for (userId in (userIds - current).sortedByUuidString()) {
            insertAssignee(taskId = task.id, groupId = task.groupId, userId = userId, assignedBy = me)
        }
        if (data.assignees[task.id]?.isEmpty() == true) data.assignees.remove(task.id)
    }

    // endregion

    // region Accounts

    /** `delete_my_account()` (docs/CONTRACTS.md §2), then the cascade of deleting the auth user. */
    fun deleteAccount(userId: UUID) {
        for (groupId in data.groupIds(userId)) {
            val members = data.members[groupId] ?: continue
            if (members.size == 1) {
                deleteGroup(groupId)
                continue
            }
            if (members[userId]?.role == MemberRole.ADMIN && data.adminCount(groupId) == 1) {
                val oldest = members.values.filter { it.userId != userId }.minWithOrNull(MemberRecord.seniority)
                if (oldest != null) updateRole(groupId, oldest.userId, MemberRole.ADMIN)
            }
        }
        // auth.users → profiles → group_members (and their assignments) cascade.
        for (groupId in data.groupIds(userId)) {
            deleteMembership(groupId, userId)
        }
        // ON DELETE SET NULL fires the UPDATE triggers: the group bumps, but `tasks_before_update` keeps
        // `updated_at` (no editable field changed).
        for (task in data.tasks.values.toList()) {
            if (task.createdBy != userId) continue
            data.tasks[task.id] = task.copy(createdBy = null)
            bump(task.groupId)
        }
        for (rows in data.assignees.values) {
            for (row in rows.values.toList()) {
                if (row.assignedBy != userId) continue
                rows[row.userId] = row.copy(assignedBy = null)
                bump(row.groupId)
            }
        }
        for (group in data.groups.values.toList()) {
            if (group.createdBy != userId) continue
            data.groups[group.id] = group.copy(createdBy = null)
            touch(group.id)
        }
        for (invite in data.invites.values.toList()) {
            if (invite.createdBy != userId) continue
            data.invites[invite.groupId] = invite.copy(createdBy = null)
        }
        data.pushTopics.remove(userId)
        data.recoveries.remove(userId)
        data.profiles.remove(userId)
        data.accounts.remove(userId)
        membershipChangedUsers.remove(userId)
        updatedProfiles.remove(userId)
    }

    // endregion
}
