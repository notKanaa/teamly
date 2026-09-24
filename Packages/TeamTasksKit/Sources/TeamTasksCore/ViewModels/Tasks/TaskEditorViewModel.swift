import Foundation
import Observation

/// A member offered in the assignee picker.
public struct AssigneeOption: Sendable, Hashable, Identifiable {
    public var id: UUID
    /// « Camille Martin (vous) » for the current user.
    public var name: String
    public var role: MemberRole
    public var isMe: Bool
    public var isSelected: Bool

    public init(id: UUID, name: String, role: MemberRole, isMe: Bool, isSelected: Bool) {
        self.id = id
        self.name = name
        self.role = role
        self.isMe = isMe
        self.isSelected = isSelected
    }
}

/// « Nouvelle tâche » / « Modifier la tâche » sheet: title, details, priority, optional due date and assignees
/// (members of the group, at most 20). Fields are validated before calling the service, each with its message.
/// On success `savedTask` is set: dismiss.
///
/// View: `.task { await model.load() }` (loads the members for the picker).
@MainActor
@Observable
public final class TaskEditorViewModel: ErrorPresenting {
    public enum Mode: Sendable, Hashable {
        case create(groupId: UUID)
        case edit(TaskItem)
    }

    public static let maxAssignees = Limits.maxAssignees
    public static let maxTitleLength = Limits.taskTitle.upperBound
    public static let maxDetailsLength = Limits.taskDetailsMax
    public static let invalidDueDateMessage = "Date d’échéance invalide."
    public static let goneMessage = "Cette tâche a été supprimée."
    /// After `assignee_not_member`: the people who left the group were removed from the selection.
    public static let departedAssigneesMessage =
        "Une personne assignée a quitté le groupe\u{00A0}: elle a été retirée. Enregistrez à nouveau."

    public let mode: Mode
    public let groupId: UUID

    public var title: String {
        get { titleValue }
        set {
            titleValue = newValue
            if titleError != nil { titleError = Self.titleMessage(newValue) }
        }
    }

    public var details: String {
        get { detailsValue }
        set {
            detailsValue = newValue
            if detailsError != nil { detailsError = Self.detailsMessage(newValue) }
        }
    }

    public var priority: TaskPriority
    /// « Échéance » toggle. Turning it on keeps the last chosen date (tomorrow 18:00 by default).
    public var hasDueDate: Bool {
        get { hasDueDateValue }
        set {
            hasDueDateValue = newValue
            if !newValue { dueDateError = nil }
        }
    }

    /// Date picker value (used when `hasDueDate`).
    public var dueDate: Date {
        get { dueDateValue }
        set {
            dueDateValue = newValue
            dueDateError = nil
        }
    }

    public private(set) var assigneeIds: Set<UUID>
    /// Members of the group (assignee picker), admins first then by name.
    public private(set) var members: [Membership] = []
    public private(set) var loadState: LoadState = .idle
    public private(set) var titleError: String?
    public private(set) var detailsError: String?
    public private(set) var dueDateError: String?
    public private(set) var assigneesError: String?
    public private(set) var isSaving = false
    public private(set) var savedTask: TaskItem?
    /// Edit mode: the task was deleted meanwhile.
    public private(set) var isGone = false
    public var error: ErrorState?

    public let session: SessionModel
    private var original: TaskDraft
    private var titleValue: String
    private var detailsValue: String
    private var hasDueDateValue: Bool
    private var dueDateValue: Date
    private let runner = LoadRunner()

    /// New task in `groupId`. Pass `members` when already loaded (the picker then needs no request).
    public convenience init(session: SessionModel, groupId: UUID, members: [Membership]? = nil) {
        self.init(session: session, mode: .create(groupId: groupId), members: members)
    }

    /// Full edit of `task` (admin or creator).
    public convenience init(session: SessionModel, task: TaskItem, members: [Membership]? = nil) {
        self.init(session: session, mode: .edit(task), members: members)
    }

    public init(session: SessionModel, mode: Mode, members: [Membership]? = nil) {
        self.session = session
        self.mode = mode
        let draft: TaskDraft
        switch mode {
        case let .create(groupId):
            self.groupId = groupId
            draft = TaskDraft()
        case let .edit(task):
            groupId = task.groupId
            draft = TaskDraft(task: task)
        }
        original = draft
        titleValue = draft.title
        detailsValue = draft.details
        priority = draft.priority
        assigneeIds = draft.assigneeIds
        hasDueDateValue = draft.dueAt != nil
        dueDateValue = draft.dueAt ?? Self.defaultDueDate(now: session.platform.now(), calendar: session.platform.calendar)
        if let members {
            self.members = NameOrder.sortedMembers(members)
            loadState = .loaded
        }
    }

    // MARK: - Loading (members)

    /// Loads the group's members for the picker (once).
    public func load() async {
        guard loadState != .loaded else { return }
        await runner.run(rerunIfRunning: false) { [weak self] in await self?.fetchMembers() }
    }

    public func reload() async {
        await runner.run(rerunIfRunning: true) { [weak self] in await self?.fetchMembers() }
    }

    /// Loads the members and drops from the selection the people who are no longer members: the server refuses
    /// them (`assignee_not_member`) and the picker has no row to unselect them.
    private func fetchMembers() async {
        if loadState != .loaded { loadState = .loading }
        do {
            members = NameOrder.sortedMembers(try await session.services.groups.members(groupId: groupId))
            loadState = .loaded
            let memberIds = Set(members.map(\.user.id))
            assigneeIds.formIntersection(memberIds)
            // Their assignments are gone on the server too: dropping them is not a change of the user.
            original.assigneeIds.formIntersection(memberIds)
        } catch {
            guard let state = ErrorState(from: error) else {
                if loadState == .loading { loadState = .idle }
                return
            }
            if loadState == .loaded {
                self.error = state
            } else {
                loadState = .failed(state.message)
            }
        }
    }

    // MARK: - Display

    public var isEditing: Bool {
        if case .edit = mode { return true }
        return false
    }

    public var navigationTitle: String { isEditing ? "Modifier la tâche" : "Nouvelle tâche" }
    public var saveButtonTitle: String { isEditing ? "Enregistrer" : "Créer" }

    /// The draft sent to the service.
    public var draft: TaskDraft {
        TaskDraft(
            title: titleValue,
            details: detailsValue,
            priority: priority,
            dueAt: hasDueDateValue ? dueDateValue : nil,
            assigneeIds: assigneeIds
        )
    }

    /// Something differs from the initial values (ask before discarding).
    public var hasChanges: Bool { draft != originalComparable }

    private var originalComparable: TaskDraft {
        var value = original
        // A create form with the toggle off has no due date whatever the picker shows.
        if !isEditing { value.dueAt = nil }
        return value
    }

    /// The current user's role in the group (from the members), nil when not a member.
    public var myRole: MemberRole? {
        members.first { $0.user.id == session.userId }?.role
    }

    /// Edit mode: whether the user may edit this task (admin or creator). Always true for a new task of a member.
    public var canEdit: Bool {
        switch mode {
        case .create:
            return loadState != .loaded || TaskPermissions.canCreate(role: myRole)
        case let .edit(task):
            return loadState != .loaded || TaskPermissions.canEdit(task, userId: session.userId, role: myRole)
        }
    }

    public var canSave: Bool { !InputValidation.trimmed(titleValue).isEmpty && !isSaving && canEdit }

    public var assigneeOptions: [AssigneeOption] {
        members.map { member in
            let isMe = member.user.id == session.userId
            return AssigneeOption(
                id: member.user.id,
                name: isMe ? "\(member.user.displayName) (vous)" : member.user.displayName,
                role: member.role,
                isMe: isMe,
                isSelected: assigneeIds.contains(member.user.id)
            )
        }
    }

    /// 20 people are already assigned: others cannot be added.
    public var assigneeLimitReached: Bool { assigneeIds.count >= Self.maxAssignees }

    /// « Vous, Lucas Bernard » / « Non assignée ».
    public var assigneesSummary: String {
        MemberDirectory(members: members, currentUserId: session.userId).assigneesText(Array(assigneeIds))
    }

    public func isAssigned(_ userId: UUID) -> Bool { assigneeIds.contains(userId) }

    /// Adds or removes an assignee. Adding beyond 20 is refused with `assigneesError`.
    public func toggleAssignee(_ userId: UUID) {
        if assigneeIds.contains(userId) {
            assigneeIds.remove(userId)
            if assigneeIds.count <= Self.maxAssignees { assigneesError = nil }
        } else if assigneeLimitReached {
            assigneesError = AppError.tooManyAssignees.messageFR
        } else {
            assigneeIds.insert(userId)
            assigneesError = nil
        }
    }

    // MARK: - Save

    /// Checks every field (same order as the server) and sets their messages. Returns true when valid.
    @discardableResult
    public func validate() -> Bool {
        titleError = Self.titleMessage(titleValue)
        detailsError = Self.detailsMessage(detailsValue)
        dueDateError = nil
        if hasDueDateValue, (try? InputValidation.dueDate(dueDateValue)) == nil {
            dueDateError = Self.invalidDueDateMessage
        }
        assigneesError = assigneeIds.count > Self.maxAssignees ? AppError.tooManyAssignees.messageFR : nil
        return titleError == nil && detailsError == nil && dueDateError == nil && assigneesError == nil
    }

    /// Creates or updates the task. Returns it on success (`savedTask`), nil otherwise.
    @discardableResult
    public func save() async -> TaskItem? {
        guard !isSaving else { return nil }
        error = nil
        guard canEdit else {
            present(AppError.forbidden)
            return nil
        }
        guard validate() else { return nil }
        isSaving = true
        defer { isSaving = false }
        let draft = self.draft
        do {
            let task: TaskItem
            switch mode {
            case let .create(groupId):
                task = try await session.services.tasks.create(groupId: groupId, draft: draft)
            case let .edit(existing):
                task = try await session.services.tasks.update(taskId: existing.id, draft: draft)
            }
            savedTask = task
            session.feed.bump(groupId: groupId)
            session.feed.bumpMyTasks()
            return task
        } catch {
            guard let appError = ErrorState(from: error)?.error else { return nil }
            switch appError {
            case .invalidTitle:
                titleError = appError.messageFR
            case .invalidDetails:
                detailsError = appError.messageFR
            case .tooManyAssignees, .assigneeNotMember:
                assigneesError = appError.messageFR
                if appError == .assigneeNotMember {
                    let selected = assigneeIds
                    await reload()
                    if assigneeIds != selected {
                        // The people who left were dropped: saving again works.
                        assigneesError = Self.departedAssigneesMessage
                    }
                }
            case .notFound where isEditing:
                isGone = true
                present(message: Self.goneMessage, error: .notFound)
            default:
                present(appError)
            }
            return nil
        }
    }

    // MARK: - Rules

    public static func titleMessage(_ title: String) -> String? {
        (try? InputValidation.taskTitle(title)) == nil ? AppError.invalidTitle.messageFR : nil
    }

    public static func detailsMessage(_ details: String) -> String? {
        do {
            _ = try InputValidation.taskDetails(details)
            return nil
        } catch {
            return AppError.invalidDetails.messageFR
        }
    }

    /// Tomorrow at 18:00 in `calendar`'s time zone.
    public static func defaultDueDate(now: Date, calendar: Calendar) -> Date {
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)) ?? now
        return calendar.date(bySettingHour: 18, minute: 0, second: 0, of: tomorrow) ?? tomorrow
    }
}
