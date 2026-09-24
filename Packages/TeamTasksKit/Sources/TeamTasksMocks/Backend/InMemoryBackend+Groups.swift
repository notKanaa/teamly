import Foundation
import TeamTasksCore

// Profiles, groups, invites and memberships (docs/CONTRACTS.md §2, §4).
extension InMemoryBackend {
    // MARK: - Profiles

    func myProfile(clientId: UUID) throws -> UserProfile {
        try read(as: clientId) { data, me in
            guard let profile = data.profiles[me] else { throw AppError.notAuthenticated }
            return UserProfile(id: profile.id, displayName: profile.displayName)
        }
    }

    /// `PATCH profiles`. The profile UPDATE also matches the Realtime binding on `profiles` (→ `.membershipsChanged`).
    func updateDisplayName(clientId: UUID, name: String) throws -> UserProfile {
        try write(as: clientId) { transaction, me in
            let name = try InputRules.displayName(name)
            guard transaction.data.profiles[me] != nil else { throw AppError.forbidden }
            let now = transaction.now // local copy: see Transaction.finish()
            transaction.data.profiles[me]?.displayName = name
            transaction.data.profiles[me]?.updatedAt = now
            transaction.profileUpdated(me)
            return UserProfile(id: me, displayName: name)
        }
    }

    // MARK: - Group reads

    /// Groups of the caller, most recently active first.
    func myGroups(clientId: UUID) throws -> [GroupSummary] {
        try read(as: clientId) { data, me in
            NameOrder.sortedGroups(data.groupIds(of: me).compactMap { groupId -> GroupSummary? in
                guard let group = data.groups[groupId], let role = data.role(of: me, in: groupId) else { return nil }
                return GroupSummary(group: data.teamGroup(group), myRole: role)
            })
        }
    }

    /// Members sorted admins first, then by display name. Non-members get an empty list (RLS).
    func members(clientId: UUID, groupId: UUID) throws -> [Membership] {
        try read(as: clientId) { data, me in
            guard data.isMember(me, of: groupId) else { return [] }
            return NameOrder.sortedMembers((data.members[groupId] ?? [:]).values.compactMap(data.membership))
        }
    }

    /// `group_invites` is readable by admins only: 0 rows → `.forbidden`.
    func inviteCode(clientId: UUID, groupId: UUID) throws -> InviteCode {
        try read(as: clientId) { data, me in
            guard data.role(of: me, in: groupId) == .admin, let invite = data.invites[groupId] else {
                throw AppError.forbidden
            }
            return try InMemoryBackend.inviteCode(invite.code)
        }
    }

    // MARK: - Group RPCs

    /// `create_group`: group + caller as admin + invite code.
    func createGroup(clientId: UUID, name: String) throws -> GroupSummary {
        try write(as: clientId) { transaction, me in
            let name = try InputRules.groupName(name)
            let group = GroupRecord(
                id: UUID(), name: name, createdBy: me, createdAt: transaction.now, lastActivityAt: transaction.now
            )
            transaction.data.groups[group.id] = group
            transaction.data.invites[group.id] = InviteRecord(
                groupId: group.id, code: transaction.data.newInviteCode(), createdBy: me, createdAt: transaction.now
            )
            transaction.insertMembership(groupId: group.id, userId: me, role: .admin)
            return GroupSummary(group: transaction.data.teamGroup(group), myRole: .admin)
        }
    }

    private enum JoinOutcome {
        case joined(JoinResult)
        case invalidCode
    }

    /// `join_group_by_code`. An invalid code is logged (and committed) before `.invalidCode` is thrown.
    /// Failures count while `attempted_at >= now() - 1 hour` (an attempt exactly one hour old still counts).
    func join(clientId: UUID, code: InviteCode) throws -> JoinResult {
        let outcome = try write(as: clientId) { transaction, me -> JoinOutcome in
            let windowStart = transaction.now.addingTimeInterval(-InMemoryBackend.joinRateLimitWindow)
            let failures = transaction.data.joinAttempts.filter {
                $0.userId == me && !$0.succeeded && $0.attemptedAt >= windowStart
            }.count
            if failures >= InMemoryBackend.maxFailedJoinsPerHour { throw AppError.rateLimited }

            let normalized = InviteCode.normalize(code.value)
            guard let invite = transaction.data.invites.values.first(where: { $0.code == normalized }),
                  let group = transaction.data.groups[invite.groupId]
            else {
                transaction.data.joinAttempts.append(JoinAttemptRecord(userId: me, attemptedAt: transaction.now, succeeded: false))
                return .invalidCode
            }
            transaction.data.joinAttempts.append(JoinAttemptRecord(userId: me, attemptedAt: transaction.now, succeeded: true))
            if transaction.data.isMember(me, of: group.id) {
                return .joined(JoinResult(groupId: group.id, groupName: group.name, alreadyMember: true))
            }
            transaction.insertMembership(groupId: group.id, userId: me, role: .member)
            return .joined(JoinResult(groupId: group.id, groupName: group.name, alreadyMember: false))
        }
        switch outcome {
        case let .joined(result): return result
        case .invalidCode: throw AppError.invalidCode
        }
    }

    /// `regenerate_invite_code`: admin only; the previous code stops working.
    func regenerateInviteCode(clientId: UUID, groupId: UUID) throws -> InviteCode {
        try write(as: clientId) { transaction, me in
            guard transaction.data.role(of: me, in: groupId) == .admin, transaction.data.groups[groupId] != nil else {
                throw AppError.forbidden
            }
            let code = transaction.data.newInviteCode()
            transaction.data.invites[groupId] = InviteRecord(groupId: groupId, code: code, createdBy: me, createdAt: transaction.now)
            return try InMemoryBackend.inviteCode(code)
        }
    }

    /// `rename_group`: `group_not_found` for an unknown group, then admin only, then name validation.
    func rename(clientId: UUID, groupId: UUID, name: String) throws -> TeamGroup {
        try write(as: clientId) { transaction, me in
            guard transaction.data.groups[groupId] != nil else { throw AppError.notFound }
            guard transaction.data.role(of: me, in: groupId) == .admin else { throw AppError.forbidden }
            let name = try InputRules.groupName(name)
            let now = transaction.now // local copy: see Transaction.finish()
            transaction.data.groups[groupId]?.name = name
            transaction.data.groups[groupId]?.lastActivityAt = now
            transaction.bump(groupId)
            guard let group = transaction.data.groups[groupId] else { throw AppError.notFound }
            return transaction.data.teamGroup(group)
        }
    }

    /// `delete_group`: admin only; cascades.
    func deleteGroup(clientId: UUID, groupId: UUID) throws {
        try write(as: clientId) { transaction, me in
            guard transaction.data.groups[groupId] != nil else { throw AppError.notFound }
            guard transaction.data.role(of: me, in: groupId) == .admin else { throw AppError.forbidden }
            transaction.deleteGroup(groupId)
        }
    }

    /// `set_member_role`: admin only; the target must be a member; the last admin cannot be demoted.
    /// Like SQL, an unchanged role returns before any write: no bump, no Realtime signal.
    func setRole(clientId: UUID, groupId: UUID, userId: UUID, role: MemberRole) throws {
        try write(as: clientId) { transaction, me in
            guard transaction.data.role(of: me, in: groupId) == .admin else { throw AppError.forbidden }
            guard let current = transaction.data.role(of: userId, in: groupId) else { throw AppError.notMember }
            guard current != role else { return }
            if current == .admin, role == .member, transaction.data.adminCount(in: groupId) == 1 {
                throw AppError.lastAdmin
            }
            transaction.updateRole(groupId: groupId, userId: userId, role: role)
        }
    }

    /// `remove_member`: admin only, not self, target must be a member. Admins can remove other admins.
    func removeMember(clientId: UUID, groupId: UUID, userId: UUID) throws {
        try write(as: clientId) { transaction, me in
            guard transaction.data.role(of: me, in: groupId) == .admin else { throw AppError.forbidden }
            guard userId != me else { throw AppError.cannotRemoveSelf }
            guard transaction.data.isMember(userId, of: groupId) else { throw AppError.notMember }
            transaction.deleteMembership(groupId: groupId, userId: userId)
        }
    }

    /// `leave_group`: the only admin cannot leave while other members remain; the last member deletes the group.
    func leave(clientId: UUID, groupId: UUID) throws {
        try write(as: clientId) { transaction, me in
            guard let role = transaction.data.role(of: me, in: groupId) else { throw AppError.notMember }
            let memberCount = transaction.data.members[groupId]?.count ?? 0
            if memberCount == 1 {
                transaction.deleteGroup(groupId)
                return
            }
            if role == .admin, transaction.data.adminCount(in: groupId) == 1 {
                throw AppError.lastAdmin
            }
            transaction.deleteMembership(groupId: groupId, userId: me)
        }
    }

    // MARK: - Push (ntfy topic)

    func currentPushTopic(clientId: UUID) throws -> String? {
        try read(as: clientId) { data, me in data.pushTopics[me]?.topic }
    }

    /// `enable_push`: returns the existing topic or creates a random one.
    func enablePush(clientId: UUID) throws -> String {
        try write(as: clientId) { transaction, me in
            if let existing = transaction.data.pushTopics[me] { return existing.topic }
            let topic = transaction.data.newPushTopic()
            transaction.data.pushTopics[me] = PushRecord(userId: me, topic: topic, createdAt: transaction.now)
            return topic
        }
    }

    func disablePush(clientId: UUID) throws {
        try write(as: clientId) { transaction, me in
            transaction.data.pushTopics[me] = nil
        }
    }

    // MARK: - Helpers

    static func inviteCode(_ stored: String) throws -> InviteCode {
        guard let code = InviteCode(stored) else { throw AppError.unknown("code d’invitation corrompu") }
        return code
    }
}
