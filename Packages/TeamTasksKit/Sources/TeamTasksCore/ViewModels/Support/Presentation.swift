import Foundation

// French labels and ready-to-display values shared by the view models, so that every screen words things the
// same way. `systemImage` values are SF Symbols names.

extension TaskStatus {
    /// « À faire », « En cours », « Terminée ».
    public var label: String {
        switch self {
        case .todo: "À faire"
        case .inProgress: "En cours"
        case .done: "Terminée"
        }
    }

    public var systemImage: String {
        switch self {
        case .todo: "circle"
        case .inProgress: "circle.lefthalf.filled"
        case .done: "checkmark.circle.fill"
        }
    }

    /// Next status of a one-tap cycle: à faire → en cours → terminée → à faire.
    public var next: TaskStatus {
        switch self {
        case .todo: .inProgress
        case .inProgress: .done
        case .done: .todo
        }
    }
}

extension TaskPriority {
    /// « Basse », « Moyenne », « Haute ».
    public var label: String {
        switch self {
        case .low: "Basse"
        case .medium: "Moyenne"
        case .high: "Haute"
        }
    }

    public var systemImage: String {
        switch self {
        case .low: "arrow.down"
        case .medium: "minus"
        case .high: "exclamationmark"
        }
    }

    /// Picker order: high first.
    public static let pickerOrder: [TaskPriority] = [.high, .medium, .low]
}

extension MemberRole {
    /// « Admin », « Membre ».
    public var label: String {
        switch self {
        case .admin: "Admin"
        case .member: "Membre"
        }
    }
}

/// Date wording of the screens (French, relative to a reference date, in the injected calendar's time zone).
public enum DateText {
    /// « Aujourd'hui à 20:00 », « Demain à 18:00 », « Hier à 09:30 », « Lundi 28 septembre à 18:00 ».
    public static func relative(_ date: Date, now: Date, calendar: Calendar) -> String {
        let formatter = FrenchDateFormatter(timeZone: calendar.timeZone)
        return FrenchDateFormatter.capitalizingFirstLetter(formatter.relativeDateTime(date, relativeTo: now))
    }

    /// Same wording in lowercase, to be embedded in a sentence (« créée hier à 09:30 »).
    public static func relativeLowercase(_ date: Date, now: Date, calendar: Calendar) -> String {
        FrenchDateFormatter(timeZone: calendar.timeZone).relativeDateTime(date, relativeTo: now)
    }
}

/// Display names of a group's members, as seen by the current user.
public struct MemberDirectory: Sendable, Hashable {
    /// Shown for a user who is no longer a member (or a deleted account).
    public static let formerMemberName = "Ancien membre"
    /// Shown instead of the current user's own name in lists of people.
    public static let meName = "Vous"
    /// Assignee text of a task without assignees.
    public static let unassignedText = "Non assignée"

    public var members: [Membership]
    public var currentUserId: UUID

    public init(members: [Membership], currentUserId: UUID) {
        self.members = members
        self.currentUserId = currentUserId
    }

    /// The current user's role, nil when not a member.
    public var myRole: MemberRole? { role(of: currentUserId) }

    public func role(of userId: UUID) -> MemberRole? {
        members.first { $0.user.id == userId }?.role
    }

    /// Display name of a member, « Ancien membre » when unknown or nil.
    public func name(of userId: UUID?) -> String {
        guard let userId, let member = members.first(where: { $0.user.id == userId }) else {
            return Self.formerMemberName
        }
        return member.user.displayName
    }

    /// Names of `userIds` for a list: « Vous » first, then the others in name order (`NameOrder`).
    public func names(of userIds: [UUID]) -> [String] {
        var includesMe = false
        var others: [String] = []
        for userId in Set(userIds) {
            if userId == currentUserId {
                includesMe = true
            } else {
                others.append(name(of: userId))
            }
        }
        others.sort { NameOrder.precedes($0, $1) ?? false }
        return (includesMe ? [Self.meName] : []) + others
    }

    /// « Vous, Lucas Bernard », or « Non assignée ».
    public func assigneesText(_ userIds: [UUID]) -> String {
        let names = names(of: userIds)
        return names.isEmpty ? Self.unassignedText : names.joined(separator: ", ")
    }
}

/// One row of a task list, ready to display.
public struct TaskRow: Sendable, Hashable, Identifiable {
    public var task: TaskItem
    /// « Aujourd'hui à 20:00 », nil without due date.
    public var dueText: String?
    /// Not done and due in the past (show the due text in red).
    public var isOverdue: Bool
    /// « Vous, Lucas Bernard » / « Non assignée »; nil on screens that do not show assignees (« Mes tâches »).
    public var assigneesText: String?
    /// Group name, filled on « Mes tâches » only.
    public var groupName: String?
    /// « Nouveau » badge (« Mes tâches » only).
    public var isNew: Bool
    public var canChangeStatus: Bool
    public var canEdit: Bool
    public var canDelete: Bool

    public var id: UUID { task.id }
    public var title: String { task.title }
    public var status: TaskStatus { task.status }
    public var priority: TaskPriority { task.priority }
    public var isDone: Bool { task.status == .done }

    public init(
        task: TaskItem,
        dueText: String?,
        isOverdue: Bool,
        assigneesText: String?,
        groupName: String?,
        isNew: Bool,
        canChangeStatus: Bool,
        canEdit: Bool,
        canDelete: Bool
    ) {
        self.task = task
        self.dueText = dueText
        self.isOverdue = isOverdue
        self.assigneesText = assigneesText
        self.groupName = groupName
        self.isNew = isNew
        self.canChangeStatus = canChangeStatus
        self.canEdit = canEdit
        self.canDelete = canDelete
    }
}

/// A filter chip of a task list (« Toutes », « À faire », « En cours », « Terminées », « Assignées à moi »,
/// « En retard »).
public struct TaskFilterChip: Sendable, Hashable, Identifiable {
    public enum Kind: Sendable, Hashable {
        /// Mutually exclusive status choice (`.all` resets the status criterion).
        case status(TaskStatusFilter)
        case assignedToMe
        case overdue
    }

    public var kind: Kind
    public var label: String
    public var isSelected: Bool

    public var id: Kind { kind }

    public init(kind: Kind, label: String, isSelected: Bool) {
        self.kind = kind
        self.label = label
        self.isSelected = isSelected
    }

    /// Status choices offered as chips, in display order.
    public static let statusChoices: [TaskStatusFilter] = [.all, .todo, .inProgress, .done]

    /// The chips describing `filter`.
    public static func chips(for filter: TaskFilter) -> [TaskFilterChip] {
        statusChoices.map { TaskFilterChip(kind: .status($0), label: $0.label, isSelected: filter.status == $0) } + [
            TaskFilterChip(kind: .assignedToMe, label: "Assignées à moi", isSelected: filter.onlyAssignedToMe),
            TaskFilterChip(kind: .overdue, label: "En retard", isSelected: filter.onlyOverdue),
        ]
    }

    /// `filter` after a tap on the chip `kind`: a status chip selects its status (tapping the selected status
    /// again goes back to « Toutes »); the other chips toggle.
    public static func toggling(_ kind: Kind, in filter: TaskFilter) -> TaskFilter {
        var filter = filter
        switch kind {
        case let .status(status):
            filter.status = (filter.status == status && status != .all) ? .all : status
        case .assignedToMe:
            filter.onlyAssignedToMe.toggle()
        case .overdue:
            filter.onlyOverdue.toggle()
        }
        return filter
    }
}
