package io.github.notkanaa.equipe.core.viewmodel

import io.github.notkanaa.equipe.core.AppError
import io.github.notkanaa.equipe.core.GroupPermissions
import io.github.notkanaa.equipe.core.InviteCode
import io.github.notkanaa.equipe.core.MemberRole
import io.github.notkanaa.equipe.core.Membership
import io.github.notkanaa.equipe.core.NameOrder
import io.github.notkanaa.equipe.core.TeamGroup
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.async
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.collectLatest
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.distinctUntilChanged
import java.util.UUID
import kotlin.coroutines.cancellation.CancellationException

// Port of TeamTasksCore/ViewModels/Groups/MembersViewModel.swift.

/** State of the « Membres » screen. */
data class MembersState(
    val groupId: UUID,
    /** The signed-in user. */
    val currentUserId: UUID,
    val group: TeamGroup? = null,
    /** Admins first, then by name. */
    val members: List<Membership> = emptyList(),
    val myRole: MemberRole? = null,
    /** Admins only (null otherwise). */
    val inviteCode: InviteCode? = null,
    val loadState: LoadState = LoadState.Idle,
    /** The user left, was removed, or the group was deleted: leave the group's screens. */
    val isGone: Boolean = false,
    /** Set by a successful `leave()`. */
    val didLeave: Boolean = false,
    /** Members with a role change or a removal in progress. */
    val busyMemberIds: Set<UUID> = emptySet(),
    val isRegeneratingCode: Boolean = false,
    val isLeaving: Boolean = false,
    override val error: ErrorState? = null,
) : ErrorHolder {
    /** « Membres ». */
    val title: String get() = "Membres"

    val groupName: String get() = group?.name ?: "Groupe"

    val isAdmin: Boolean get() = myRole == MemberRole.ADMIN

    val canManageMembers: Boolean get() = GroupPermissions.canManageMembers(myRole)

    val canSeeInviteCode: Boolean get() = GroupPermissions.canSeeInviteCode(myRole)

    val adminCount: Int get() = members.count { it.role == MemberRole.ADMIN }

    /** `ABCD-EFGH` (admins). */
    val inviteCodeText: String? get() = inviteCode?.formatted

    /** Text shared with the share sheet: « Rejoins mon groupe « X » sur Équipe avec le code ABCD-EFGH ». */
    val shareText: String?
        get() {
            val code = inviteCode ?: return null
            val group = group ?: return null
            return MembersViewModel.shareText(group.name, code)
        }

    fun isMe(member: Membership): Boolean = member.user.id == currentUserId

    /** Name for the list: « Camille Martin (vous) » for the current user. */
    fun displayName(member: Membership): String =
        if (isMe(member)) "${member.user.displayName} (vous)" else member.user.displayName

    /** Admins can change anyone's role; their own only while another admin exists (last-admin rule). */
    fun canChangeRole(member: Membership): Boolean {
        if (!canManageMembers) return false
        return !isMe(member) || member.role != MemberRole.ADMIN || adminCount > 1
    }

    /** Admins can remove anyone but themselves (they use « Quitter le groupe »). */
    fun canRemove(member: Membership): Boolean = canManageMembers && !isMe(member)

    /** « Nommer admin » / « Retirer le rôle d’admin ». */
    fun roleActionTitle(member: Membership): String =
        if (member.role == MemberRole.ADMIN) "Retirer le rôle d’admin" else "Nommer admin"

    /** The only member: leaving deletes the group. */
    val isLastMember: Boolean get() = members.size == 1 && members.first().user.id == currentUserId

    /** The only admin while other members remain: leaving is refused until someone else is admin. */
    val isLastAdmin: Boolean get() = myRole == MemberRole.ADMIN && adminCount == 1 && members.size > 1

    val canLeave: Boolean get() = myRole != null && !isLastAdmin && !isLeaving

    /** Text of the « Quitter le groupe » confirmation (or why it is impossible). */
    val leaveConfirmationMessage: String
        get() = when {
            isLastMember ->
                "Vous êtes le dernier membre : le groupe « $groupName » et toutes ses tâches seront supprimés."
            isLastAdmin -> AppError.LastAdmin.messageFR
            else ->
                "Vous ne verrez plus « $groupName » ni ses tâches. Vos assignations dans ce groupe seront retirées."
        }
}

/**
 * « Membres » screen: members (admins first, then by name), the invite code for admins (regenerate, share), role
 * changes, removal, and « Quitter le groupe ».
 *
 * Reloads when the group's revision (or the memberships revision) changes. Screen:
 * `LaunchedEffect(model) { model.autoRefresh() }`; leave the group's screens when [MembersState.isGone] becomes true
 * (`router.removeRoutesForGroup(groupId)`).
 */
class MembersViewModel(
    val session: SessionModel,
    val groupId: UUID,
    scope: CoroutineScope,
) : ScreenModel<MembersState>(
    MembersState(groupId = groupId, currentUserId = session.userId),
    { state, error -> state.copy(error = error) },
) {
    private val runner = LoadRunner(scope)
    private var loadedRevision: Int? = null
    private var fetchingRevision: Int? = null

    // region Loading

    val refreshKey: RefreshKey
        get() = RefreshKey(session.feed.groupRevision(groupId) + session.feed.membershipsRevision.value)

    /** [refreshKey] as a flow: the current value first, then every change. */
    val refreshKeys: Flow<RefreshKey> = combine(
        session.feed.groupRevisionFlow(groupId),
        session.feed.membershipsRevision,
    ) { group, memberships -> RefreshKey(group + memberships) }.distinctUntilChanged()

    val needsRefresh: Boolean
        get() = current.loadState != LoadState.Loaded || loadedRevision != refreshKey.revision

    /** Loads if never loaded or out of date (no-op once gone). */
    suspend fun load() {
        if (!needsRefresh || current.isGone) return
        val upToDate = runner.isRunning && fetchingRevision == refreshKey.revision
        runner.run(rerunIfRunning = !upToDate) { fetch() }
    }

    /** Always fetches again; no-op once gone. */
    suspend fun reload() {
        if (current.isGone) return
        runner.run(rerunIfRunning = true) { fetch() }
    }

    /** Loads now, then again whenever [refreshKey] changes. Never returns: run it in a `LaunchedEffect`. */
    suspend fun autoRefresh() {
        refreshKeys.collectLatest { load() }
    }

    private suspend fun fetch() {
        if (current.isGone) return
        val revision = refreshKey.revision
        fetchingRevision = revision
        try {
            update { it.copy(loadState = startedLoad(it.loadState)) }
            val groupService = session.services.groups
            val (groups, members) = coroutineScope {
                val groupsRequest = async { groupService.myGroups() }
                val membersRequest = async { groupService.members(groupId) }
                groupsRequest.await() to membersRequest.await()
            }
            val summary = groups.firstOrNull { it.id == groupId }
            if (summary == null) {
                markGone()
                return
            }
            val code = if (GroupPermissions.canSeeInviteCode(summary.myRole)) groupService.inviteCode(groupId) else null
            loadedRevision = revision
            update {
                it.copy(
                    group = summary.group,
                    myRole = summary.myRole,
                    members = NameOrder.sortedMembers(members),
                    inviteCode = code,
                    loadState = LoadState.Loaded,
                )
            }
        } catch (error: CancellationException) {
            update { it.copy(loadState = cancelledLoad(it.loadState)) }
            throw error
        } catch (error: Exception) {
            update {
                val failure = loadFailure(it.loadState, it.error, error)
                it.copy(loadState = failure.loadState, error = failure.error)
            }
        } finally {
            fetchingRevision = null
        }
    }

    private fun markGone() {
        update { it.copy(isGone = true, loadState = LoadState.Loaded) }
    }

    // endregion

    // region Actions

    /** Admins: invalidates the current code and shows the new one. */
    suspend fun regenerateInviteCode(): Boolean {
        if (!current.canSeeInviteCode) {
            present(AppError.Forbidden)
            return false
        }
        if (current.isRegeneratingCode) return false
        update { it.copy(error = null, isRegeneratingCode = true) }
        try {
            val code = session.services.groups.regenerateInviteCode(groupId)
            update { it.copy(inviteCode = code) }
            return true
        } catch (error: CancellationException) {
            throw error
        } catch (error: Exception) {
            present(error)
            return false
        } finally {
            update { it.copy(isRegeneratingCode = false) }
        }
    }

    /** Admins: gives or removes the admin role. */
    suspend fun setRole(role: MemberRole, member: Membership): Boolean {
        if (!current.canManageMembers) {
            present(AppError.Forbidden)
            return false
        }
        if (member.id in current.busyMemberIds) return false
        update { it.copy(error = null, busyMemberIds = it.busyMemberIds + member.id) }
        try {
            session.services.groups.setRole(groupId, member.user.id, role)
            update { state ->
                val members = if (state.members.any { it.id == member.id }) {
                    NameOrder.sortedMembers(state.members.map { if (it.id == member.id) it.copy(role = role) else it })
                } else {
                    state.members
                }
                if (state.isMe(member)) {
                    state.copy(
                        members = members,
                        myRole = role,
                        inviteCode = if (role != MemberRole.ADMIN) null else state.inviteCode,
                    )
                } else {
                    state.copy(members = members)
                }
            }
            session.feed.bump(groupId)
            session.feed.bumpMemberships()
            return true
        } catch (error: CancellationException) {
            throw error
        } catch (error: Exception) {
            present(error)
            return false
        } finally {
            update { it.copy(busyMemberIds = it.busyMemberIds - member.id) }
        }
    }

    /** Admins: switches between admin and member. */
    suspend fun toggleRole(member: Membership): Boolean =
        setRole(if (member.role == MemberRole.ADMIN) MemberRole.MEMBER else MemberRole.ADMIN, member)

    /** Admins: removes a member (their assignments in the group are removed too). */
    suspend fun remove(member: Membership): Boolean {
        if (!current.canRemove(member)) {
            present(if (current.isMe(member)) AppError.CannotRemoveSelf else AppError.Forbidden)
            return false
        }
        if (member.id in current.busyMemberIds) return false
        update { it.copy(error = null, busyMemberIds = it.busyMemberIds + member.id) }
        try {
            session.services.groups.removeMember(groupId, member.user.id)
            update { state -> state.copy(members = state.members.filter { it.id != member.id }) }
            session.feed.bump(groupId)
            return true
        } catch (error: CancellationException) {
            throw error
        } catch (error: Exception) {
            if (present(error) == AppError.NotMember) {
                update { state -> state.copy(members = state.members.filter { it.id != member.id }) }
            }
            return false
        } finally {
            update { it.copy(busyMemberIds = it.busyMemberIds - member.id) }
        }
    }

    /** Leaves the group (the last member deletes it). The last admin gets the `LastAdmin` error. */
    suspend fun leave(): Boolean {
        if (current.isLeaving) return false
        update { it.copy(error = null, isLeaving = true) }
        try {
            session.services.groups.leave(groupId)
            update { it.copy(didLeave = true, isGone = true) }
            session.feed.bumpMemberships()
            session.feed.bumpMyTasks()
            session.feed.bump(groupId)
            return true
        } catch (error: CancellationException) {
            throw error
        } catch (error: Exception) {
            if (present(error) == AppError.NotMember) markGone()
            return false
        } finally {
            update { it.copy(isLeaving = false) }
        }
    }

    // endregion

    companion object {
        const val GONE_MESSAGE: String = GroupDetailViewModel.GONE_MESSAGE

        /** « Rejoins mon groupe « X » sur Équipe avec le code ABCD-EFGH ». */
        fun shareText(groupName: String, code: InviteCode): String =
            "Rejoins mon groupe « $groupName » sur Équipe avec le code ${code.formatted}"
    }
}
