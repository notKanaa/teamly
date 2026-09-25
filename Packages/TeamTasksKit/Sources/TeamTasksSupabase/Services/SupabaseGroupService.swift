import Foundation
import TeamTasksCore

/// `GroupService` on the group RPCs and PostgREST reads (docs/CONTRACTS.md §2, §4).
struct SupabaseGroupService: GroupService {
    let context: SupabaseContext

    private var rest: RestClient { context.rest }

    /// Most recently active first, ties by `NameOrder` then id (§4.3). A membership with a role unknown to this
    /// client (added by a later migration) is left out (`RestClient.fetchRows`).
    func myGroups() async throws -> [GroupSummary] {
        let rows = try await rest.fetchRows(MyGroupRow.self) { RestQuery.myGroups(me: $0.userId) }
        return NameOrder.sortedGroups(rows.map(\.summary))
    }

    func createGroup(name: String) async throws -> GroupSummary {
        let name = try InputValidation.groupName(name)
        let row = try await rest.fetch(GroupRow.self) { _ in
            RestQuery.rpc("create_group", ["p_name": .string(name)])
        }
        return GroupSummary(group: row.teamGroup, myRole: .admin)
    }

    /// `invalid_code` is returned (not raised) by the server so that the attempt is logged: it becomes
    /// `.invalidCode` here.
    func join(code: InviteCode) async throws -> JoinResult {
        let row = try await rest.fetch(JoinRow.self) { _ in
            RestQuery.rpc("join_group_by_code", ["p_code": .string(code.value)])
        }
        return try row.result()
    }

    func rename(groupId: UUID, name: String) async throws -> TeamGroup {
        let name = try InputValidation.groupName(name)
        let row = try await rest.fetch(GroupRow.self) { _ in
            RestQuery.rpc("rename_group", ["p_group_id": .uuid(groupId), "p_name": .string(name)])
        }
        return row.teamGroup
    }

    func deleteGroup(groupId: UUID) async throws {
        _ = try await rest.send { _ in RestQuery.rpc("delete_group", ["p_group_id": .uuid(groupId)]) }
    }

    /// Admins first, then `NameOrder` on the display name, then id (§4.3). Non-members read an empty list (RLS).
    /// Members with a role unknown to this client are left out.
    func members(groupId: UUID) async throws -> [Membership] {
        let rows = try await rest.fetchRows(MemberRow.self) { _ in RestQuery.members(groupId: groupId) }
        return NameOrder.sortedMembers(rows.map { $0.membership(groupId: groupId) })
    }

    /// `group_invites` is only readable by the group's admins: 0 rows → `.forbidden`.
    func inviteCode(groupId: UUID) async throws -> InviteCode {
        let rows = try await rest.fetch([InviteRow].self) { _ in RestQuery.inviteCode(groupId: groupId) }
        guard let row = rows.first else { throw AppError.forbidden }
        return try Self.inviteCode(row.code)
    }

    func regenerateInviteCode(groupId: UUID) async throws -> InviteCode {
        let code = try await rest.fetch(String.self) { _ in
            RestQuery.rpc("regenerate_invite_code", ["p_group_id": .uuid(groupId)])
        }
        return try Self.inviteCode(code)
    }

    func setRole(groupId: UUID, userId: UUID, role: MemberRole) async throws {
        _ = try await rest.send { _ in
            RestQuery.rpc("set_member_role", [
                "p_group_id": .uuid(groupId), "p_user_id": .uuid(userId), "p_role": .string(role.rawValue),
            ])
        }
    }

    func removeMember(groupId: UUID, userId: UUID) async throws {
        _ = try await rest.send { _ in
            RestQuery.rpc("remove_member", ["p_group_id": .uuid(groupId), "p_user_id": .uuid(userId)])
        }
    }

    func leave(groupId: UUID) async throws {
        _ = try await rest.send { _ in RestQuery.rpc("leave_group", ["p_group_id": .uuid(groupId)]) }
    }

    static func inviteCode(_ stored: String) throws -> InviteCode {
        guard let code = InviteCode(stored), code.value == stored else {
            throw AppError.unknown("code d’invitation inattendu")
        }
        return code
    }

    // TODO(v2-supabase): implement (docs/CONTRACTS-V2.md §5 create_group with appearance).
    func createGroup(name: String, color: ColorKey?, emoji: String?) async throws -> GroupSummary {
        throw AppError.unknown("pas encore disponible")
    }

    // TODO(v2-supabase): implement (docs/CONTRACTS-V2.md §5 set_group_appearance).
    func setAppearance(groupId: UUID, color: ColorKey?, emoji: String?) async throws -> TeamGroup {
        throw AppError.unknown("pas encore disponible")
    }

    // TODO(v2-supabase): implement (docs/CONTRACTS-V2.md §7 activity read).
    func activity(groupId: UUID) async throws -> [ActivityEvent] {
        throw AppError.unknown("pas encore disponible")
    }
}
