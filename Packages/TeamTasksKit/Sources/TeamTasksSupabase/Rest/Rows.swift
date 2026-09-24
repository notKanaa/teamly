import Foundation
import TeamTasksCore

// JSON rows returned by PostgREST for the reads and RPCs of docs/CONTRACTS.md §4. Column names are the SQL
// ones; embedded resources use the aliases of the `select` parameters (`group`, `profile`, `assignees`, `mine`,
// `task`). Dates are decoded by `RestDecoding` (0 to 6 fractional digits). Enum columns are `Known` values: in a
// list read (`RestClient.fetchRows`), a row with a value added by a later migration is left out instead of
// failing the whole list.

/// `public.groups` row (`create_group`, `rename_group`, embedded `group:groups(*)`).
struct GroupRow: Decodable, Sendable, Hashable {
    let id: UUID
    let name: String
    let createdBy: UUID?
    let createdAt: Date
    let lastActivityAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case createdBy = "created_by"
        case createdAt = "created_at"
        case lastActivityAt = "last_activity_at"
    }

    var teamGroup: TeamGroup {
        TeamGroup(id: id, name: name, createdBy: createdBy, createdAt: createdAt, lastActivityAt: lastActivityAt)
    }
}

/// `group_members?select=role,group:groups(*)`.
struct MyGroupRow: Decodable, Sendable, Hashable {
    private let knownRole: Known<MemberRole>
    let group: GroupRow

    enum CodingKeys: String, CodingKey {
        case knownRole = "role"
        case group
    }

    var role: MemberRole { knownRole.value }

    var summary: GroupSummary {
        GroupSummary(group: group.teamGroup, myRole: role)
    }
}

/// `profiles?select=id,display_name` (also the embedded `profile:profiles(id,display_name)`).
struct ProfileRow: Decodable, Sendable, Hashable {
    let id: UUID
    let displayName: String

    enum CodingKeys: String, CodingKey {
        case id
        case displayName = "display_name"
    }

    var profile: UserProfile {
        UserProfile(id: id, displayName: displayName)
    }
}

/// `group_members?select=user_id,role,joined_at,profile:profiles(id,display_name)`.
struct MemberRow: Decodable, Sendable, Hashable {
    let userId: UUID
    private let knownRole: Known<MemberRole>
    let joinedAt: Date
    let profile: ProfileRow?

    enum CodingKeys: String, CodingKey {
        case userId = "user_id"
        case knownRole = "role"
        case joinedAt = "joined_at"
        case profile
    }

    var role: MemberRole { knownRole.value }

    func membership(groupId: UUID) -> Membership {
        Membership(
            groupId: groupId,
            user: UserProfile(id: userId, displayName: profile?.displayName ?? ""),
            role: role,
            joinedAt: joinedAt
        )
    }
}

/// `group_invites?select=code`.
struct InviteRow: Decodable, Sendable, Hashable {
    let code: String
}

/// `push_subscriptions?select=topic`.
struct PushTopicRow: Decodable, Sendable, Hashable {
    let topic: String
}

/// `join_group_by_code` result: `{status, group_id, group_name}`.
struct JoinRow: Decodable, Sendable, Hashable {
    let status: String
    let groupId: UUID?
    let groupName: String?

    enum CodingKeys: String, CodingKey {
        case status
        case groupId = "group_id"
        case groupName = "group_name"
    }

    func result() throws -> JoinResult {
        switch status {
        case "joined", "already_member":
            guard let groupId, let groupName else { throw AppError.unknown("réponse inattendue du serveur") }
            return JoinResult(groupId: groupId, groupName: groupName, alreadyMember: status == "already_member")
        case "invalid_code":
            throw AppError.invalidCode
        default:
            throw AppError.unknown("réponse inattendue du serveur")
        }
    }
}

/// `{user_id}` of the embedded `assignees:task_assignees(user_id)`.
struct AssigneeRow: Decodable, Sendable, Hashable {
    let userId: UUID

    enum CodingKeys: String, CodingKey {
        case userId = "user_id"
    }
}

/// `{assigned_at, assigned_by, user_id}` of the embedded `mine:task_assignees!inner(assigned_at,assigned_by,user_id)`.
struct MyAssignmentRow: Decodable, Sendable, Hashable {
    let assignedAt: Date
    /// NULL when the assigner deleted their account.
    let assignedBy: UUID?
    let userId: UUID

    enum CodingKeys: String, CodingKey {
        case assignedAt = "assigned_at"
        case assignedBy = "assigned_by"
        case userId = "user_id"
    }
}

/// `{name}` of an embedded `group:groups(name)`.
struct GroupNameRow: Decodable, Sendable, Hashable {
    let name: String
}

/// `public.tasks` row, bare (RPC results) or with the embedded resources of the task reads.
struct TaskDTO: Decodable, Sendable, Hashable {
    let id: UUID
    let groupId: UUID
    let title: String
    let details: String?
    private let knownStatus: Known<TaskStatus>
    private let knownPriority: Known<TaskPriority>
    let dueAt: Date?
    let createdBy: UUID?
    let createdAt: Date
    let updatedAt: Date
    let completedAt: Date?
    /// `assignees:task_assignees(user_id)` (absent from RPC results).
    let assignees: [AssigneeRow]?
    /// `mine:task_assignees!inner(assigned_at,assigned_by,user_id)` (`myTasks` only).
    let mine: [MyAssignmentRow]?
    /// `group:groups(name)` (`myTasks` only).
    let group: GroupNameRow?

    enum CodingKeys: String, CodingKey {
        case id
        case groupId = "group_id"
        case title
        case details
        case knownStatus = "status"
        case knownPriority = "priority"
        case dueAt = "due_at"
        case createdBy = "created_by"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case completedAt = "completed_at"
        case assignees
        case mine
        case group
    }

    var status: TaskStatus { knownStatus.value }
    var priority: TaskPriority { knownPriority.value }

    /// The task; `assigneeIds` defaults to the embedded assignees, sorted by `uuidString`.
    func item(assigneeIds: [UUID]? = nil) -> TaskItem {
        let ids = assigneeIds ?? (assignees ?? []).map(\.userId)
        return TaskItem(
            id: id,
            groupId: groupId,
            title: title,
            details: details,
            status: status,
            priority: priority,
            dueAt: dueAt,
            createdBy: createdBy,
            createdAt: createdAt,
            updatedAt: updatedAt,
            completedAt: completedAt,
            assigneeIds: TaskDTO.sorted(ids)
        )
    }

    /// `myTasks` item: also `myAssignedAt`, `myAssignedBy` and `groupName`.
    var myTaskItem: TaskItem {
        var task = item()
        task.myAssignedAt = mine?.first?.assignedAt
        task.myAssignedBy = mine?.first?.assignedBy
        task.groupName = group?.name
        return task
    }

    static func sorted(_ ids: [UUID]) -> [UUID] {
        Array(Set(ids)).sorted { $0.uuidString < $1.uuidString }
    }

    /// Deterministic order for task lists (the server order is unspecified; view models sort with `TaskSort`).
    static func creationOrder(_ lhs: TaskItem, _ rhs: TaskItem) -> Bool {
        if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
        return lhs.id.uuidString < rhs.id.uuidString
    }
}

/// `task_assignees?select=task_id,group_id,assigned_by,assigned_at,task:tasks(title,due_at,group:groups(name))`.
struct AssignmentRow: Decodable, Sendable, Hashable {
    struct EmbeddedTask: Decodable, Sendable, Hashable {
        let title: String
        let dueAt: Date?
        let group: GroupNameRow?

        enum CodingKeys: String, CodingKey {
            case title
            case dueAt = "due_at"
            case group
        }
    }

    let taskId: UUID
    let groupId: UUID
    let assignedBy: UUID?
    let assignedAt: Date
    let task: EmbeddedTask?

    enum CodingKeys: String, CodingKey {
        case taskId = "task_id"
        case groupId = "group_id"
        case assignedBy = "assigned_by"
        case assignedAt = "assigned_at"
        case task
    }

    var event: AssignmentEvent? {
        guard let task else { return nil }
        return AssignmentEvent(
            taskId: taskId,
            groupId: groupId,
            taskTitle: task.title,
            groupName: task.group?.name ?? "",
            assignedBy: assignedBy,
            assignedAt: assignedAt,
            dueAt: task.dueAt
        )
    }
}
