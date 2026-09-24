package io.github.notkanaa.equipe.mocks

import io.github.notkanaa.equipe.core.AppError
import io.github.notkanaa.equipe.core.GroupSummary
import io.github.notkanaa.equipe.core.InviteCode
import io.github.notkanaa.equipe.core.JoinResult
import io.github.notkanaa.equipe.core.MemberRole
import io.github.notkanaa.equipe.core.Membership
import io.github.notkanaa.equipe.core.NameOrder
import io.github.notkanaa.equipe.core.TeamGroup
import io.github.notkanaa.equipe.core.UserProfile
import java.util.UUID
import kotlin.time.toJavaDuration

// Profiles, groups, invites, memberships and push topics (docs/CONTRACTS.md §2, §4).

// region Profiles

internal fun InMemoryBackend.myProfile(clientId: UUID): UserProfile = read(clientId) { data, me ->
    val profile = data.profiles[me] ?: throw AppError.NotAuthenticated
    UserProfile(id = profile.id, displayName = profile.displayName)
}

/** `PATCH profiles`. The profile UPDATE also matches the Realtime binding on `profiles` (→ MembershipsChanged). */
internal fun InMemoryBackend.updateDisplayName(clientId: UUID, name: String): UserProfile =
    write(clientId) { transaction, me ->
        val cleaned = InputRules.displayName(name)
        val profile = transaction.data.profiles[me] ?: throw AppError.Forbidden
        transaction.data.profiles[me] = profile.copy(displayName = cleaned, updatedAt = transaction.now)
        transaction.profileUpdated(me)
        UserProfile(id = me, displayName = cleaned)
    }

// endregion

// region Group reads

/** Groups of the caller, most recently active first. */
internal fun InMemoryBackend.myGroups(clientId: UUID): List<GroupSummary> = read(clientId) { data, me ->
    NameOrder.sortedGroups(
        data.groupIds(me).mapNotNull { groupId ->
            val group = data.groups[groupId] ?: return@mapNotNull null
            val role = data.role(me, groupId) ?: return@mapNotNull null
            GroupSummary(group = data.teamGroup(group), myRole = role)
        },
    )
}

/** Members sorted admins first, then by display name. Non-members get an empty list (RLS). */
internal fun InMemoryBackend.members(clientId: UUID, groupId: UUID): List<Membership> = read(clientId) { data, me ->
    if (!data.isMember(me, groupId)) return@read emptyList()
    NameOrder.sortedMembers(data.members[groupId]?.values.orEmpty().mapNotNull { data.membership(it) })
}

/** `group_invites` is readable by admins only: 0 rows → [AppError.Forbidden]. */
internal fun InMemoryBackend.inviteCode(clientId: UUID, groupId: UUID): InviteCode = read(clientId) { data, me ->
    val invite = data.invites[groupId]
    if (data.role(me, groupId) != MemberRole.ADMIN || invite == null) throw AppError.Forbidden
    storedInviteCode(invite.code)
}

// endregion

// region Group RPCs

/** `create_group`: group + caller as admin + invite code. */
internal fun InMemoryBackend.createGroup(clientId: UUID, name: String): GroupSummary =
    write(clientId) { transaction, me ->
        val cleaned = InputRules.groupName(name)
        val group = GroupRecord(
            id = UUID.randomUUID(), name = cleaned, createdBy = me,
            createdAt = transaction.now, lastActivityAt = transaction.now,
        )
        transaction.data.groups[group.id] = group
        transaction.data.invites[group.id] = InviteRecord(
            groupId = group.id, code = transaction.data.newInviteCode(), createdBy = me, createdAt = transaction.now,
        )
        transaction.insertMembership(group.id, me, MemberRole.ADMIN)
        GroupSummary(group = transaction.data.teamGroup(group), myRole = MemberRole.ADMIN)
    }

private sealed interface JoinOutcome {
    data class Joined(val result: JoinResult) : JoinOutcome

    data object InvalidCode : JoinOutcome
}

/**
 * `join_group_by_code`. An invalid code is logged (and committed) before [AppError.InvalidCode] is thrown.
 * Failures count while `attempted_at >= now() - 1 hour` (an attempt exactly one hour old still counts).
 */
internal fun InMemoryBackend.join(clientId: UUID, code: InviteCode): JoinResult {
    val outcome = write(clientId) { transaction, me ->
        val windowStart = transaction.now.minus(InMemoryBackend.joinRateLimitWindow.toJavaDuration())
        val failures = transaction.data.joinAttempts.count {
            it.userId == me && !it.succeeded && it.attemptedAt >= windowStart
        }
        if (failures >= InMemoryBackend.maxFailedJoinsPerHour) throw AppError.RateLimited

        val normalized = InviteCode.normalize(code.value)
        val invite = transaction.data.invites.values.firstOrNull { it.code == normalized }
        val group = invite?.let { transaction.data.groups[it.groupId] }
        if (group == null) {
            transaction.data.joinAttempts.add(JoinAttemptRecord(me, transaction.now, succeeded = false))
            return@write JoinOutcome.InvalidCode
        }
        transaction.data.joinAttempts.add(JoinAttemptRecord(me, transaction.now, succeeded = true))
        if (transaction.data.isMember(me, group.id)) {
            return@write JoinOutcome.Joined(JoinResult(group.id, group.name, alreadyMember = true))
        }
        transaction.insertMembership(group.id, me, MemberRole.MEMBER)
        JoinOutcome.Joined(JoinResult(group.id, group.name, alreadyMember = false))
    }
    return when (outcome) {
        is JoinOutcome.Joined -> outcome.result
        JoinOutcome.InvalidCode -> throw AppError.InvalidCode
    }
}

/** `regenerate_invite_code`: admin only; the previous code stops working. */
internal fun InMemoryBackend.regenerateInviteCode(clientId: UUID, groupId: UUID): InviteCode =
    write(clientId) { transaction, me ->
        if (transaction.data.role(me, groupId) != MemberRole.ADMIN || transaction.data.groups[groupId] == null) {
            throw AppError.Forbidden
        }
        val code = transaction.data.newInviteCode()
        transaction.data.invites[groupId] =
            InviteRecord(groupId = groupId, code = code, createdBy = me, createdAt = transaction.now)
        storedInviteCode(code)
    }

/** `rename_group`: `group_not_found` for an unknown group, then admin only, then name validation. */
internal fun InMemoryBackend.rename(clientId: UUID, groupId: UUID, name: String): TeamGroup =
    write(clientId) { transaction, me ->
        val stored = transaction.data.groups[groupId] ?: throw AppError.NotFound
        if (transaction.data.role(me, groupId) != MemberRole.ADMIN) throw AppError.Forbidden
        val cleaned = InputRules.groupName(name)
        val renamed = stored.copy(name = cleaned, lastActivityAt = transaction.now)
        transaction.data.groups[groupId] = renamed
        transaction.bump(groupId)
        transaction.data.teamGroup(renamed)
    }

/** `delete_group`: admin only; cascades. */
internal fun InMemoryBackend.deleteGroup(clientId: UUID, groupId: UUID) {
    write(clientId) { transaction, me ->
        if (transaction.data.groups[groupId] == null) throw AppError.NotFound
        if (transaction.data.role(me, groupId) != MemberRole.ADMIN) throw AppError.Forbidden
        transaction.deleteGroup(groupId)
    }
}

/**
 * `set_member_role`: admin only; the target must be a member; the last admin cannot be demoted.
 * Like SQL, an unchanged role returns before any write: no bump, no Realtime signal.
 */
internal fun InMemoryBackend.setRole(clientId: UUID, groupId: UUID, userId: UUID, role: MemberRole) {
    write(clientId) { transaction, me ->
        if (transaction.data.role(me, groupId) != MemberRole.ADMIN) throw AppError.Forbidden
        val current = transaction.data.role(userId, groupId) ?: throw AppError.NotMember
        if (current == role) return@write
        if (current == MemberRole.ADMIN && role == MemberRole.MEMBER && transaction.data.adminCount(groupId) == 1) {
            throw AppError.LastAdmin
        }
        transaction.updateRole(groupId, userId, role)
    }
}

/** `remove_member`: admin only, not self, target must be a member. Admins can remove other admins. */
internal fun InMemoryBackend.removeMember(clientId: UUID, groupId: UUID, userId: UUID) {
    write(clientId) { transaction, me ->
        if (transaction.data.role(me, groupId) != MemberRole.ADMIN) throw AppError.Forbidden
        if (userId == me) throw AppError.CannotRemoveSelf
        if (!transaction.data.isMember(userId, groupId)) throw AppError.NotMember
        transaction.deleteMembership(groupId, userId)
    }
}

/** `leave_group`: the only admin cannot leave while other members remain; the last member deletes the group. */
internal fun InMemoryBackend.leave(clientId: UUID, groupId: UUID) {
    write(clientId) { transaction, me ->
        val role = transaction.data.role(me, groupId) ?: throw AppError.NotMember
        val memberCount = transaction.data.members[groupId]?.size ?: 0
        if (memberCount == 1) {
            transaction.deleteGroup(groupId)
            return@write
        }
        if (role == MemberRole.ADMIN && transaction.data.adminCount(groupId) == 1) throw AppError.LastAdmin
        transaction.deleteMembership(groupId, me)
    }
}

// endregion

// region Push (ntfy topic)

internal fun InMemoryBackend.currentPushTopic(clientId: UUID): String? =
    read(clientId) { data, me -> data.pushTopics[me]?.topic }

/** `enable_push`: returns the existing topic or creates a random one. */
internal fun InMemoryBackend.enablePush(clientId: UUID): String = write(clientId) { transaction, me ->
    transaction.data.pushTopics[me]?.let { return@write it.topic }
    val topic = transaction.data.newPushTopic()
    transaction.data.pushTopics[me] = PushRecord(userId = me, topic = topic, createdAt = transaction.now)
    topic
}

internal fun InMemoryBackend.disablePush(clientId: UUID) {
    write(clientId) { transaction, me -> transaction.data.pushTopics.remove(me) }
}

// endregion

/** The [InviteCode] of a stored code (always valid: generated from the invite alphabet). */
internal fun storedInviteCode(stored: String): InviteCode =
    InviteCode.parse(stored) ?: throw AppError.Unknown("code d’invitation corrompu")
