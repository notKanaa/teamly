import Foundation
import TeamTasksCore

/// Unique values so that scenarios never collide with each other or with existing data on a real server.
enum Unique {
    private static let alphabet = Array("ABCDEFGHJKLMNPQRSTUVWXYZ23456789")

    static func token(_ length: Int = 6) -> String {
        String((0..<length).map { _ in alphabet.randomElement() ?? "A" })
    }

    /// `"<base> <token>"`, e.g. `"Alice K7Q2ZP"`. Bases starting with distinct letters sort predictably.
    static func name(_ base: String) -> String {
        "\(base) \(token())"
    }

    /// A random, well-formed invite code (practically never an existing one).
    static func inviteCode() -> InviteCode {
        InviteCode(token(InviteCode.length)) ?? InviteCode("ZZZZZZZZ")!
    }

    /// A fresh e-mail on the same domain as `reference`.
    static func email(like reference: String) -> String {
        let domain = reference.split(separator: "@").last.map(String.init) ?? "example.com"
        return "contrat-\(token(10).lowercased())@\(domain)"
    }
}

/// Deterministic values (whole seconds, so they round-trip exactly through any backend).
enum Fixed {
    /// 2031-01-01T00:00:00Z.
    static let dueA = Date(timeIntervalSince1970: 1_924_992_000)
    /// 2031-03-01T12:30:00Z.
    static let dueB = Date(timeIntervalSince1970: 1_930_091_400)
    /// Earlier than any server timestamp.
    static let longAgo = Date(timeIntervalSince1970: 0)

    static func text(_ count: Int) -> String {
        String(repeating: "x", count: count)
    }
}

/// A group created by a scenario.
struct GroupFixture: Sendable {
    let id: UUID
    let name: String
    let code: InviteCode
}

func sortedIDs(_ users: [ContractUser]) -> [UUID] {
    users.map(\.id).sorted { $0.uuidString < $1.uuidString }
}

func isPushTopic(_ topic: String) -> Bool {
    let prefix = "equipe-"
    guard topic.hasPrefix(prefix) else { return false }
    let suffix = topic.dropFirst(prefix.count)
    return suffix.count == 24 && suffix.allSatisfy { ("a"..."z").contains($0) || ("0"..."9").contains($0) }
}

func isWellFormedCode(_ code: InviteCode) -> Bool {
    code.value.count == InviteCode.length && code.value.allSatisfy { InviteCode.alphabet.contains($0) }
}

extension TaskItem {
    /// The task without the `myTasks`-only fields, to compare with `task(id:)`.
    var withoutPersonalFields: TaskItem {
        var copy = self
        copy.myAssignedAt = nil
        copy.groupName = nil
        return copy
    }
}

extension ContractHarness {
    /// A fresh user named `"<base> <token>"`.
    func user(_ base: String) async throws -> ContractUser {
        try await Verify.step("makeUser(\(base))") {
            try await makeUser(displayName: Unique.name(base))
        }
    }
}

extension ContractUser {
    /// Creates a group administered by this user; `members` then join it, in order.
    func makeGroup(_ base: String = "Groupe", joinedBy members: [ContractUser] = []) async throws -> GroupFixture {
        let name = Unique.name(base)
        let summary = try await Verify.step("\(displayName) creates group \(name)") {
            try await groups.createGroup(name: name)
        }
        let code = try await Verify.step("\(displayName) reads the invite code") {
            try await groups.inviteCode(groupId: summary.id)
        }
        let fixture = GroupFixture(id: summary.id, name: name, code: code)
        for member in members {
            let result = try await member.join(fixture)
            try Verify.that(!result.alreadyMember, "\(member.displayName) should be a new member of \(name)")
        }
        return fixture
    }

    func join(_ group: GroupFixture) async throws -> JoinResult {
        try await Verify.step("\(displayName) joins \(group.name)") {
            try await groups.join(code: group.code)
        }
    }

    /// Creates a task titled `"<base> <token>"`.
    func makeTask(
        in groupId: UUID,
        _ base: String = "Tâche",
        assignees: [ContractUser] = [],
        priority: TaskPriority = .medium,
        dueAt: Date? = nil
    ) async throws -> TaskItem {
        let draft = TaskDraft(
            title: Unique.name(base), priority: priority, dueAt: dueAt, assigneeIds: Set(assignees.map(\.id))
        )
        return try await Verify.step("\(displayName) creates task \(draft.title)") {
            try await tasks.create(groupId: groupId, draft: draft)
        }
    }

    /// Full edit keeping the current fields, only replacing the assignees.
    func reassign(_ task: TaskItem, to users: [ContractUser]) async throws -> TaskItem {
        var draft = TaskDraft(task: task)
        draft.assigneeIds = Set(users.map(\.id))
        return try await tasks.update(taskId: task.id, draft: draft)
    }

    func summary(of groupId: UUID) async throws -> GroupSummary? {
        try await groups.myGroups().first { $0.id == groupId }
    }

    func lastActivity(of groupId: UUID) async throws -> Date {
        let summary = try await summary(of: groupId)
        return try Verify.unwrap(summary, "group \(groupId) in \(displayName)'s groups").group.lastActivityAt
    }

    /// Checks that the group's `lastActivityAt` moved strictly after `previous`; returns the new value.
    func checkBumped(_ groupId: UUID, since previous: Date, _ action: String) async throws -> Date {
        let current = try await lastActivity(of: groupId)
        try Verify.that(current > previous, "\(action) must bump lastActivityAt (\(previous) → \(current))")
        return current
    }

    /// Member ids in the order returned by `members(groupId:)`.
    func memberIDs(of groupId: UUID) async throws -> [UUID] {
        try await groups.members(groupId: groupId).map(\.user.id)
    }

    func role(in groupId: UUID) async throws -> MemberRole? {
        try await summary(of: groupId)?.myRole
    }

    /// Subscribes to Realtime and waits for `.connected`, so that later changes are delivered.
    func subscribe(groups groupIds: [UUID]) async throws -> StreamProbe<RealtimeEvent> {
        let probe = StreamProbe(realtime.events(userId: id, groupIds: groupIds))
        do {
            try await probe.waitFor("\(displayName): .connected") { $0 == .connected }
        } catch {
            probe.stop()
            throw error
        }
        return probe
    }
}
