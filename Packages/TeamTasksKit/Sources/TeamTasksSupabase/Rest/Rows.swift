import Foundation
import TeamTasksCore

// JSON rows returned by PostgREST for the reads and RPCs of docs/CONTRACTS.md §4 and docs/CONTRACTS-V2.md §5, §8, §10.
// Column names are the SQL ones; embedded resources use the aliases of the `select` parameters (`group`, `profile`,
// `assignees`, `checklist`, `mine`, `task`). Dates are decoded by `RestDecoding` (0 to 6 fractional digits).
//
// Forward compatibility (docs/CONTRACTS.md §9): enum columns, the recurrence frequency and the activity kind are
// `Known` values: in a list read (`RestClient.fetchRows`), a row with a value added by a later version is left out
// instead of failing the whole list. A color is different: an unknown color text reads as nil, the automatic color
// (docs/CONTRACTS-V2.md §1), since it only changes the display.

extension ColorKey {
    /// The color of a stored `ColorKey` text; nil for NULL (automatic) and for a text unknown to this client.
    static func stored(_ text: String?) -> ColorKey? {
        text.flatMap(ColorKey.init(rawValue:))
    }
}

/// `public.groups` row (`create_group`, `rename_group`, `set_group_appearance`, embedded `group:groups(*)`).
struct GroupRow: Decodable, Sendable, Hashable {
    let id: UUID
    let name: String
    let createdBy: UUID?
    let createdAt: Date
    let lastActivityAt: Date
    /// v2 `color`, as stored (see `color`).
    let colorText: String?
    /// v2 `emoji` (stored normalized).
    let emoji: String?

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case createdBy = "created_by"
        case createdAt = "created_at"
        case lastActivityAt = "last_activity_at"
        case colorText = "color"
        case emoji
    }

    /// nil: automatic, or a color unknown to this client.
    var color: ColorKey? { ColorKey.stored(colorText) }

    var teamGroup: TeamGroup {
        TeamGroup(
            id: id, name: name, createdBy: createdBy, createdAt: createdAt, lastActivityAt: lastActivityAt,
            color: color, emoji: emoji
        )
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

/// `profiles?select=id,display_name,avatar_color,avatar_emoji` (members, the `PATCH` results), plus
/// `onboarded_at,created_at` for `myProfile` (absent keys read as nil).
struct ProfileRow: Decodable, Sendable, Hashable {
    let id: UUID
    let displayName: String
    /// v2 `avatar_color`, as stored (see `avatarColor`).
    let avatarColorText: String?
    let avatarEmoji: String?
    let onboardedAt: Date?
    let createdAt: Date?

    enum CodingKeys: String, CodingKey {
        case id
        case displayName = "display_name"
        case avatarColorText = "avatar_color"
        case avatarEmoji = "avatar_emoji"
        case onboardedAt = "onboarded_at"
        case createdAt = "created_at"
    }

    /// nil: automatic, or a color unknown to this client.
    var avatarColor: ColorKey? { ColorKey.stored(avatarColorText) }

    var profile: UserProfile {
        UserProfile(
            id: id, displayName: displayName, avatarColor: avatarColor, avatarEmoji: avatarEmoji,
            onboardedAt: onboardedAt, createdAt: createdAt
        )
    }
}

/// `group_members?select=user_id,role,joined_at,profile:profiles(id,display_name,avatar_color,avatar_emoji)`; v2, the
/// groups overview also selects `group_id` (docs/CONTRACTS-V2.md §10).
struct MemberRow: Decodable, Sendable, Hashable {
    /// Only read by the groups overview (nil in the members read).
    let groupId: UUID?
    let userId: UUID
    private let knownRole: Known<MemberRole>
    let joinedAt: Date
    let profile: ProfileRow?

    enum CodingKeys: String, CodingKey {
        case groupId = "group_id"
        case userId = "user_id"
        case knownRole = "role"
        case joinedAt = "joined_at"
        case profile
    }

    var role: MemberRole { knownRole.value }

    func membership(groupId: UUID) -> Membership {
        Membership(
            groupId: groupId,
            user: UserProfile(
                id: userId,
                displayName: profile?.displayName ?? "",
                avatarColor: profile?.avatarColor,
                avatarEmoji: profile?.avatarEmoji
            ),
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

/// An embedded group: `group:groups(name)` (assignments), `group:groups(name,color,emoji)` (`myTasks`).
struct GroupNameRow: Decodable, Sendable, Hashable {
    let name: String
    /// v2 `color`, as stored (absent from the assignments read).
    let colorText: String?
    let emoji: String?

    enum CodingKeys: String, CodingKey {
        case name
        case colorText = "color"
        case emoji
    }

    /// nil: automatic, or a color unknown to this client.
    var color: ColorKey? { ColorKey.stored(colorText) }
}

/// `public.task_checklist_items` row: the embedded `checklist:task_checklist_items(id,title,position,done,done_at,done_by)`
/// and the whole rows returned by the checklist RPCs.
struct ChecklistItemRow: Decodable, Sendable, Hashable {
    let id: UUID
    let title: String
    let position: Int
    let done: Bool
    let doneAt: Date?
    let doneBy: UUID?

    enum CodingKeys: String, CodingKey {
        case id
        case title
        case position
        case done
        case doneAt = "done_at"
        case doneBy = "done_by"
    }

    var item: ChecklistItem {
        ChecklistItem(id: id, title: title, position: position, isDone: done, doneAt: doneAt, doneBy: doneBy)
    }
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
    /// v2: the `repeat_*` columns (the server's `repeat_month_day` included); nil for a plain task.
    let recurrence: RecurrenceRule?
    /// v2 `rotation`, in turn order; nil (NULL) without rotation.
    let rotation: [UUID]?
    let turnUserId: UUID?
    let seriesId: UUID?
    let nextOccurrenceId: UUID?
    let completedBy: UUID?
    /// `assignees:task_assignees(user_id)` (absent from RPC results).
    let assignees: [AssigneeRow]?
    /// v2 `checklist:task_checklist_items(…)` (absent from RPC results).
    let checklist: [ChecklistItemRow]?
    /// `mine:task_assignees!inner(assigned_at,assigned_by,user_id)` (`myTasks` only).
    let mine: [MyAssignmentRow]?
    /// `group:groups(name,color,emoji)` (`myTasks` only).
    let group: GroupNameRow?

    enum CodingKeys: String, CodingKey {
        case id
        case groupId = "group_id"
        case title
        case details
        case status
        case priority
        case dueAt = "due_at"
        case createdBy = "created_by"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case completedAt = "completed_at"
        case repeatFreq = "repeat_freq"
        case repeatInterval = "repeat_interval"
        case repeatWeekdays = "repeat_weekdays"
        case repeatMonthDay = "repeat_month_day"
        case repeatTimeZone = "repeat_tz"
        case rotation
        case turnUserId = "turn_user_id"
        case seriesId = "series_id"
        case nextOccurrenceId = "next_occurrence_id"
        case completedBy = "completed_by"
        case assignees
        case checklist
        case mine
        case group
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        groupId = try container.decode(UUID.self, forKey: .groupId)
        title = try container.decode(String.self, forKey: .title)
        details = try container.decodeIfPresent(String.self, forKey: .details)
        knownStatus = try container.decode(Known<TaskStatus>.self, forKey: .status)
        knownPriority = try container.decode(Known<TaskPriority>.self, forKey: .priority)
        dueAt = try container.decodeIfPresent(Date.self, forKey: .dueAt)
        createdBy = try container.decodeIfPresent(UUID.self, forKey: .createdBy)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        completedAt = try container.decodeIfPresent(Date.self, forKey: .completedAt)
        recurrence = try Self.recurrence(in: container)
        rotation = try container.decodeIfPresent([UUID].self, forKey: .rotation)
        turnUserId = try container.decodeIfPresent(UUID.self, forKey: .turnUserId)
        seriesId = try container.decodeIfPresent(UUID.self, forKey: .seriesId)
        nextOccurrenceId = try container.decodeIfPresent(UUID.self, forKey: .nextOccurrenceId)
        completedBy = try container.decodeIfPresent(UUID.self, forKey: .completedBy)
        assignees = try container.decodeIfPresent([AssigneeRow].self, forKey: .assignees)
        checklist = try container.decodeIfPresent([ChecklistItemRow].self, forKey: .checklist)
        mine = try container.decodeIfPresent([MyAssignmentRow].self, forKey: .mine)
        group = try container.decodeIfPresent(GroupNameRow.self, forKey: .group)
    }

    /// The rule of the `repeat_*` columns: nil when `repeat_freq` is NULL (or absent: a v1 server). A frequency added by
    /// a later version is an unknown enum value (the task can be neither shown nor safely edited: a full edit would
    /// overwrite its rule).
    private static func recurrence(in container: KeyedDecodingContainer<CodingKeys>) throws -> RecurrenceRule? {
        guard let frequency = try container.decodeIfPresent(Known<RecurrenceRule.Frequency>.self, forKey: .repeatFreq)
        else { return nil }
        guard let timeZoneId = try container.decodeIfPresent(String.self, forKey: .repeatTimeZone) else {
            throw DecodingError.dataCorruptedError(
                forKey: .repeatTimeZone, in: container, debugDescription: "repeat_freq without repeat_tz"
            )
        }
        return RecurrenceRule(
            frequency: frequency.value,
            interval: try container.decodeIfPresent(Int.self, forKey: .repeatInterval) ?? 1,
            weekdays: try container.decodeIfPresent([Int].self, forKey: .repeatWeekdays).map(Set.init),
            timeZoneId: timeZoneId,
            monthDay: try container.decodeIfPresent(Int.self, forKey: .repeatMonthDay)
        )
    }

    var status: TaskStatus { knownStatus.value }
    var priority: TaskPriority { knownPriority.value }

    /// The task. `assigneeIds` defaults to the embedded assignees, `checklist` to the embedded items; the assignees are
    /// sorted by `uuidString`, the items with `ChecklistItem.sorted` (reads return both unordered).
    func item(assigneeIds: [UUID]? = nil, checklist items: [ChecklistItem]? = nil) -> TaskItem {
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
            assigneeIds: TaskDTO.sorted(ids),
            recurrence: recurrence,
            rotation: rotation ?? [],
            turnUserId: turnUserId,
            seriesId: seriesId,
            nextOccurrenceId: nextOccurrenceId,
            completedBy: completedBy,
            checklist: ChecklistItem.sorted(items ?? (checklist ?? []).map(\.item))
        )
    }

    /// `myTasks` item: also `myAssignedAt`, `myAssignedBy`, `groupName`, `groupColor` and `groupEmoji`.
    var myTaskItem: TaskItem {
        var task = item()
        task.myAssignedAt = mine?.first?.assignedAt
        task.myAssignedBy = mine?.first?.assignedBy
        task.groupName = group?.name
        task.groupColor = group?.color
        task.groupEmoji = group?.emoji
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

/// `task_assignees?select=task_id,group_id,assigned_by,assigned_at,task:tasks(title,due_at,rotation,group:groups(name))`.
struct AssignmentRow: Decodable, Sendable, Hashable {
    struct EmbeddedTask: Decodable, Sendable, Hashable {
        let title: String
        let dueAt: Date?
        /// v2: not NULL on a task with a rotation.
        let rotation: [UUID]?
        let group: GroupNameRow?

        enum CodingKeys: String, CodingKey {
            case title
            case dueAt = "due_at"
            case rotation
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
            dueAt: task.dueAt,
            taskHasRotation: !(task.rotation ?? []).isEmpty
        )
    }
}

/// `group_activity?select=id,kind,actor_id,subject_id,task_id,task_title,item_title,created_at` (docs/CONTRACTS-V2.md §7).
/// A kind unknown to this client leaves the row out of the list (`Known`).
struct ActivityRow: Decodable, Sendable, Hashable {
    let id: Int64
    private let knownKind: Known<ActivityEvent.Kind>
    let actorId: UUID?
    let subjectId: UUID?
    let taskId: UUID?
    let taskTitle: String?
    let itemTitle: String?
    let createdAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case knownKind = "kind"
        case actorId = "actor_id"
        case subjectId = "subject_id"
        case taskId = "task_id"
        case taskTitle = "task_title"
        case itemTitle = "item_title"
        case createdAt = "created_at"
    }

    var event: ActivityEvent {
        ActivityEvent(
            id: id, kind: knownKind.value, actorId: actorId, subjectId: subjectId, taskId: taskId,
            taskTitle: taskTitle, itemTitle: itemTitle, createdAt: createdAt
        )
    }
}

/// `tasks?select=group_id,status,completed_at` (the groups overview, docs/CONTRACTS-V2.md §10). A status unknown to
/// this client leaves the row out of the list (`Known`): such a task is not counted.
struct OverviewTaskRow: Decodable, Sendable, Hashable {
    let groupId: UUID
    private let knownStatus: Known<TaskStatus>
    let completedAt: Date?

    enum CodingKeys: String, CodingKey {
        case groupId = "group_id"
        case knownStatus = "status"
        case completedAt = "completed_at"
    }

    var state: GroupOverview.TaskState {
        GroupOverview.TaskState(status: knownStatus.value, completedAt: completedAt)
    }
}

/// The `group_id` of any row of a read over several groups: the groups overview pages on it, whatever the row holds
/// (rows with an unknown enum value included).
struct GroupKeyRow: Decodable, Sendable, Hashable {
    let groupId: UUID

    enum CodingKeys: String, CodingKey {
        case groupId = "group_id"
    }
}

/// `tasks?select=id,completed_by,completed_at&status=eq.done` (the weekly recap, docs/CONTRACTS-V2.md §8).
struct CompletionRow: Decodable, Sendable, Hashable {
    let id: UUID
    let completedBy: UUID?
    let completedAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case completedBy = "completed_by"
        case completedAt = "completed_at"
    }

    var completion: TaskCompletion {
        TaskCompletion(taskId: id, completedBy: completedBy, completedAt: completedAt)
    }
}
