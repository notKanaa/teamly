import Foundation
import TeamTasksCore

// Profiles, groups, invites and memberships (docs/CONTRACTS.md §2, §4; docs/CONTRACTS-V2.md §1–§3, §5, §7, §9).
extension InMemoryBackend {
    // MARK: - Profiles

    /// `GET profiles?select=id,display_name,avatar_color,avatar_emoji,onboarded_at,created_at&id=eq.<me>`.
    func myProfile(clientId: UUID) throws -> UserProfile {
        try read(as: clientId) { data, me in
            guard let profile = data.profiles[me] else { throw AppError.notAuthenticated }
            return data.ownProfile(profile)
        }
    }

    /// `PATCH profiles?select=id,display_name,avatar_color,avatar_emoji`. The profile UPDATE also matches the Realtime
    /// binding on `profiles` (→ `.membershipsChanged`); v2: an actual change bumps every group of the user. Returns the
    /// profile with its avatar; `onboardedAt` and `createdAt` are only read by `myProfile()`.
    func updateDisplayName(clientId: UUID, name: String) throws -> UserProfile {
        try write(as: clientId) { transaction, me in
            let name = try InputRules.displayName(name)
            guard transaction.data.profiles[me] != nil else { throw AppError.forbidden }
            transaction.updateProfile(me) { $0.displayName = name }
            guard let profile = transaction.data.profiles[me] else { throw AppError.forbidden }
            return transaction.data.publicProfile(profile)
        }
    }

    /// Avatar `PATCH profiles` (docs/CONTRACTS-V2.md §2): `profiles_before_write` checks the display name (unchanged),
    /// then the color (a typed `ColorKey` is always valid), then the emoji (`.invalidAppearance`), stored normalized.
    /// Same signals and same result as a display-name change.
    func updateAvatar(clientId: UUID, color: ColorKey?, emoji: String?) throws -> UserProfile {
        try write(as: clientId) { transaction, me in
            let emoji = try InputRules.emoji(emoji)
            guard transaction.data.profiles[me] != nil else { throw AppError.forbidden }
            transaction.updateProfile(me) { profile in
                profile.avatarColor = color
                profile.avatarEmoji = emoji
            }
            guard let profile = transaction.data.profiles[me] else { throw AppError.forbidden }
            return transaction.data.publicProfile(profile)
        }
    }

    /// `complete_onboarding()`: `onboarded_at = coalesce(onboarded_at, now())`. No write (no Realtime event) when it is
    /// already set; `updated_at` does not move and no group is bumped.
    func completeOnboarding(clientId: UUID) throws {
        try write(as: clientId) { transaction, me in
            guard let profile = transaction.data.profiles[me], profile.onboardedAt == nil else { return }
            let now = transaction.now // local copy: see Transaction.finish()
            transaction.data.profiles[me]?.onboardedAt = now
            transaction.profileUpdated(me)
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

    /// v2 groups overview (docs/CONTRACTS-V2.md §10), the two reads in one snapshot: the members of `groupIds` and the
    /// tasks not done or done since `doneSince`, aggregated like the adapter (`GroupOverview.init(groupId:members:tasks:
    /// doneSince:)`). One overview per distinct group, in the order of `groupIds`; groups the caller does not belong
    /// to (RLS) are left out. The server's row limit is not mirrored: the mocks never leave out a readable group.
    func overviews(clientId: UUID, groupIds: [UUID], doneSince: Date) throws -> [GroupOverview] {
        try read(as: clientId) { data, me in
            var seen = Set<UUID>()
            return groupIds.compactMap { groupId -> GroupOverview? in
                guard seen.insert(groupId).inserted, data.isMember(me, of: groupId) else { return nil }
                let members = (data.members[groupId] ?? [:]).values.compactMap(data.membership)
                let tasks = data.tasks.values
                    .filter { $0.groupId == groupId }
                    .map { GroupOverview.TaskState(status: $0.status, completedAt: $0.completedAt) }
                return GroupOverview(groupId: groupId, members: members, tasks: tasks, doneSince: doneSince)
            }
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

    /// `GET group_activity?…&group_id=eq.<g>&order=id.desc&limit=50`: the newest `Limits.activityFeedMax` events.
    /// Non-members read nothing (RLS).
    func activity(clientId: UUID, groupId: UUID) throws -> [ActivityEvent] {
        try read(as: clientId) { data, me in
            guard data.isMember(me, of: groupId) else { return [] }
            return data.activity
                .filter { $0.groupId == groupId }
                .sorted { $0.id > $1.id }
                .prefix(Limits.activityFeedMax)
                .map(\.event)
        }
    }

    // MARK: - Group RPCs

    /// `create_group`: group + caller as admin + invite code. v2: `groups_before_write` checks the name, then the
    /// color (typed: always valid), then the emoji (`.invalidAppearance`), stored normalized; the creator's own
    /// membership writes no `member_joined`.
    func createGroup(clientId: UUID, name: String, color: ColorKey? = nil, emoji: String? = nil) throws -> GroupSummary {
        try write(as: clientId) { transaction, me in
            let name = try InputRules.groupName(name)
            let emoji = try InputRules.emoji(emoji)
            let group = GroupRecord(
                id: UUID(), name: name, createdBy: me, createdAt: transaction.now, lastActivityAt: transaction.now,
                color: color, emoji: emoji
            )
            transaction.data.groups[group.id] = group
            transaction.data.invites[group.id] = InviteRecord(
                groupId: group.id, code: transaction.data.newInviteCode(), createdBy: me, createdAt: transaction.now
            )
            transaction.insertMembership(groupId: group.id, userId: me, role: .admin)
            return GroupSummary(group: transaction.data.teamGroup(group), myRole: .admin)
        }
    }

    /// `set_group_appearance`: `group_not_found` (`.notFound`) → admin only (`.forbidden`, non-members included) →
    /// color → emoji (`.invalidAppearance`). nil = automatic color / no emoji (a blank emoji is stored nil). Sets
    /// `last_activity_at = now()` (one Realtime UPDATE, like `rename_group`).
    func setAppearance(clientId: UUID, groupId: UUID, color: ColorKey?, emoji: String?) throws -> TeamGroup {
        try write(as: clientId) { transaction, me in
            guard transaction.data.groups[groupId] != nil else { throw AppError.notFound }
            guard transaction.data.role(of: me, in: groupId) == .admin else { throw AppError.forbidden }
            let emoji = try InputRules.emoji(emoji)
            let now = transaction.now // local copy: see Transaction.finish()
            transaction.data.groups[groupId]?.color = color
            transaction.data.groups[groupId]?.emoji = emoji
            transaction.data.groups[groupId]?.lastActivityAt = now
            transaction.bump(groupId)
            guard let group = transaction.data.groups[groupId] else { throw AppError.notFound }
            return transaction.data.teamGroup(group)
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
    /// v2: `member_left` (actor = the admin), then the turn handover.
    func removeMember(clientId: UUID, groupId: UUID, userId: UUID) throws {
        try write(as: clientId) { transaction, me in
            guard transaction.data.role(of: me, in: groupId) == .admin else { throw AppError.forbidden }
            guard userId != me else { throw AppError.cannotRemoveSelf }
            guard transaction.data.isMember(userId, of: groupId) else { throw AppError.notMember }
            transaction.deleteMembership(groupId: groupId, userId: userId)
        }
    }

    /// `leave_group`: the only admin cannot leave while other members remain; the last member deletes the group.
    /// v2: `member_left` (actor = subject = the leaver), then the turn handover.
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
