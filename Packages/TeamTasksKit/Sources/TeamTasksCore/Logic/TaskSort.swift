import Foundation

/// Sort orders of a task list. Every order is total and deterministic; tasks that compare equal on
/// every criterion keep their input order (stable sort).
public enum TaskSort: String, Sendable, Hashable, Codable, CaseIterable, Identifiable {
    /// Due date ascending (tasks without due date last), then priority (high first), then title.
    case dueDate
    /// Priority (high first), then due date ascending (none last), then title.
    case priority
    /// Most recently created first, then title.
    case recentlyCreated

    public var id: String { rawValue }

    /// French label for pickers.
    public var label: String {
        switch self {
        case .dueDate: "Échéance"
        case .priority: "Priorité"
        case .recentlyCreated: "Plus récentes"
        }
    }

    /// Returns the tasks sorted in this order (stable).
    public func sorted(_ tasks: [TaskItem]) -> [TaskItem] {
        let keyed = tasks.enumerated().map { offset, task in
            (offset: offset, task: task, title: TaskSort.titleKey(task.title))
        }
        return keyed.sorted { lhs, rhs in
            switch compare(lhs.task, lhs.title, rhs.task, rhs.title) {
            case .orderedAscending: true
            case .orderedDescending: false
            case .orderedSame: lhs.offset < rhs.offset
            }
        }.map { $0.task }
    }

    /// Strict ordering predicate (false for tasks that compare equal), usable with `sort(by:)`.
    /// Prefer `sorted(_:)`, which is stable and computes each title key once.
    public func areInIncreasingOrder(_ lhs: TaskItem, _ rhs: TaskItem) -> Bool {
        compare(lhs, TaskSort.titleKey(lhs.title), rhs, TaskSort.titleKey(rhs.title)) == .orderedAscending
    }

    // MARK: - Criteria

    private func compare(_ lhs: TaskItem, _ lhsTitle: String, _ rhs: TaskItem, _ rhsTitle: String) -> ComparisonResult {
        let criteria: [ComparisonResult]
        switch self {
        case .dueDate:
            criteria = [
                TaskSort.compareDue(lhs.dueAt, rhs.dueAt),
                TaskSort.compareDescending(lhs.priority.rank, rhs.priority.rank),
                TaskSort.compareAscending(lhsTitle, rhsTitle),
                TaskSort.compareAscending(lhs.title, rhs.title),
            ]
        case .priority:
            criteria = [
                TaskSort.compareDescending(lhs.priority.rank, rhs.priority.rank),
                TaskSort.compareDue(lhs.dueAt, rhs.dueAt),
                TaskSort.compareAscending(lhsTitle, rhsTitle),
                TaskSort.compareAscending(lhs.title, rhs.title),
            ]
        case .recentlyCreated:
            criteria = [
                TaskSort.compareDescending(lhs.createdAt, rhs.createdAt),
                TaskSort.compareAscending(lhsTitle, rhsTitle),
                TaskSort.compareAscending(lhs.title, rhs.title),
            ]
        }
        return criteria.first { $0 != .orderedSame } ?? .orderedSame
    }

    /// Case-, accent- and width-insensitive key so that "éclairage" sorts between "eau" and "fenêtre".
    static func titleKey(_ title: String) -> String {
        title.folding(
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
            locale: Locale(identifier: "fr_FR")
        )
    }

    /// Ascending due date, nil last.
    static func compareDue(_ lhs: Date?, _ rhs: Date?) -> ComparisonResult {
        switch (lhs, rhs) {
        case (nil, nil): .orderedSame
        case (nil, _): .orderedDescending
        case (_, nil): .orderedAscending
        case let (lhs?, rhs?): compareAscending(lhs, rhs)
        }
    }

    static func compareAscending<T: Comparable>(_ lhs: T, _ rhs: T) -> ComparisonResult {
        lhs < rhs ? .orderedAscending : (rhs < lhs ? .orderedDescending : .orderedSame)
    }

    static func compareDescending<T: Comparable>(_ lhs: T, _ rhs: T) -> ComparisonResult {
        compareAscending(rhs, lhs)
    }
}
