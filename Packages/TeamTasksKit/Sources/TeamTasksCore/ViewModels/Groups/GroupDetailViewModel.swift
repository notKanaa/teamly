import Foundation
import Observation

/// Group screen: its tasks (filter chips, sort, « Afficher les anciennes terminées »), the current user's role and
/// what it allows, member names for the assignees, rename / delete for admins.
///
/// Reloads when the group's revision changes (any task, assignee or member change, rename) and when
/// `includeOldDone` flips. View: `.task(id: model.refreshKey) { await model.load() }`,
/// `.refreshable { await model.reload() }`; dismiss when `isGone` becomes true.
@MainActor
@Observable
public final class GroupDetailViewModel: ErrorPresenting {
    public static let goneMessage = "Ce groupe n'existe plus ou vous n'en faites plus partie."
    public static let emptyMessage = "Aucune tâche pour l'instant."
    public static let noMatchMessage = "Aucune tâche ne correspond aux filtres."

    public let groupId: UUID
    public private(set) var group: TeamGroup?
    public private(set) var myRole: MemberRole?
    public private(set) var members: [Membership] = []
    public private(set) var tasks: [TaskItem] = []
    public private(set) var loadState: LoadState = .idle
    /// The group was deleted or the user is no longer a member: dismiss the screen.
    public private(set) var isGone = false
    /// Tasks with a status change or a deletion in progress.
    public private(set) var busyTaskIds: Set<UUID> = []
    public private(set) var isUpdatingGroup = false
    /// Date used for « En retard » and the due texts (refreshed at every load).
    public private(set) var referenceDate: Date
    public var filter = TaskFilter.all
    public var sort = TaskSort.dueDate
    /// Also show tasks completed more than 30 days ago (reloads).
    public var includeOldDone = false
    public var error: ErrorState?

    public let session: SessionModel
    private let runner = LoadRunner()
    private var loadedKey: RefreshKey?
    private var fetchingKey: RefreshKey?
    private let initialName: String?

    /// - Parameter group: the summary from the list, if known (title shown before the first load).
    public init(session: SessionModel, groupId: UUID, group: GroupSummary? = nil) {
        self.session = session
        self.groupId = groupId
        initialName = group?.group.name
        self.group = group?.group
        myRole = group?.myRole
        referenceDate = session.platform.now()
    }

    // MARK: - Loading

    public var refreshKey: RefreshKey {
        RefreshKey(revision: session.feed.groupRevision(groupId), includeDone: includeOldDone)
    }

    public var needsRefresh: Bool { loadState != .loaded || loadedKey != refreshKey }

    public func load() async {
        guard needsRefresh, !isGone else { return }
        let upToDate = runner.isRunning && fetchingKey == refreshKey
        await runner.run(rerunIfRunning: !upToDate) { [weak self] in await self?.fetch() }
    }

    public func reload() async {
        guard !isGone else { return }
        await runner.run(rerunIfRunning: true) { [weak self] in await self?.fetch() }
    }

    private func fetch() async {
        guard !isGone else { return }
        let key = refreshKey
        fetchingKey = key
        defer { fetchingKey = nil }
        if loadState != .loaded { loadState = .loading }
        let groupService = session.services.groups
        let taskService = session.services.tasks
        let groupId = groupId
        let includeOldDone = key.includeDone
        do {
            async let groupsRequest = groupService.myGroups()
            async let membersRequest = groupService.members(groupId: groupId)
            async let tasksRequest = taskService.tasks(groupId: groupId, includeOldDone: includeOldDone)
            let (groups, members, tasks) = try await (groupsRequest, membersRequest, tasksRequest)
            guard let summary = groups.first(where: { $0.id == groupId }) else {
                markGone()
                return
            }
            group = summary.group
            myRole = summary.myRole
            self.members = members
            self.tasks = tasks
            referenceDate = session.platform.now()
            loadedKey = key
            loadState = .loaded
        } catch {
            if (error as? AppError) == .notFound {
                markGone()
            } else {
                handleLoadFailure(error)
            }
        }
    }

    private func markGone() {
        isGone = true
        if loadState != .loaded { loadState = .loaded }
    }

    private func handleLoadFailure(_ error: any Error) {
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

    // MARK: - Display

    /// Navigation title.
    public var title: String { group?.name ?? initialName ?? "Groupe" }

    public var directory: MemberDirectory {
        MemberDirectory(members: members, currentUserId: session.userId)
    }

    /// Filtered and sorted tasks, ready to display.
    public var rows: [TaskRow] {
        let directory = directory
        let now = referenceDate
        let calendar = session.platform.calendar
        let userId = session.userId
        let role = myRole
        return sort.sorted(filter.apply(to: tasks, userId: userId, now: now)).map { task in
            TaskRow(
                task: task,
                dueText: task.dueAt.map { DateText.relative($0, now: now, calendar: calendar) },
                isOverdue: task.isOverdue(at: now),
                assigneesText: directory.assigneesText(task.assigneeIds),
                groupName: nil,
                isNew: false,
                canChangeStatus: TaskPermissions.canChangeStatus(task, userId: userId, role: role),
                canEdit: TaskPermissions.canEdit(task, userId: userId, role: role),
                canDelete: TaskPermissions.canDelete(task, userId: userId, role: role)
            )
        }
    }

    /// No task at all (loaded).
    public var isEmpty: Bool { loadState == .loaded && tasks.isEmpty }

    /// Message when `rows` is empty: no task at all, or none matching the filter.
    public var emptyRowsMessage: String { tasks.isEmpty ? Self.emptyMessage : Self.noMatchMessage }

    // MARK: - Filter

    public var filterChips: [TaskFilterChip] { TaskFilterChip.chips(for: filter) }
    public var hasActiveFilter: Bool { filter.isActive }

    public func toggleFilterChip(_ kind: TaskFilterChip.Kind) {
        filter = TaskFilterChip.toggling(kind, in: filter)
    }

    public func resetFilter() {
        filter = .all
    }

    // MARK: - Permissions

    public var canCreateTask: Bool { TaskPermissions.canCreate(role: myRole) }
    public var canRename: Bool { GroupPermissions.canRename(role: myRole) }
    public var canDeleteGroup: Bool { GroupPermissions.canDelete(role: myRole) }
    public var canManageMembers: Bool { GroupPermissions.canManageMembers(role: myRole) }
    public var canSeeInviteCode: Bool { GroupPermissions.canSeeInviteCode(role: myRole) }

    public func canEdit(_ task: TaskItem) -> Bool {
        TaskPermissions.canEdit(task, userId: session.userId, role: myRole)
    }

    public func canChangeStatus(_ task: TaskItem) -> Bool {
        TaskPermissions.canChangeStatus(task, userId: session.userId, role: myRole)
    }

    public func canDelete(_ task: TaskItem) -> Bool {
        TaskPermissions.canDelete(task, userId: session.userId, role: myRole)
    }

    // MARK: - Names

    /// Display name of a member (« Ancien membre » when unknown).
    public func memberName(_ userId: UUID?) -> String {
        directory.name(of: userId)
    }

    /// « Vous » first, then the other assignees in name order.
    public func assigneeNames(for task: TaskItem) -> [String] {
        directory.names(of: task.assigneeIds)
    }

    // MARK: - Task actions

    /// Changes a task's status (admin, creator or assignee).
    @discardableResult
    public func setStatus(_ status: TaskStatus, for task: TaskItem) async -> Bool {
        guard canChangeStatus(task) else {
            present(AppError.forbidden)
            return false
        }
        guard !busyTaskIds.contains(task.id) else { return false }
        error = nil
        busyTaskIds.insert(task.id)
        defer { busyTaskIds.remove(task.id) }
        do {
            let updated = try await session.services.tasks.setStatus(taskId: task.id, status: status)
            replace(updated)
            session.feed.bump(groupId: groupId)
            session.feed.bumpMyTasks()
            return true
        } catch {
            handleTaskFailure(error, taskId: task.id)
            return false
        }
    }

    /// Deletes a task (admin or creator).
    @discardableResult
    public func delete(_ task: TaskItem) async -> Bool {
        guard canDelete(task) else {
            present(AppError.forbidden)
            return false
        }
        guard !busyTaskIds.contains(task.id) else { return false }
        error = nil
        busyTaskIds.insert(task.id)
        defer { busyTaskIds.remove(task.id) }
        do {
            try await session.services.tasks.delete(taskId: task.id)
            tasks.removeAll { $0.id == task.id }
            session.feed.bump(groupId: groupId)
            session.feed.bumpMyTasks()
            return true
        } catch {
            handleTaskFailure(error, taskId: task.id)
            return false
        }
    }

    /// Puts a task returned by another screen (editor, detail) in the list.
    public func apply(_ task: TaskItem) {
        guard task.groupId == groupId else { return }
        replace(task)
    }

    private func replace(_ task: TaskItem) {
        if let index = tasks.firstIndex(where: { $0.id == task.id }) {
            tasks[index] = task
        } else {
            tasks.append(task)
        }
    }

    private func handleTaskFailure(_ error: any Error, taskId: UUID) {
        guard let appError = present(error) else { return }
        if appError == .notFound {
            tasks.removeAll { $0.id == taskId }
            session.feed.bump(groupId: groupId)
        }
    }

    // MARK: - Group actions (admins)

    /// Renames the group. Returns false with `error` set on failure (invalid name, not admin…).
    @discardableResult
    public func rename(to name: String) async -> Bool {
        guard canRename else {
            present(AppError.forbidden)
            return false
        }
        guard !isUpdatingGroup else { return false }
        error = nil
        if let message = CreateGroupViewModel.nameMessage(name) {
            present(message: message, error: .invalidName)
            return false
        }
        isUpdatingGroup = true
        defer { isUpdatingGroup = false }
        do {
            group = try await session.services.groups.rename(groupId: groupId, name: name)
            session.feed.bump(groupId: groupId)
            session.feed.bumpMemberships()
            return true
        } catch {
            if present(error) == .notFound { markGone() }
            return false
        }
    }

    /// Deletes the group and all its tasks (admins). On success `isGone` becomes true.
    @discardableResult
    public func deleteGroup() async -> Bool {
        guard canDeleteGroup else {
            present(AppError.forbidden)
            return false
        }
        guard !isUpdatingGroup else { return false }
        error = nil
        isUpdatingGroup = true
        defer { isUpdatingGroup = false }
        do {
            try await session.services.groups.deleteGroup(groupId: groupId)
            markGone()
            session.feed.bumpMemberships()
            session.feed.bumpMyTasks()
            return true
        } catch {
            if present(error) == .notFound { markGone() }
            return false
        }
    }

    /// Confirmation text of « Supprimer le groupe ».
    public var deleteGroupConfirmationMessage: String {
        "Le groupe « \(title) » et toutes ses tâches seront supprimés pour tous ses membres. Cette action est définitive."
    }
}
