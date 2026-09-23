import Foundation
import TeamTasksCore

// Rows of the in-memory "database". They mirror the tables of docs/CONTRACTS.md §3.

struct AccountRecord: Sendable {
    var id: UUID
    /// Trimmed and lowercased (Supabase Auth stores e-mails lowercased).
    var email: String
    var password: String
    var createdAt: Date
}

struct ProfileRecord: Sendable {
    var id: UUID
    var displayName: String
    var membershipsChangedAt: Date
    var createdAt: Date
    var updatedAt: Date
}

struct GroupRecord: Sendable {
    var id: UUID
    var name: String
    var createdBy: UUID?
    var createdAt: Date
    var lastActivityAt: Date
}

struct InviteRecord: Sendable {
    var groupId: UUID
    var code: String
    var createdBy: UUID?
    var createdAt: Date
}

struct MemberRecord: Sendable {
    var groupId: UUID
    var userId: UUID
    var role: MemberRole
    var joinedAt: Date

    /// Seniority order used to pick the member to promote: `joined_at`, then `user_id`.
    /// Uppercase `uuidString` order equals the byte order Postgres uses for `uuid`.
    static func joinedBefore(_ lhs: MemberRecord, _ rhs: MemberRecord) -> Bool {
        (lhs.joinedAt, lhs.userId.uuidString) < (rhs.joinedAt, rhs.userId.uuidString)
    }
}

struct TaskRecord: Sendable {
    var id: UUID
    var groupId: UUID
    var title: String
    var details: String?
    var status: TaskStatus
    var priority: TaskPriority
    var dueAt: Date?
    var createdBy: UUID?
    var createdAt: Date
    var updatedAt: Date
    var completedAt: Date?
}

extension TaskRecord {
    /// `tasks_before_update`: `updated_at` moves only when title, details, status, priority or due date changed.
    mutating func touch(from stored: TaskRecord, at now: Date) {
        let changed = title != stored.title || details != stored.details || status != stored.status
            || priority != stored.priority || dueAt != stored.dueAt
        updatedAt = changed ? now : stored.updatedAt
    }
}

struct AssigneeRecord: Sendable {
    var taskId: UUID
    var groupId: UUID
    var userId: UUID
    var assignedBy: UUID?
    var assignedAt: Date
}

struct PushRecord: Sendable {
    var userId: UUID
    var topic: String
    var createdAt: Date
}

struct JoinAttemptRecord: Sendable {
    var userId: UUID
    var attemptedAt: Date
    var succeeded: Bool
}

struct RecoveryRecord: Sendable {
    var userId: UUID
    var code: String
    var createdAt: Date
}

/// The whole persistent state. A value type, so a transaction works on a copy and commits atomically.
struct BackendData: Sendable {
    var accounts: [UUID: AccountRecord] = [:]
    var profiles: [UUID: ProfileRecord] = [:]
    var groups: [UUID: GroupRecord] = [:]
    /// Keyed by group id (one invite per group).
    var invites: [UUID: InviteRecord] = [:]
    /// group id → user id → membership.
    var members: [UUID: [UUID: MemberRecord]] = [:]
    var tasks: [UUID: TaskRecord] = [:]
    /// task id → user id → assignee row.
    var assignees: [UUID: [UUID: AssigneeRecord]] = [:]
    /// Keyed by user id.
    var pushTopics: [UUID: PushRecord] = [:]
    var joinAttempts: [JoinAttemptRecord] = []
    /// Pending password-recovery codes, keyed by user id.
    var recoveries: [UUID: RecoveryRecord] = [:]
}

// MARK: - Queries

extension BackendData {
    func account(email: String) -> AccountRecord? {
        accounts.values.first { $0.email == email }
    }

    func role(of userId: UUID, in groupId: UUID) -> MemberRole? {
        members[groupId]?[userId]?.role
    }

    func isMember(_ userId: UUID, of groupId: UUID) -> Bool {
        members[groupId]?[userId] != nil
    }

    func adminCount(in groupId: UUID) -> Int {
        members[groupId]?.values.filter { $0.role == .admin }.count ?? 0
    }

    /// Groups the user belongs to, in a stable order.
    func groupIds(of userId: UUID) -> [UUID] {
        members.compactMap { $0.value[userId] != nil ? $0.key : nil }.sortedByUUIDString()
    }

    func taskIds(in groupId: UUID) -> [UUID] {
        tasks.values.filter { $0.groupId == groupId }.map(\.id).sortedByUUIDString()
    }

    func assigneeIds(of taskId: UUID) -> [UUID] {
        Array((assignees[taskId] ?? [:]).keys).sortedByUUIDString()
    }

    /// `profiles` SELECT policy: self or co-member.
    func canSeeProfile(of userId: UUID, as viewer: UUID) -> Bool {
        viewer == userId || members.values.contains { $0[viewer] != nil && $0[userId] != nil }
    }

    /// Visibility rule of the `tasks` SELECT policy: members of the task's group.
    func visibleTask(_ taskId: UUID, to userId: UUID) -> TaskRecord? {
        guard let task = tasks[taskId], isMember(userId, of: task.groupId) else { return nil }
        return task
    }

    /// Admin of the task's group, or creator who is still a member (docs/CONTRACTS.md §2).
    func canEdit(_ task: TaskRecord, userId: UUID) -> Bool {
        guard let role = role(of: userId, in: task.groupId) else { return false }
        return role == .admin || task.createdBy == userId
    }

    /// Editors, plus members assigned to the task.
    func canChangeStatus(_ task: TaskRecord, userId: UUID) -> Bool {
        guard isMember(userId, of: task.groupId) else { return false }
        return canEdit(task, userId: userId) || assignees[task.id]?[userId] != nil
    }

    func teamGroup(_ record: GroupRecord) -> TeamGroup {
        TeamGroup(
            id: record.id,
            name: record.name,
            createdBy: record.createdBy,
            createdAt: record.createdAt,
            lastActivityAt: record.lastActivityAt
        )
    }

    func taskItem(_ record: TaskRecord) -> TaskItem {
        TaskItem(
            id: record.id,
            groupId: record.groupId,
            title: record.title,
            details: record.details,
            status: record.status,
            priority: record.priority,
            dueAt: record.dueAt,
            createdBy: record.createdBy,
            createdAt: record.createdAt,
            updatedAt: record.updatedAt,
            completedAt: record.completedAt,
            assigneeIds: assigneeIds(of: record.id)
        )
    }

    func membership(_ record: MemberRecord) -> Membership? {
        guard let profile = profiles[record.userId] else { return nil }
        return Membership(
            groupId: record.groupId,
            user: UserProfile(id: profile.id, displayName: profile.displayName),
            role: record.role,
            joinedAt: record.joinedAt
        )
    }

    func authUser(_ userId: UUID) -> AuthUser? {
        guard let account = accounts[userId] else { return nil }
        return AuthUser(id: account.id, email: account.email)
    }
}

// MARK: - Generators

extension BackendData {
    static let inviteAlphabet = Array("ABCDEFGHJKLMNPQRSTUVWXYZ23456789")
    static let topicAlphabet = Array("abcdefghijklmnopqrstuvwxyz0123456789")

    /// Random 8-character code from the invite alphabet, unique among existing invites
    /// (mirrors `private.generate_invite_code()`).
    func newInviteCode() -> String {
        let used = Set(invites.values.map(\.code))
        while true {
            let code = String((0..<InviteCode.length).map { _ in BackendData.inviteAlphabet.randomElement() ?? "A" })
            if !used.contains(code) { return code }
        }
    }

    /// `equipe-` + 24 random `[a-z0-9]` characters, unique among existing subscriptions.
    func newPushTopic() -> String {
        let used = Set(pushTopics.values.map(\.topic))
        while true {
            let suffix = String((0..<24).map { _ in BackendData.topicAlphabet.randomElement() ?? "a" })
            let topic = InMemoryBackend.pushTopicPrefix + suffix
            if !used.contains(topic) { return topic }
        }
    }
}

// MARK: - Helpers

extension Sequence where Element == UUID {
    /// Sorted by `uuidString` (the order used for `TaskItem.assigneeIds`).
    func sortedByUUIDString() -> [UUID] {
        sorted { $0.uuidString < $1.uuidString }
    }
}
