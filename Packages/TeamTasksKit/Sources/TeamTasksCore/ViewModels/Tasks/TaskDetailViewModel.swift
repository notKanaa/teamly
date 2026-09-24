import Foundation
import Observation

/// Task screen: fields, assignee and creator names, status change (admin, creator, assignee), edit and delete
/// (admin, creator).
///
/// Reloads when the group's revision changes. View: `.task(id: model.refreshKey) { await model.load() }`;
/// dismiss when `isGone` becomes true (deleted here or elsewhere, or no longer visible).
@MainActor
@Observable
public final class TaskDetailViewModel: ErrorPresenting {
    public static let goneMessage = "Cette tâche n’existe plus."

    public let groupId: UUID
    public let taskId: UUID
    public private(set) var task: TaskItem?
    public private(set) var members: [Membership] = []
    public private(set) var loadState: LoadState = .idle
    /// Deleted (here or by someone else) or no longer visible: dismiss.
    public private(set) var isGone = false
    /// Set by a successful `delete()`.
    public private(set) var didDelete = false
    public private(set) var isWorking = false
    public private(set) var referenceDate: Date
    public var error: ErrorState?

    public let session: SessionModel
    private let runner = LoadRunner()
    private var loadedRevision: Int?
    private var fetchingRevision: Int?

    /// - Parameter task: the task from the list, if known (shown before the first load).
    public init(session: SessionModel, groupId: UUID, taskId: UUID, task: TaskItem? = nil) {
        self.session = session
        self.groupId = groupId
        self.taskId = taskId
        self.task = task?.id == taskId && task?.groupId == groupId ? task : nil
        referenceDate = session.platform.now()
    }

    // MARK: - Loading

    public var refreshKey: RefreshKey { RefreshKey(revision: session.feed.groupRevision(groupId)) }

    public var needsRefresh: Bool { loadState != .loaded || loadedRevision != refreshKey.revision }

    public func load() async {
        guard needsRefresh, !isGone else { return }
        let upToDate = runner.isRunning && fetchingRevision == refreshKey.revision
        await runner.run(rerunIfRunning: !upToDate) { [weak self] in await self?.fetch() }
    }

    public func reload() async {
        guard !isGone else { return }
        await runner.run(rerunIfRunning: true) { [weak self] in await self?.fetch() }
    }

    private func fetch() async {
        guard !isGone else { return }
        let revision = refreshKey.revision
        fetchingRevision = revision
        defer { fetchingRevision = nil }
        if loadState != .loaded { loadState = .loading }
        let taskService = session.services.tasks
        let groupService = session.services.groups
        let taskId = taskId
        let groupId = groupId
        do {
            async let taskRequest = taskService.task(id: taskId)
            async let membersRequest = groupService.members(groupId: groupId)
            let (task, members) = try await (taskRequest, membersRequest)
            guard task.groupId == groupId else {
                // A link naming another group (`equipe://task/<group>/<task>`; a task never changes group): the
                // rights, names and reloads would follow the wrong group.
                self.task = nil
                markGone()
                return
            }
            self.task = task
            self.members = members
            referenceDate = session.platform.now()
            loadedRevision = revision
            loadState = .loaded
        } catch {
            if (error as? AppError) == .notFound {
                markGone()
                return
            }
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

    private func markGone() {
        isGone = true
        if loadState != .loaded { loadState = .loaded }
    }

    // MARK: - Display

    public var directory: MemberDirectory { MemberDirectory(members: members, currentUserId: session.userId) }
    public var myRole: MemberRole? { directory.myRole }

    public var title: String { task?.title ?? "Tâche" }
    public var details: String? { task?.details }
    public var status: TaskStatus? { task?.status }
    public var priority: TaskPriority? { task?.priority }

    /// « Aujourd'hui à 20:00 », nil without due date.
    public var dueText: String? {
        task?.dueAt.map { DateText.relative($0, now: referenceDate, calendar: session.platform.calendar) }
    }

    public var isOverdue: Bool { task?.isOverdue(at: referenceDate) ?? false }

    /// « Vous » first, then the other assignees by name; empty when unassigned.
    public var assigneeNames: [String] { directory.names(of: task?.assigneeIds ?? []) }

    /// « Vous, Lucas Bernard » / « Non assignée ».
    public var assigneesText: String { directory.assigneesText(task?.assigneeIds ?? []) }

    /// « Vous », the creator's name, or « Ancien membre » (left the group or deleted account).
    public var creatorName: String? {
        guard let task else { return nil }
        if task.createdBy == session.userId { return MemberDirectory.meName }
        return directory.name(of: task.createdBy)
    }

    /// « Créée par Lucas Bernard hier à 10:00 » / « Créée par vous le lundi 14 septembre à 09:00 ».
    public var createdText: String? {
        guard let task, let creatorName else { return nil }
        let who = task.createdBy == session.userId ? "vous" : creatorName
        let when = DateText.relativeInSentence(task.createdAt, now: referenceDate, calendar: session.platform.calendar)
        return "Créée par \(who) \(when)"
    }

    /// « Terminée aujourd'hui à 09:00 » / « Terminée le lundi 14 septembre à 09:00 », nil unless done.
    public var completedText: String? {
        guard let completedAt = task?.completedAt, task?.status == .done else { return nil }
        return "Terminée \(DateText.relativeInSentence(completedAt, now: referenceDate, calendar: session.platform.calendar))"
    }

    // MARK: - Permissions

    public var canEdit: Bool {
        guard let task else { return false }
        return TaskPermissions.canEdit(task, userId: session.userId, role: myRole)
    }

    public var canChangeStatus: Bool {
        guard let task else { return false }
        return TaskPermissions.canChangeStatus(task, userId: session.userId, role: myRole)
    }

    public var canDelete: Bool {
        guard let task else { return false }
        return TaskPermissions.canDelete(task, userId: session.userId, role: myRole)
    }

    /// Status choices, in order.
    public var statusOptions: [TaskStatus] { TaskStatus.allCases }

    // MARK: - Actions

    @discardableResult
    public func setStatus(_ status: TaskStatus) async -> Bool {
        guard canChangeStatus else {
            present(AppError.forbidden)
            return false
        }
        guard !isWorking, task?.status != status else { return false }
        error = nil
        isWorking = true
        defer { isWorking = false }
        do {
            task = try await session.services.tasks.setStatus(taskId: taskId, status: status)
            session.feed.bump(groupId: groupId)
            session.feed.bumpMyTasks()
            return true
        } catch {
            if present(error) == .notFound { markGone() }
            return false
        }
    }

    @discardableResult
    public func delete() async -> Bool {
        guard canDelete else {
            present(AppError.forbidden)
            return false
        }
        guard !isWorking else { return false }
        error = nil
        isWorking = true
        defer { isWorking = false }
        do {
            try await session.services.tasks.delete(taskId: taskId)
            didDelete = true
            markGone()
            session.feed.bump(groupId: groupId)
            session.feed.bumpMyTasks()
            return true
        } catch {
            if present(error) == .notFound { markGone() }
            return false
        }
    }

    /// Editor for this task (nil when not editable or not loaded). Present it as a sheet; on save call `apply(_:)`.
    public func makeEditor() -> TaskEditorViewModel? {
        guard let task, canEdit else { return nil }
        return TaskEditorViewModel(session: session, task: task, members: members.isEmpty ? nil : members)
    }

    /// Shows a task saved by the editor.
    public func apply(_ updated: TaskItem) {
        guard updated.id == taskId else { return }
        task = updated
    }

    /// Confirmation text of « Supprimer la tâche ».
    public var deleteConfirmationMessage: String {
        "La tâche «\u{00A0}\(title)\u{00A0}» sera supprimée pour tous les membres du groupe."
    }
}
