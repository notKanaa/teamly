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
    /// « Aujourd'hui à 20:00 », « Demain à 18:00 », « Hier à 09:30 », « Lundi à 18:00 » (2 to 6 days ahead),
    /// « Jeudi 1er octobre à 18:00 ».
    public static func relative(_ date: Date, now: Date, calendar: Calendar) -> String {
        let formatter = FrenchDateFormatter(timeZone: calendar.timeZone)
        return FrenchDateFormatter.capitalizingFirstLetter(formatter.relativeDateTime(date, relativeTo: now))
    }

    /// Same wording in lowercase, after a label (« Dernière activité : hier à 09:30 »).
    public static func relativeLowercase(_ date: Date, now: Date, calendar: Calendar) -> String {
        FrenchDateFormatter(timeZone: calendar.timeZone).relativeDateTime(date, relativeTo: now)
    }

    /// Wording for the middle of a sentence: « hier à 09:30 », « le lundi 14 septembre à 10:00 »
    /// (« Créée par Lucas Bernard le lundi 14 septembre à 10:00 »).
    public static func relativeInSentence(_ date: Date, now: Date, calendar: Calendar) -> String {
        FrenchDateFormatter(timeZone: calendar.timeZone).relativeDateTimeInSentence(date, relativeTo: now)
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
    /// v2, group screen: the assignees as badges, the current user first, then by name; empty elsewhere.
    public var assignees: [PersonBadge]
    /// v2: a pending occurrence of a rotating task whose turn is the current user's (`myTurnLabel`).
    public var isMyTurn: Bool

    /// « À tour de rôle », shown on rotating tasks (`hasRotation`).
    public static let rotationLabel = "À tour de rôle"
    /// « Ton tour », shown when `isMyTurn`.
    public static let myTurnLabel = "Ton tour"

    public var id: UUID { task.id }
    public var title: String { task.title }
    public var status: TaskStatus { task.status }
    public var priority: TaskPriority { task.priority }
    public var isDone: Bool { task.status == .done }

    /// v2: « Chaque semaine », « Tous les 2 jours » (`RecurrenceText.summary`), nil for a plain task.
    public var recurrenceText: String? { task.recurrence.map(RecurrenceText.summary) }
    /// v2: the task is done « à tour de rôle » (`rotationLabel`).
    public var hasRotation: Bool { task.hasRotation }
    /// v2: the checklist's progress (« 2/5 »), nil without checklist.
    public var checklistProgress: ChecklistProgress? { ChecklistProgress(task.checklist) }
    /// v2, « Mes tâches »: the group's badge (resolved color, emoji or initials).
    public var groupAppearance: AvatarAppearance? { groupName == nil ? nil : task.groupAppearance }
    /// v2, « Mes tâches »: the group's short name for its chip (« Coloc’ », `GroupShortName`).
    public var groupShortName: String? { groupName.map(GroupShortName.of) }

    public init(
        task: TaskItem,
        dueText: String?,
        isOverdue: Bool,
        assigneesText: String?,
        groupName: String?,
        isNew: Bool,
        canChangeStatus: Bool,
        canEdit: Bool,
        canDelete: Bool,
        assignees: [PersonBadge] = [],
        isMyTurn: Bool = false
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
        self.assignees = assignees
        self.isMyTurn = isMyTurn
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
    /// v2, status chips of the group screen: the number of tasks this chip shows (the other criteria applied).
    public var count: Int?

    public var id: Kind { kind }

    /// « À faire · 4 » with a count, the label otherwise.
    public var countedLabel: String {
        count.map { "\(label) · \($0)" } ?? label
    }

    public init(kind: Kind, label: String, isSelected: Bool, count: Int? = nil) {
        self.kind = kind
        self.label = label
        self.isSelected = isSelected
        self.count = count
    }

    /// Status choices offered as chips, in display order.
    public static let statusChoices: [TaskStatusFilter] = [.all, .todo, .inProgress, .done]

    /// The chips describing `filter`.
    public static func chips(for filter: TaskFilter) -> [TaskFilterChip] {
        chips(for: filter, counts: [:])
    }

    /// v2: the chips describing `filter`, each status chip with its count from `counts` when present.
    public static func chips(for filter: TaskFilter, counts: [TaskStatusFilter: Int]) -> [TaskFilterChip] {
        statusChoices.map { status in
            TaskFilterChip(kind: .status(status), label: status.label, isSelected: filter.status == status, count: counts[status])
        } + [
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
