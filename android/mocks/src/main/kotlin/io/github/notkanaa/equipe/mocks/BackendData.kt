package io.github.notkanaa.equipe.mocks

import io.github.notkanaa.equipe.core.AuthUser
import io.github.notkanaa.equipe.core.InviteCode
import io.github.notkanaa.equipe.core.MemberRole
import io.github.notkanaa.equipe.core.Membership
import io.github.notkanaa.equipe.core.TaskItem
import io.github.notkanaa.equipe.core.TaskPriority
import io.github.notkanaa.equipe.core.TaskStatus
import io.github.notkanaa.equipe.core.TeamGroup
import io.github.notkanaa.equipe.core.UserProfile
import io.github.notkanaa.equipe.core.uuidString
import java.time.Instant
import java.util.UUID
import kotlin.random.Random

// Rows of the in-memory "database". They mirror the tables of docs/CONTRACTS.md §3. Rows are immutable values:
// updates replace them (`copy`), so a transaction working on a copy of the maps never touches the committed state.

internal data class AccountRecord(
    val id: UUID,
    /** Trimmed and lowercased (Supabase Auth stores e-mails lowercased). */
    val email: String,
    val password: String,
    val createdAt: Instant,
)

internal data class ProfileRecord(
    val id: UUID,
    val displayName: String,
    val membershipsChangedAt: Instant,
    val createdAt: Instant,
    val updatedAt: Instant,
)

internal data class GroupRecord(
    val id: UUID,
    val name: String,
    val createdBy: UUID?,
    val createdAt: Instant,
    val lastActivityAt: Instant,
)

internal data class InviteRecord(
    val groupId: UUID,
    val code: String,
    val createdBy: UUID?,
    val createdAt: Instant,
)

internal data class MemberRecord(
    val groupId: UUID,
    val userId: UUID,
    val role: MemberRole,
    val joinedAt: Instant,
) {
    companion object {
        /**
         * Seniority order used to pick the member to promote: `joined_at`, then `user_id`.
         * Upper-case `uuidString` order equals the byte order Postgres uses for `uuid`.
         */
        val seniority: Comparator<MemberRecord> =
            compareBy<MemberRecord> { it.joinedAt }.thenBy { it.userId.uuidString }
    }
}

internal data class TaskRecord(
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
) {
    /** `tasks_before_update`: `updated_at` moves only when title, details, status, priority or due date changed. */
    fun touched(stored: TaskRecord, now: Instant): TaskRecord {
        val changed = title != stored.title || details != stored.details || status != stored.status ||
            priority != stored.priority || dueAt != stored.dueAt
        return copy(updatedAt = if (changed) now else stored.updatedAt)
    }

    companion object {
        /** `created_at`, then id (`uuidString`): the stable order of the task reads. */
        val creationOrder: Comparator<TaskRecord> =
            compareBy<TaskRecord> { it.createdAt }.thenBy { it.id.uuidString }
    }
}

internal data class AssigneeRecord(
    val taskId: UUID,
    val groupId: UUID,
    val userId: UUID,
    val assignedBy: UUID?,
    val assignedAt: Instant,
)

internal data class PushRecord(
    val userId: UUID,
    val topic: String,
    val createdAt: Instant,
)

internal data class JoinAttemptRecord(
    val userId: UUID,
    val attemptedAt: Instant,
    val succeeded: Boolean,
)

internal data class RecoveryRecord(
    val userId: UUID,
    val code: String,
    val createdAt: Instant,
)

/**
 * The whole persistent state. A transaction works on a [copy] (every map copied, rows shared since they are
 * immutable) and the backend commits it by swapping the reference, like a Postgres transaction.
 */
internal class BackendData(
    val accounts: HashMap<UUID, AccountRecord> = HashMap(),
    val profiles: HashMap<UUID, ProfileRecord> = HashMap(),
    val groups: HashMap<UUID, GroupRecord> = HashMap(),
    /** Keyed by group id (one invite per group). */
    val invites: HashMap<UUID, InviteRecord> = HashMap(),
    /** group id → user id → membership. */
    val members: HashMap<UUID, HashMap<UUID, MemberRecord>> = HashMap(),
    val tasks: HashMap<UUID, TaskRecord> = HashMap(),
    /** task id → user id → assignee row. */
    val assignees: HashMap<UUID, HashMap<UUID, AssigneeRecord>> = HashMap(),
    /** Keyed by user id. */
    val pushTopics: HashMap<UUID, PushRecord> = HashMap(),
    val joinAttempts: ArrayList<JoinAttemptRecord> = ArrayList(),
    /** Pending password-recovery codes, keyed by user id. */
    val recoveries: HashMap<UUID, RecoveryRecord> = HashMap(),
) {
    /** A deep copy of the containers (value semantics of the Swift `struct`). */
    fun copy(): BackendData = BackendData(
        accounts = HashMap(accounts),
        profiles = HashMap(profiles),
        groups = HashMap(groups),
        invites = HashMap(invites),
        members = members.mapValuesTo(HashMap()) { HashMap(it.value) },
        tasks = HashMap(tasks),
        assignees = assignees.mapValuesTo(HashMap()) { HashMap(it.value) },
        pushTopics = HashMap(pushTopics),
        joinAttempts = ArrayList(joinAttempts),
        recoveries = HashMap(recoveries),
    )

    // region Queries

    fun account(email: String): AccountRecord? = accounts.values.firstOrNull { it.email == email }

    fun role(userId: UUID, groupId: UUID): MemberRole? = members[groupId]?.get(userId)?.role

    fun isMember(userId: UUID, groupId: UUID): Boolean = members[groupId]?.get(userId) != null

    fun adminCount(groupId: UUID): Int = members[groupId]?.values?.count { it.role == MemberRole.ADMIN } ?: 0

    /** Groups the user belongs to, in a stable order. */
    fun groupIds(userId: UUID): List<UUID> =
        members.filter { it.value[userId] != null }.keys.sortedByUuidString()

    fun taskIds(groupId: UUID): List<UUID> =
        tasks.values.filter { it.groupId == groupId }.map { it.id }.sortedByUuidString()

    fun assigneeIds(taskId: UUID): List<UUID> = (assignees[taskId]?.keys ?: emptySet<UUID>()).sortedByUuidString()

    /** `profiles` SELECT policy: self or co-member. */
    fun canSeeProfile(userId: UUID, viewer: UUID): Boolean =
        viewer == userId || members.values.any { it[viewer] != null && it[userId] != null }

    /** Visibility rule of the `tasks` SELECT policy: members of the task's group. */
    fun visibleTask(taskId: UUID, userId: UUID): TaskRecord? {
        val task = tasks[taskId] ?: return null
        return if (isMember(userId, task.groupId)) task else null
    }

    /** Admin of the task's group, or creator who is still a member (docs/CONTRACTS.md §2). */
    fun canEdit(task: TaskRecord, userId: UUID): Boolean {
        val role = role(userId, task.groupId) ?: return false
        return role == MemberRole.ADMIN || task.createdBy == userId
    }

    /** Editors, plus members assigned to the task. */
    fun canChangeStatus(task: TaskRecord, userId: UUID): Boolean {
        if (!isMember(userId, task.groupId)) return false
        return canEdit(task, userId) || assignees[task.id]?.get(userId) != null
    }

    fun teamGroup(record: GroupRecord): TeamGroup = TeamGroup(
        id = record.id,
        name = record.name,
        createdBy = record.createdBy,
        createdAt = record.createdAt,
        lastActivityAt = record.lastActivityAt,
    )

    fun taskItem(record: TaskRecord): TaskItem = TaskItem(
        id = record.id,
        groupId = record.groupId,
        title = record.title,
        details = record.details,
        status = record.status,
        priority = record.priority,
        dueAt = record.dueAt,
        createdBy = record.createdBy,
        createdAt = record.createdAt,
        updatedAt = record.updatedAt,
        completedAt = record.completedAt,
        assigneeIds = assigneeIds(record.id),
    )

    fun membership(record: MemberRecord): Membership? {
        val profile = profiles[record.userId] ?: return null
        return Membership(
            groupId = record.groupId,
            user = UserProfile(id = profile.id, displayName = profile.displayName),
            role = record.role,
            joinedAt = record.joinedAt,
        )
    }

    fun authUser(userId: UUID): AuthUser? {
        val account = accounts[userId] ?: return null
        return AuthUser(id = account.id, email = account.email)
    }

    // endregion

    // region Generators

    /**
     * Random 8-character code from the invite alphabet, unique among existing invites
     * (mirrors `private.generate_invite_code()`).
     */
    fun newInviteCode(): String {
        val used = invites.values.map { it.code }.toSet()
        while (true) {
            val code = randomString(InviteCode.ALPHABET, InviteCode.length)
            if (code !in used) return code
        }
    }

    /** `equipe-` + 24 random `[a-z0-9]` characters, unique among existing subscriptions. */
    fun newPushTopic(): String {
        val used = pushTopics.values.map { it.topic }.toSet()
        while (true) {
            val topic = InMemoryBackend.pushTopicPrefix + randomString(topicAlphabet, 24)
            if (topic !in used) return topic
        }
    }

    // endregion

    companion object {
        const val topicAlphabet: String = "abcdefghijklmnopqrstuvwxyz0123456789"

        private fun randomString(alphabet: String, length: Int): String {
            val builder = StringBuilder(length)
            repeat(length) { builder.append(alphabet[Random.nextInt(alphabet.length)]) }
            return builder.toString()
        }
    }
}

/** Sorted by `uuidString` (the order used for `TaskItem.assigneeIds`). */
internal fun Iterable<UUID>.sortedByUuidString(): List<UUID> = sortedBy { it.uuidString }
