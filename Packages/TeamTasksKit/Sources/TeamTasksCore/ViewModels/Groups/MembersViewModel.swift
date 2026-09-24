import Foundation
import Observation

/// « Membres » screen: members (admins first, then by name), the invite code for admins (regenerate, share),
/// role changes, removal, and « Quitter le groupe ».
///
/// Reloads when the group's revision changes. View: `.task(id: model.refreshKey) { await model.load() }`;
/// leave the group's screens when `isGone` becomes true (`router.removeRoutes(forGroup:)`).
@MainActor
@Observable
public final class MembersViewModel: ErrorPresenting {
    public static let goneMessage = GroupDetailViewModel.goneMessage

    public let groupId: UUID
    public private(set) var group: TeamGroup?
    public private(set) var members: [Membership] = []
    public private(set) var myRole: MemberRole?
    /// Admins only (nil otherwise).
    public private(set) var inviteCode: InviteCode?
    public private(set) var loadState: LoadState = .idle
    /// The user left, was removed, or the group was deleted: leave the group's screens.
    public private(set) var isGone = false
    /// Set by a successful `leave()`.
    public private(set) var didLeave = false
    /// Members with a role change or a removal in progress.
    public private(set) var busyMemberIds: Set<UUID> = []
    public private(set) var isRegeneratingCode = false
    public private(set) var isLeaving = false
    public var error: ErrorState?

    public let session: SessionModel
    private let runner = LoadRunner()
    private var loadedRevision: Int?
    private var fetchingRevision: Int?

    public init(session: SessionModel, groupId: UUID) {
        self.session = session
        self.groupId = groupId
    }

    // MARK: - Loading

    public var refreshKey: RefreshKey {
        RefreshKey(revision: session.feed.groupRevision(groupId) &+ session.feed.membershipsRevision)
    }

    public var needsRefresh: Bool { loadState != .loaded || loadedRevision != refreshKey.revision }

    public func load() async {
        guard needsRefresh, !isGone else { return }
        let upToDate = runner.isRunning && fetchingRevision == refreshKey.revision
        await runner.run(rerunIfRunning: !upToDate) { [weak self] in await self?.fetch() }
    }

    public func reload() async {
        guard !isGone else { return }
        await runner.run(rerunIfRunning: true) { [weak self] in await self?.fetch() }
    }

    private func fetch() async {
        guard !isGone else { return }
        let revision = refreshKey.revision
        fetchingRevision = revision
        defer { fetchingRevision = nil }
        if loadState != .loaded { loadState = .loading }
        let groupService = session.services.groups
        let groupId = groupId
        do {
            async let groupsRequest = groupService.myGroups()
            async let membersRequest = groupService.members(groupId: groupId)
            let (groups, members) = try await (groupsRequest, membersRequest)
            guard let summary = groups.first(where: { $0.id == groupId }) else {
                markGone()
                return
            }
            var code: InviteCode?
            if GroupPermissions.canSeeInviteCode(role: summary.myRole) {
                code = try await groupService.inviteCode(groupId: groupId)
            }
            group = summary.group
            myRole = summary.myRole
            self.members = NameOrder.sortedMembers(members)
            inviteCode = code
            loadedRevision = revision
            loadState = .loaded
        } catch {
            handleLoadFailure(error)
        }
    }

    private func markGone() {
        isGone = true
        if loadState != .loaded { loadState = .loaded }
    }

    private func handleLoadFailure(_ error: any Error) {
        guard let state = ErrorState(from: error) else {
            if loadState == .loading { loadState = .idle }
            return
        }
        if loadState == .loaded {
            self.error = state
        } else {
            loadState = .failed(state.message)
        }
    }

    // MARK: - Display

    public var title: String { "Membres" }
    public var groupName: String { group?.name ?? "Groupe" }
    public var isAdmin: Bool { myRole == .admin }
    public var canManageMembers: Bool { GroupPermissions.canManageMembers(role: myRole) }
    public var canSeeInviteCode: Bool { GroupPermissions.canSeeInviteCode(role: myRole) }
    public var adminCount: Int { members.filter { $0.role == .admin }.count }

    /// `ABCD-EFGH` (admins).
    public var inviteCodeText: String? { inviteCode?.formatted }

    /// Text shared with `ShareLink`: « Rejoins mon groupe « X » sur Équipe avec le code ABCD-EFGH ».
    public var shareText: String? {
        guard let inviteCode, let group else { return nil }
        return Self.shareText(groupName: group.name, code: inviteCode)
    }

    public static func shareText(groupName: String, code: InviteCode) -> String {
        "Rejoins mon groupe «\u{00A0}\(groupName)\u{00A0}» sur Équipe avec le code \(code.formatted)"
    }

    public func isMe(_ member: Membership) -> Bool { member.user.id == session.userId }

    /// Name for the list: « Camille Martin (vous) » for the current user.
    public func displayName(of member: Membership) -> String {
        isMe(member) ? "\(member.user.displayName) (vous)" : member.user.displayName
    }

    /// Admins can change anyone's role; their own only while another admin exists (last-admin rule).
    public func canChangeRole(of member: Membership) -> Bool {
        guard canManageMembers else { return false }
        return !isMe(member) || member.role != .admin || adminCount > 1
    }

    /// Admins can remove anyone but themselves (they use « Quitter le groupe »).
    public func canRemove(_ member: Membership) -> Bool {
        canManageMembers && !isMe(member)
    }

    /// « Nommer admin » / « Retirer le rôle d'admin ».
    public func roleActionTitle(for member: Membership) -> String {
        member.role == .admin ? "Retirer le rôle d’admin" : "Nommer admin"
    }

    /// The only member: leaving deletes the group.
    public var isLastMember: Bool { members.count == 1 && members.first?.user.id == session.userId }

    /// The only admin while other members remain: leaving is refused until someone else is admin.
    public var isLastAdmin: Bool { myRole == .admin && adminCount == 1 && members.count > 1 }

    public var canLeave: Bool { myRole != nil && !isLastAdmin && !isLeaving }

    /// Text of the « Quitter le groupe » confirmation (or why it is impossible).
    public var leaveConfirmationMessage: String {
        if isLastMember {
            return "Vous êtes le dernier membre\u{00A0}: le groupe «\u{00A0}\(groupName)\u{00A0}» et toutes ses tâches seront supprimés."
        }
        if isLastAdmin {
            return AppError.lastAdmin.messageFR
        }
        return "Vous ne verrez plus «\u{00A0}\(groupName)\u{00A0}» ni ses tâches. Vos assignations dans ce groupe seront retirées."
    }

    // MARK: - Actions

    /// Admins: invalidates the current code and shows the new one.
    @discardableResult
    public func regenerateInviteCode() async -> Bool {
        guard canSeeInviteCode else {
            present(AppError.forbidden)
            return false
        }
        guard !isRegeneratingCode else { return false }
        error = nil
        isRegeneratingCode = true
        defer { isRegeneratingCode = false }
        do {
            inviteCode = try await session.services.groups.regenerateInviteCode(groupId: groupId)
            return true
        } catch {
            present(error)
            return false
        }
    }

    /// Admins: gives or removes the admin role.
    @discardableResult
    public func setRole(_ role: MemberRole, for member: Membership) async -> Bool {
        guard canManageMembers else {
            present(AppError.forbidden)
            return false
        }
        guard !busyMemberIds.contains(member.id) else { return false }
        error = nil
        busyMemberIds.insert(member.id)
        defer { busyMemberIds.remove(member.id) }
        do {
            try await session.services.groups.setRole(groupId: groupId, userId: member.user.id, role: role)
            if let index = members.firstIndex(where: { $0.id == member.id }) {
                members[index].role = role
                members = NameOrder.sortedMembers(members)
            }
            if isMe(member) {
                myRole = role
                if role != .admin { inviteCode = nil }
            }
            session.feed.bump(groupId: groupId)
            session.feed.bumpMemberships()
            return true
        } catch {
            present(error)
            return false
        }
    }

    /// Admins: switches between admin and member.
    @discardableResult
    public func toggleRole(of member: Membership) async -> Bool {
        await setRole(member.role == .admin ? .member : .admin, for: member)
    }

    /// Admins: removes a member (their assignments in the group are removed too).
    @discardableResult
    public func remove(_ member: Membership) async -> Bool {
        guard canRemove(member) else {
            present(isMe(member) ? AppError.cannotRemoveSelf : AppError.forbidden)
            return false
        }
        guard !busyMemberIds.contains(member.id) else { return false }
        error = nil
        busyMemberIds.insert(member.id)
        defer { busyMemberIds.remove(member.id) }
        do {
            try await session.services.groups.removeMember(groupId: groupId, userId: member.user.id)
            members.removeAll { $0.id == member.id }
            session.feed.bump(groupId: groupId)
            return true
        } catch {
            if present(error) == .notMember {
                members.removeAll { $0.id == member.id }
            }
            return false
        }
    }

    /// Leaves the group (the last member deletes it). The last admin gets the `lastAdmin` error.
    @discardableResult
    public func leave() async -> Bool {
        guard !isLeaving else { return false }
        error = nil
        isLeaving = true
        defer { isLeaving = false }
        do {
            try await session.services.groups.leave(groupId: groupId)
            didLeave = true
            isGone = true
            session.feed.bumpMemberships()
            session.feed.bumpMyTasks()
            session.feed.bump(groupId: groupId)
            return true
        } catch {
            if present(error) == .notMember { markGone() }
            return false
        }
    }
}
