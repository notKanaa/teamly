package io.github.notkanaa.equipe.supabase

import io.github.notkanaa.equipe.core.AppError
import io.github.notkanaa.equipe.core.GroupService
import io.github.notkanaa.equipe.core.GroupSummary
import io.github.notkanaa.equipe.core.InputValidation
import io.github.notkanaa.equipe.core.InviteCode
import io.github.notkanaa.equipe.core.JoinResult
import io.github.notkanaa.equipe.core.MemberRole
import io.github.notkanaa.equipe.core.Membership
import io.github.notkanaa.equipe.core.NameOrder
import io.github.notkanaa.equipe.core.TeamGroup
import kotlinx.serialization.json.JsonElement
import java.util.UUID

/** [GroupService] on the group RPCs and PostgREST reads (docs/CONTRACTS.md §2, §4). Port of SupabaseGroupService.swift. */
internal class SupabaseGroupService(private val context: SupabaseContext) : GroupService {
    private val rest get() = context.rest

    /**
     * Most recently active first, ties by [NameOrder] then id (§4.3). A membership with a role unknown to this client
     * (added by a later migration) is left out ([RestClient.fetchRows]).
     */
    override suspend fun myGroups(): List<GroupSummary> {
        val rows = rest.fetchRows(MyGroupRow::decode) { RestQuery.myGroups(it.userId) }
        return NameOrder.sortedGroups(rows.map { it.summary })
    }

    override suspend fun createGroup(name: String): GroupSummary {
        val validName = InputValidation.groupName(name)
        val row = rest.fetch(::groupRow) { RestQuery.rpc("create_group", mapOf("p_name" to JsonValues.string(validName))) }
        return GroupSummary(row.teamGroup, MemberRole.ADMIN)
    }

    /** `invalid_code` is returned (not raised) by the server so that the attempt is logged: it becomes `InvalidCode`. */
    override suspend fun join(code: InviteCode): JoinResult {
        val row = rest.fetch({ JoinRow.decode(it.asObject("join result")) }) {
            RestQuery.rpc("join_group_by_code", mapOf("p_code" to JsonValues.string(code.value)))
        }
        return row.result()
    }

    override suspend fun rename(groupId: UUID, name: String): TeamGroup {
        val validName = InputValidation.groupName(name)
        val row = rest.fetch(::groupRow) {
            RestQuery.rpc("rename_group", mapOf("p_group_id" to JsonValues.uuid(groupId), "p_name" to JsonValues.string(validName)))
        }
        return row.teamGroup
    }

    override suspend fun deleteGroup(groupId: UUID) {
        rest.send { RestQuery.rpc("delete_group", mapOf("p_group_id" to JsonValues.uuid(groupId))) }
    }

    /**
     * Admins first, then [NameOrder] on the display name, then id (§4.3). Non-members read an empty list (RLS). Members
     * with a role unknown to this client are left out.
     */
    override suspend fun members(groupId: UUID): List<Membership> {
        val rows = rest.fetchRows(MemberRow::decode) { RestQuery.members(groupId) }
        return NameOrder.sortedMembers(rows.map { it.membership(groupId) })
    }

    /** `group_invites` is only readable by the group's admins: 0 rows → [AppError.Forbidden]. */
    override suspend fun inviteCode(groupId: UUID): InviteCode {
        val rows = rest.fetchAll(InviteRow::decode) { RestQuery.inviteCode(groupId) }
        val row = rows.firstOrNull() ?: throw AppError.Forbidden
        return inviteCode(row.code)
    }

    override suspend fun regenerateInviteCode(groupId: UUID): InviteCode {
        val code = rest.fetch({ it.stringValue() ?: throw MalformedAnswer("expected a string") }) {
            RestQuery.rpc("regenerate_invite_code", mapOf("p_group_id" to JsonValues.uuid(groupId)))
        }
        return inviteCode(code)
    }

    override suspend fun setRole(groupId: UUID, userId: UUID, role: MemberRole) {
        rest.send {
            RestQuery.rpc(
                "set_member_role",
                mapOf(
                    "p_group_id" to JsonValues.uuid(groupId),
                    "p_user_id" to JsonValues.uuid(userId),
                    "p_role" to JsonValues.string(role.rawValue),
                ),
            )
        }
    }

    override suspend fun removeMember(groupId: UUID, userId: UUID) {
        rest.send {
            RestQuery.rpc("remove_member", mapOf("p_group_id" to JsonValues.uuid(groupId), "p_user_id" to JsonValues.uuid(userId)))
        }
    }

    override suspend fun leave(groupId: UUID) {
        rest.send { RestQuery.rpc("leave_group", mapOf("p_group_id" to JsonValues.uuid(groupId))) }
    }

    private fun groupRow(element: JsonElement): GroupRow = GroupRow.decode(element.asObject("group"))

    companion object {
        /** A code as stored by the server: it must already be in normalized form. */
        fun inviteCode(stored: String): InviteCode {
            val code = InviteCode.parse(stored)
            if (code == null || code.value != stored) throw AppError.Unknown("code d’invitation inattendu")
            return code
        }
    }
}
