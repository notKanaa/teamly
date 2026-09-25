import Foundation

// MARK: - Users

/// Authenticated account (from Supabase Auth).
public struct AuthUser: Sendable, Hashable, Identifiable {
    public var id: UUID
    public var email: String?

    public init(id: UUID, email: String?) {
        self.id = id
        self.email = email
    }
}

/// Public profile visible to co-members (`public.profiles`).
public struct UserProfile: Sendable, Hashable, Identifiable {
    public var id: UUID
    public var displayName: String
    /// v2: avatar color; nil = automatic (`resolvedColor`).
    public var avatarColor: ColorKey?
    /// v2: avatar emoji (normalized, see `InputValidation.emoji(_:)`); nil = the initials.
    public var avatarEmoji: String?
    /// v2: when the user finished or skipped the onboarding; nil = not yet (`OnboardingPolicy`).
    /// Only read by `ProfileService.myProfile()` (nil in the members list).
    public var onboardedAt: Date?
    /// v2: when the account was created. Only read by `ProfileService.myProfile()` (nil in the members list).
    public var createdAt: Date?

    public init(
        id: UUID,
        displayName: String,
        avatarColor: ColorKey? = nil,
        avatarEmoji: String? = nil,
        onboardedAt: Date? = nil,
        createdAt: Date? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.avatarColor = avatarColor
        self.avatarEmoji = avatarEmoji
        self.onboardedAt = onboardedAt
        self.createdAt = createdAt
    }

    /// The avatar color to show: `avatarColor`, or the automatic color of the user id.
    public var resolvedColor: ColorKey { ColorKey.resolved(avatarColor, for: id) }
}

// MARK: - Groups

public enum MemberRole: String, Sendable, Hashable, Codable, CaseIterable {
    case admin
    case member
}

/// A group of people sharing tasks (`public.groups`).
/// Named `TeamGroup` to avoid clashing with SwiftUI's `Group`.
public struct TeamGroup: Sendable, Hashable, Identifiable {
    public var id: UUID
    public var name: String
    public var createdBy: UUID?
    public var createdAt: Date
    public var lastActivityAt: Date
    /// v2: the group's color; nil = automatic (`resolvedColor`).
    public var color: ColorKey?
    /// v2: the group's emoji (normalized, see `InputValidation.emoji(_:)`); nil = none (the initials are shown).
    public var emoji: String?

    public init(
        id: UUID,
        name: String,
        createdBy: UUID?,
        createdAt: Date,
        lastActivityAt: Date,
        color: ColorKey? = nil,
        emoji: String? = nil
    ) {
        self.id = id
        self.name = name
        self.createdBy = createdBy
        self.createdAt = createdAt
        self.lastActivityAt = lastActivityAt
        self.color = color
        self.emoji = emoji
    }

    /// The color to show: `color`, or the automatic color of the group id.
    public var resolvedColor: ColorKey { ColorKey.resolved(color, for: id) }
}

/// A group as seen by the current user, with their role in it.
public struct GroupSummary: Sendable, Hashable, Identifiable {
    public var group: TeamGroup
    public var myRole: MemberRole

    public var id: UUID { group.id }

    public init(group: TeamGroup, myRole: MemberRole) {
        self.group = group
        self.myRole = myRole
    }
}

/// A member of a group (`public.group_members` joined with `public.profiles`).
public struct Membership: Sendable, Hashable, Identifiable {
    public var groupId: UUID
    public var user: UserProfile
    public var role: MemberRole
    public var joinedAt: Date

    public var id: UUID { user.id }

    public init(groupId: UUID, user: UserProfile, role: MemberRole, joinedAt: Date) {
        self.groupId = groupId
        self.user = user
        self.role = role
        self.joinedAt = joinedAt
    }
}

/// Result of joining a group with an invite code. An invalid code throws `AppError.invalidCode`.
public struct JoinResult: Sendable, Hashable {
    public var groupId: UUID
    public var groupName: String
    public var alreadyMember: Bool

    public init(groupId: UUID, groupName: String, alreadyMember: Bool) {
        self.groupId = groupId
        self.groupName = groupName
        self.alreadyMember = alreadyMember
    }
}

// MARK: - Tasks

public enum TaskStatus: String, Sendable, Hashable, Codable, CaseIterable {
    case todo
    case inProgress = "in_progress"
    case done
}

public enum TaskPriority: String, Sendable, Hashable, Codable, CaseIterable, Comparable {
    case low
    case medium
    case high

    public var rank: Int {
        switch self {
        case .low: 0
        case .medium: 1
        case .high: 2
        }
    }

    public static func < (lhs: TaskPriority, rhs: TaskPriority) -> Bool { lhs.rank < rhs.rank }
}

/// A task of a group (`public.tasks` + its assignees).
/// Named `TaskItem` to avoid clashing with Swift Concurrency's `Task`.
public struct TaskItem: Sendable, Hashable, Identifiable {
    public var id: UUID
    public var groupId: UUID
    public var title: String
    public var details: String?
    public var status: TaskStatus
    public var priority: TaskPriority
    public var dueAt: Date?
    public var createdBy: UUID?
    public var createdAt: Date
    public var updatedAt: Date
    public var completedAt: Date?
    /// Sorted user ids of the assignees.
    public var assigneeIds: [UUID]
    /// Only filled by `TaskService.myTasks`: when the current user was assigned (drives the "Nouveau" badge).
    public var myAssignedAt: Date?
    /// Only filled by `TaskService.myTasks`: who assigned the current user (nil: a deleted account, or not a
    /// `myTasks` item). A self-assignment is never "Nouveau".
    public var myAssignedBy: UUID?
    /// Only filled by `TaskService.myTasks`: the group's name, for display outside the group screen.
    public var groupName: String?
    /// v2: the repetition rule, with the `monthDay` stored by the server; nil = a plain task.
    public var recurrence: RecurrenceRule?
    /// v2: « À tour de rôle »: 2–20 user ids in turn order, only on a recurring task; empty = no rotation. It may
    /// still list people who left the group: the next occurrence drops them.
    public var rotation: [UUID]
    /// v2: whose turn this occurrence is (an element of `rotation`, a member, and its only assignee); nil without a
    /// rotation. When the turn holder leaves the group, the server hands a pending occurrence over to the next member
    /// (`RotationHandover`). A done occurrence keeps it (nil once that account is deleted).
    public var turnUserId: UUID?
    /// v2: id of the first occurrence of the series; nil for a plain task.
    public var seriesId: UUID?
    /// v2: the occurrence created when this one was completed (it may have been deleted since); nil before.
    public var nextOccurrenceId: UUID?
    /// v2: who completed the task; nil unless done, or when unknown (a deleted account, a trusted context).
    public var completedBy: UUID?
    /// v2: the checklist, in display order (`ChecklistItem.sorted(_:)`).
    public var checklist: [ChecklistItem]
    /// v2, only filled by `TaskService.myTasks`: the group's color (nil = automatic:
    /// `ColorKey.resolved(groupColor, for: groupId)`).
    public var groupColor: ColorKey?
    /// v2, only filled by `TaskService.myTasks`: the group's emoji.
    public var groupEmoji: String?

    public init(
        id: UUID,
        groupId: UUID,
        title: String,
        details: String? = nil,
        status: TaskStatus = .todo,
        priority: TaskPriority = .medium,
        dueAt: Date? = nil,
        createdBy: UUID?,
        createdAt: Date,
        updatedAt: Date,
        completedAt: Date? = nil,
        assigneeIds: [UUID] = [],
        myAssignedAt: Date? = nil,
        groupName: String? = nil,
        myAssignedBy: UUID? = nil,
        recurrence: RecurrenceRule? = nil,
        rotation: [UUID] = [],
        turnUserId: UUID? = nil,
        seriesId: UUID? = nil,
        nextOccurrenceId: UUID? = nil,
        completedBy: UUID? = nil,
        checklist: [ChecklistItem] = [],
        groupColor: ColorKey? = nil,
        groupEmoji: String? = nil
    ) {
        self.id = id
        self.groupId = groupId
        self.title = title
        self.details = details
        self.status = status
        self.priority = priority
        self.dueAt = dueAt
        self.createdBy = createdBy
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.completedAt = completedAt
        self.assigneeIds = assigneeIds
        self.myAssignedAt = myAssignedAt
        self.myAssignedBy = myAssignedBy
        self.groupName = groupName
        self.recurrence = recurrence
        self.rotation = rotation
        self.turnUserId = turnUserId
        self.seriesId = seriesId
        self.nextOccurrenceId = nextOccurrenceId
        self.completedBy = completedBy
        self.checklist = checklist
        self.groupColor = groupColor
        self.groupEmoji = groupEmoji
    }

    /// v2: the task repeats (`recurrence` is set).
    public var isRecurring: Bool { recurrence != nil }

    /// v2: the task is done « à tour de rôle » (`rotation` is not empty).
    public var hasRotation: Bool { !rotation.isEmpty }
}

/// Editable fields of a task (create / full edit). Status is changed separately with `TaskService.setStatus`.
///
/// v2: an update is a full edit of the recurrence and the rotation too (nil / empty remove them), so an edit must
/// start from `init(task:)`, which copies them. The checklist of an existing task is edited item by item.
public struct TaskDraft: Sendable, Hashable {
    public var title: String
    public var details: String
    public var priority: TaskPriority
    public var dueAt: Date?
    /// Ignored while the task has a rotation (its only assignee is the turn holder).
    public var assigneeIds: Set<UUID>
    /// v2: the repetition rule (it needs `dueAt`); nil = the task does not repeat. An update with nil removes the rule
    /// and the rotation (the occurrence becomes a plain task).
    public var recurrence: RecurrenceRule?
    /// v2: « À tour de rôle », in turn order: 2–20 distinct members, with a `recurrence`; empty = no rotation. The
    /// turn holder is the only assignee: the first one on create; on update the current turn holder when still
    /// listed, else the first one. An update with the task's own list keeps it as is (not checked again), even when
    /// someone listed has left the group since.
    public var rotation: [UUID]
    /// v2, `TaskService.create` only: the titles of the initial checklist items, in order (at most
    /// `Limits.checklistItemsMax`). `TaskService.update` ignores it.
    public var checklist: [String]

    public init(
        title: String = "",
        details: String = "",
        priority: TaskPriority = .medium,
        dueAt: Date? = nil,
        assigneeIds: Set<UUID> = [],
        recurrence: RecurrenceRule? = nil,
        rotation: [UUID] = [],
        checklist: [String] = []
    ) {
        self.title = title
        self.details = details
        self.priority = priority
        self.dueAt = dueAt
        self.assigneeIds = assigneeIds
        self.recurrence = recurrence
        self.rotation = rotation
        self.checklist = checklist
    }

    /// The draft of a full edit of `task`: its fields, assignees, recurrence and rotation (`checklist` stays empty).
    public init(task: TaskItem) {
        self.init(
            title: task.title,
            details: task.details ?? "",
            priority: task.priority,
            dueAt: task.dueAt,
            assigneeIds: Set(task.assigneeIds),
            recurrence: task.recurrence,
            rotation: task.rotation
        )
    }
}

/// "A task was assigned to me" — used for notifications and catch-up after background/offline periods.
public struct AssignmentEvent: Sendable, Hashable, Identifiable {
    public var taskId: UUID
    public var groupId: UUID
    public var taskTitle: String
    public var groupName: String
    public var assignedBy: UUID?
    public var assignedAt: Date
    public var dueAt: Date?
    /// v2: the task has a rotation (`task:tasks(…,rotation,…)` is not NULL).
    public var taskHasRotation: Bool

    public var id: UUID { taskId }

    public init(
        taskId: UUID,
        groupId: UUID,
        taskTitle: String,
        groupName: String,
        assignedBy: UUID?,
        assignedAt: Date,
        dueAt: Date?,
        taskHasRotation: Bool = false
    ) {
        self.taskId = taskId
        self.groupId = groupId
        self.taskTitle = taskTitle
        self.groupName = groupName
        self.assignedBy = assignedBy
        self.assignedAt = assignedAt
        self.dueAt = dueAt
        self.taskHasRotation = taskHasRotation
    }

    /// v2: a turn handed out by the server (a spawn, or a handover when the turn holder left): `assignedBy` nil on a
    /// task with a rotation (docs/CONTRACTS-V2.md §11). Worded « C’est ton tour ».
    public var isRotationTurn: Bool { assignedBy == nil && taskHasRotation }
}

// MARK: - Auth

public enum AuthState: Sendable, Hashable {
    /// Session not yet restored (splash screen).
    case unknown
    case signedOut
    case signedIn(AuthUser)

    public var user: AuthUser? {
        if case let .signedIn(user) = self { return user }
        return nil
    }
}

public enum SignUpOutcome: Sendable, Hashable {
    /// Account created and session opened.
    case signedIn
    /// Account created but the project requires e-mail confirmation first.
    case confirmationRequired
}

// MARK: - Realtime

public enum RealtimeEvent: Sendable, Hashable {
    /// Channel (re)connected: anything may have been missed, reload everything.
    case connected
    /// Something changed in this group (tasks, assignees, members or the group itself).
    case groupActivity(groupId: UUID)
    /// The current user's memberships changed (joined, left, removed, role changed, group deleted).
    case membershipsChanged
    /// A task was assigned to the current user.
    case assigned(taskId: UUID, groupId: UUID, assignedBy: UUID?)
}
