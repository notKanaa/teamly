import Foundation
import TeamTasksCore

/// `GroupService` on the group RPCs and PostgREST reads (docs/CONTRACTS.md §2, §4; docs/CONTRACTS-V2.md §5, §7, §10).
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
    /// Members with a role unknown to this client are left out. v2: with their avatar color and emoji.
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

    /// v2 `create_group` with the appearance (docs/CONTRACTS-V2.md §5). Checked in the server's order before the call:
    /// the name, then the emoji (a typed color is always valid), normalized (nil or blank = no emoji); the server then
    /// applies its write quota.
    func createGroup(name: String, color: ColorKey?, emoji: String?) async throws -> GroupSummary {
        let name = try InputValidation.groupName(name)
        let emoji = try InputValidation.emoji(emoji)
        let row = try await rest.fetch(GroupRow.self) { _ in
            RestQuery.rpc("create_group", [
                "p_name": .string(name),
                "p_color": .optionalString(color?.rawValue),
                "p_emoji": .optionalString(emoji),
            ])
        }
        return GroupSummary(group: row.teamGroup, myRole: .admin)
    }

    /// v2 `set_group_appearance` (admins only; both values are sent, nil = automatic color / no emoji). The emoji is sent
    /// as typed (`ServerChecked`): the server checks it after the group and the caller's rights (docs/CONTRACTS-V2.md
    /// §3: `group_not_found` → `forbidden` → `invalid_emoji`), then stores it normalized (a blank one as no emoji).
    func setAppearance(groupId: UUID, color: ColorKey?, emoji: String?) async throws -> TeamGroup {
        let emoji = ServerChecked.emoji(emoji)
        let row = try await rest.fetch(GroupRow.self) { _ in
            RestQuery.rpc("set_group_appearance", [
                "p_group_id": .uuid(groupId),
                "p_color": .optionalString(color?.rawValue),
                "p_emoji": .optionalString(emoji),
            ])
        }
        return row.teamGroup
    }

    /// v2: newest first, at most `Limits.activityFeedMax` events (docs/CONTRACTS-V2.md §7). Events of a kind unknown to
    /// this client (added by a later version) are left out (`RestClient.fetchRows`); non-members read an empty list.
    func activity(groupId: UUID) async throws -> [ActivityEvent] {
        let rows = try await rest.fetchRows(ActivityRow.self) { _ in RestQuery.activity(groupId: groupId) }
        return rows.map(\.event).sorted { $0.id > $1.id }
    }

    // MARK: - Groups overview (docs/CONTRACTS-V2.md §10)

    /// Pages read at most per overview read (each page holds `Limits.readRowsMax` rows): the groups left after them
    /// have no overview.
    static let overviewMaxPages = 5

    /// Two reads for all the groups at once, sent together and aggregated here (`GroupOverview.init(groupId:members:
    /// tasks:doneSince:)`): the members (`RestQuery.overviewMembers`) and the tasks not done or done since `doneSince`
    /// (`RestQuery.overviewTasks`). RLS keeps the rows of the caller's groups: a group of another user, or an unknown
    /// one, reads no member and is left out. Members with a role, and tasks with a status, unknown to this client are
    /// left out. A group whose rows could not all be read (`pagedByGroup`) is left out.
    func overviews(groupIds: [UUID], doneSince: Date) async throws -> [GroupOverview] {
        try await overviews(groupIds: groupIds, doneSince: doneSince, pageSize: Limits.readRowsMax)
    }

    /// `overviews(groupIds:doneSince:)` in pages of `pageSize` rows: `Limits.readRowsMax`, the server's `max_rows`;
    /// smaller in the integration tests, which read the real server in several pages.
    func overviews(groupIds: [UUID], doneSince: Date, pageSize: Int) async throws -> [GroupOverview] {
        var seen = Set<UUID>()
        let requested = groupIds.filter { seen.insert($0).inserted }
        guard !requested.isEmpty else { return [] }
        let sorted = requested.sorted(by: Self.postgresOrder)
        async let memberPages = pagedByGroup(sorted, MemberRow.self, pageSize: pageSize, groupId: { $0.groupId }) { ids in
            RestQuery.overviewMembers(groupIds: ids, limit: pageSize)
        }
        async let taskPages = pagedByGroup(sorted, OverviewTaskRow.self, pageSize: pageSize, groupId: { $0.groupId }) { ids in
            RestQuery.overviewTasks(groupIds: ids, doneSince: doneSince, limit: pageSize)
        }
        let (members, tasks) = try await (memberPages, taskPages)
        return requested.compactMap { groupId in
            guard let memberRows = members[groupId], !memberRows.isEmpty, let taskRows = tasks[groupId] else { return nil }
            return GroupOverview(
                groupId: groupId,
                members: memberRows.map { $0.membership(groupId: groupId) },
                tasks: taskRows.map(\.state),
                doneSince: doneSince
            )
        }
    }

    /// The rows of a read over `groupIds` (sorted with `postgresOrder`), by group, for the groups read completely.
    ///
    /// PostgREST returns at most `max_rows` rows without any error (docs/CONTRACTS.md §5 pitfall 6), so each request
    /// asks for a page of `pageSize` rows ordered by `group_id`. A page with fewer rows holds every row of the groups
    /// asked. A full page may miss rows of its last group only: the groups before it are complete, and the next page
    /// asks for that group and the ones after it. A group filling a page on its own is left out (it has more rows than
    /// one page), and so are the groups not read after `overviewMaxPages` pages. The page size is counted on the raw
    /// rows (`GroupKeyRow`): rows left out for an unknown enum value still count.
    private func pagedByGroup<Row: Decodable & Sendable>(
        _ groupIds: [UUID],
        _ type: Row.Type,
        pageSize: Int,
        groupId: @escaping @Sendable (Row) -> UUID?,
        request: @escaping @Sendable ([UUID]) -> RestRequest
    ) async throws -> [UUID: [Row]] {
        var remaining = groupIds
        var complete: [UUID: [Row]] = [:]
        var pages = 0
        while !remaining.isEmpty, pages < Self.overviewMaxPages {
            pages += 1
            let asked = remaining
            let data = try await rest.send { _ in request(asked) }
            let keys = try RestDecoding.decode([GroupKeyRow].self, from: data).map(\.groupId)
            var byGroup: [UUID: [Row]] = [:]
            for row in try RestDecoding.decode(LossyRows<Row>.self, from: data).rows {
                if let id = groupId(row) { byGroup[id, default: []].append(row) }
            }
            guard keys.count >= pageSize, let last = keys.last else {
                for id in asked { complete[id] = byGroup[id] ?? [] }
                return complete
            }
            let before = asked.filter { Self.postgresOrder($0, last) }
            for id in before { complete[id] = byGroup[id] ?? [] }
            // The last group again, unless it filled the page on its own: then it is left out.
            remaining = before.isEmpty
                ? asked.filter { Self.postgresOrder(last, $0) }
                : asked.filter { !Self.postgresOrder($0, last) }
        }
        return complete
    }

    /// The order of Postgres on `uuid` values (their bytes), which the uppercase `uuidString` order follows.
    static func postgresOrder(_ lhs: UUID, _ rhs: UUID) -> Bool {
        lhs.uuidString < rhs.uuidString
    }
}
