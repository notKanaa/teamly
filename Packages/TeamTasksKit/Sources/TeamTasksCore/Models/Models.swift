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

    public init(id: UUID, displayName: String) {
        self.id = id
        self.displayName = displayName
    }
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

    public init(id: UUID, name: String, createdBy: UUID?, createdAt: Date, lastActivityAt: Date) {
        self.id = id
        self.name = name
        self.createdBy = createdBy
        self.createdAt = createdAt
        self.lastActivityAt = lastActivityAt
    }
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
        myAssignedBy: UUID? = nil
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
    }
}

/// Editable fields of a task (create / full edit). Status is changed separately with `TaskService.setStatus`.
public struct TaskDraft: Sendable, Hashable {
    public var title: String
    public var details: String
    public var priority: TaskPriority
    public var dueAt: Date?
    public var assigneeIds: Set<UUID>

    public init(
        title: String = "",
        details: String = "",
        priority: TaskPriority = .medium,
        dueAt: Date? = nil,
        assigneeIds: Set<UUID> = []
    ) {
        self.title = title
        self.details = details
        self.priority = priority
        self.dueAt = dueAt
        self.assigneeIds = assigneeIds
    }

    public init(task: TaskItem) {
        self.init(
            title: task.title,
            details: task.details ?? "",
            priority: task.priority,
            dueAt: task.dueAt,
            assigneeIds: Set(task.assigneeIds)
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

    public var id: UUID { taskId }

    public init(
        taskId: UUID,
        groupId: UUID,
        taskTitle: String,
        groupName: String,
        assignedBy: UUID?,
        assignedAt: Date,
        dueAt: Date?
    ) {
        self.taskId = taskId
        self.groupId = groupId
        self.taskTitle = taskTitle
        self.groupName = groupName
        self.assignedBy = assignedBy
        self.assignedAt = assignedAt
        self.dueAt = dueAt
    }
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
