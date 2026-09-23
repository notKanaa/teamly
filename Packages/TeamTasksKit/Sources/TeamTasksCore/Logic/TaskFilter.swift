import Foundation

extension TaskItem {
    /// True when the task is not done and its due date is strictly before `now`.
    public func isOverdue(at now: Date) -> Bool {
        guard status != .done, let dueAt else { return false }
        return dueAt < now
    }

    /// True when `userId` is one of the task's assignees.
    public func isAssigned(to userId: UUID) -> Bool {
        assigneeIds.contains(userId)
    }
}

/// Status criterion of a task list ("Toutes", "À faire", "En cours", "Terminées", "Non terminées").
public enum TaskStatusFilter: String, Sendable, Hashable, Codable, CaseIterable, Identifiable {
    case all
    case todo
    case inProgress
    case done
    /// `todo` or `inProgress`.
    case notDone

    public var id: String { rawValue }

    /// French label for pickers.
    public var label: String {
        switch self {
        case .all: "Toutes"
        case .todo: "À faire"
        case .inProgress: "En cours"
        case .done: "Terminées"
        case .notDone: "Non terminées"
        }
    }

    public func matches(_ status: TaskStatus) -> Bool {
        switch self {
        case .all: true
        case .todo: status == .todo
        case .inProgress: status == .inProgress
        case .done: status == .done
        case .notDone: status != .done
        }
    }
}

/// Filter of a task list (group screen, "Mes tâches"). All criteria are combined with AND.
/// Pure value type: `apply` keeps the input order (sort separately with `TaskSort`).
public struct TaskFilter: Sendable, Hashable, Codable {
    public var status: TaskStatusFilter
    /// Only tasks assigned to the current user.
    public var onlyAssignedToMe: Bool
    /// Only overdue tasks (not done, due date in the past).
    public var onlyOverdue: Bool

    /// Shows everything.
    public static let all = TaskFilter()

    public init(status: TaskStatusFilter = .all, onlyAssignedToMe: Bool = false, onlyOverdue: Bool = false) {
        self.status = status
        self.onlyAssignedToMe = onlyAssignedToMe
        self.onlyOverdue = onlyOverdue
    }

    /// Number of criteria that differ from `TaskFilter.all` (for a "Filtres (2)" badge).
    public var activeCriteriaCount: Int {
        (status == .all ? 0 : 1) + (onlyAssignedToMe ? 1 : 0) + (onlyOverdue ? 1 : 0)
    }

    /// True when at least one criterion is set.
    public var isActive: Bool { activeCriteriaCount > 0 }

    /// - Parameters:
    ///   - userId: the current user; when nil, "assigned to me" matches nothing.
    ///   - now: reference date for "overdue".
    public func matches(_ task: TaskItem, userId: UUID?, now: Date) -> Bool {
        guard status.matches(task.status) else { return false }
        if onlyAssignedToMe {
            guard let userId, task.isAssigned(to: userId) else { return false }
        }
        if onlyOverdue, !task.isOverdue(at: now) {
            return false
        }
        return true
    }

    /// Tasks matching the filter, in their original order.
    public func apply(to tasks: [TaskItem], userId: UUID?, now: Date) -> [TaskItem] {
        tasks.filter { matches($0, userId: userId, now: now) }
    }
}
