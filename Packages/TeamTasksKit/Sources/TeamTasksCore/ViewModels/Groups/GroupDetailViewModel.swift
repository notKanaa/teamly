import Foundation
import Observation

/// A card of « À qui le tour ? »: a pending occurrence of a rotating task, whose turn it is and who comes next.
public struct TurnCard: Sendable, Hashable, Identifiable {
    public var task: TaskItem
    /// « Aujourd’hui à 20:00 », nil without due date.
    public var dueText: String?
    public var isOverdue: Bool
    /// Whose turn it is (the occurrence's turn holder); nil when the task has none.
    public var current: PersonBadge?
    /// Who takes the next turn (`RotationHandover` over the current members); nil when nobody else is left.
    public var next: PersonBadge?

    public init(task: TaskItem, dueText: String?, isOverdue: Bool, current: PersonBadge?, next: PersonBadge?) {
        self.task = task
        self.dueText = dueText
        self.isOverdue = isOverdue
        self.current = current
        self.next = next
    }

    public var id: UUID { task.id }
    public var title: String { task.title }
    /// It is the current user's turn.
    public var isMyTurn: Bool { current?.isMe == true }
    /// « puis Lucas », « puis toi »; nil without a next person.
    public var nextText: String? {
        next.map { "puis \($0.isMe ? "toi" : $0.shortName)" }
    }
}

/// Group screen: its tasks (filter chips with counts, sort, « Afficher les anciennes terminées »), the current user's
/// role and what it allows, member names for the assignees, rename / delete for admins.
///
/// v2: the group's badge and members in the header, « À qui le tour ? » (`turnCards`), the rows' recurrence,
/// rotation, checklist and assignees, the admins' « Apparence » (`makeAppearanceEditor()`), and the « Tâches » /
/// « Activité » switch (`tab`; the activity has its own model, `activity`).
///
/// Reloads when the group's revision changes (any task, assignee or member change, rename) and when
/// `includeOldDone` flips. View: `.task(id: model.refreshKey) { await model.load() }`,
/// `.refreshable { await model.reload() }`; dismiss when `isGone` becomes true.
@MainActor
@Observable
public final class GroupDetailViewModel: ErrorPresenting {
    /// « Tâches » / « Activité ».
    public enum Tab: String, Sendable, Hashable, CaseIterable, Identifiable {
        case tasks
        case activity

        public var id: String { rawValue }

        public var label: String {
            switch self {
            case .tasks: "Tâches"
            case .activity: "Activité"
            }
        }
    }

    public static let goneMessage = "Ce groupe n’existe plus ou tu n’en fais plus partie."
    public static let emptyMessage = "Aucune tâche pour l’instant."
    public static let noMatchMessage = "Aucune tâche ne correspond aux filtres."
    /// Title of the rotation cards.
    public static let turnCardsTitle = "À qui le tour\u{00A0}?"

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
    /// v2: the « Tâches » / « Activité » switch.
    public var tab = Tab.tasks
    /// v2: the « Activité » tab (loads itself when shown).
    public let activity: GroupActivityViewModel
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
        activity = GroupActivityViewModel(session: session, groupId: groupId)
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

    /// v2: the group's badge (resolved color, emoji or initials) for the header; nil before the first load.
    public var appearance: AvatarAppearance? { group?.appearance }

    /// v2: the members' badges for the header's avatars, in the members' order.
    public var memberBadges: [PersonBadge] { directory.memberBadges }

    /// v2: « 3 membres · Tu es admin », « 2 membres · Tu es membre ».
    public var membersSummary: String {
        let count = FrenchText.count(members.count, "membre", "membres")
        switch myRole {
        case .some(.admin): return "\(count) · Tu es admin"
        case .some(.member): return "\(count) · Tu es membre"
        case .none: return count
        }
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
                canDelete: TaskPermissions.canDelete(task, userId: userId, role: role),
                assignees: directory.badges(of: task.assigneeIds),
                isMyTurn: Self.isTurn(of: userId, in: task)
            )
        }
    }

    /// No task at all (loaded).
    public var isEmpty: Bool { loadState == .loaded && tasks.isEmpty }

    /// Message when `rows` is empty: no task at all, or none matching the filter.
    public var emptyRowsMessage: String { tasks.isEmpty ? Self.emptyMessage : Self.noMatchMessage }

    static func isTurn(of userId: UUID, in task: TaskItem) -> Bool {
        task.status != .done && task.hasRotation && task.turnUserId == userId
    }

    // MARK: - « À qui le tour ? » (v2)

    /// The pending occurrences of the rotating tasks, by due date: whose turn it is and who comes next, the next turn
    /// computed like the server (`RotationHandover`) over the current members. Independent of the filter.
    public var turnCards: [TurnCard] {
        let directory = directory
        let shortNames = directory.shortNames
        let memberIds = Set(members.map(\.user.id))
        let now = referenceDate
        let calendar = session.platform.calendar
        let pending = tasks.filter { $0.status != .done && $0.hasRotation }
        return TaskSort.dueDate.sorted(pending).map { task in
            let handover = RotationHandover(after: task.rotation, turnUserId: task.turnUserId) { memberIds.contains($0) }
            let nextId = handover.assigneeId.flatMap { $0 == task.turnUserId ? nil : $0 }
            return TurnCard(
                task: task,
                dueText: task.dueAt.map { DateText.relative($0, now: now, calendar: calendar) },
                isOverdue: task.isOverdue(at: now),
                current: task.turnUserId.map { directory.badge(of: $0, shortNames: shortNames) },
                next: nextId.map { directory.badge(of: $0, shortNames: shortNames) }
            )
        }
    }

    /// « 2 tâches tournantes », nil without rotating task.
    public var turnCardsSubtitle: String? {
        let count = turnCards.count
        return count == 0 ? nil : FrenchText.count(count, "tâche tournante", "tâches tournantes")
    }

    // MARK: - Filter

    /// v2: the status chips carry their counts (`TaskFilterChip.countedLabel`: « À faire · 4 »).
    public var filterChips: [TaskFilterChip] { TaskFilterChip.chips(for: filter, counts: statusCounts) }
    public var hasActiveFilter: Bool { filter.isActive }

    /// v2: the number of tasks each status chip shows, the other criteria of the filter (« Assignées à moi »,
    /// « En retard ») applied.
    public func count(for status: TaskStatusFilter) -> Int {
        var criteria = filter
        criteria.status = status
        return criteria.apply(to: tasks, userId: session.userId, now: referenceDate).count
    }

    /// v2: `count(for:)` of every status chip.
    public var statusCounts: [TaskStatusFilter: Int] {
        Dictionary(uniqueKeysWithValues: TaskFilterChip.statusChoices.map { ($0, count(for: $0)) })
    }

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
    /// v2: « Apparence » (admins).
    public var canSetAppearance: Bool { GroupPermissions.canSetAppearance(role: myRole) }

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

    /// « Toi » first, then the other assignees in name order.
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

    /// v2: the « Apparence » sheet (admins, once loaded); nil otherwise. On save call `apply(group:)`.
    public func makeAppearanceEditor() -> GroupAppearanceViewModel? {
        guard canSetAppearance, let group else { return nil }
        return GroupAppearanceViewModel(session: session, group: group)
    }

    /// v2: shows a group saved by another screen (« Apparence »).
    public func apply(group updated: TeamGroup) {
        guard updated.id == groupId else { return }
        group = updated
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
        "Le groupe «\u{00A0}\(title)\u{00A0}» et toutes ses tâches seront supprimés pour tous ses membres. Cette action est définitive."
    }
}
