import Foundation
import Observation

/// A person of a task's rotation (« À tour de rôle »), in turn order.
public struct RotationEntry: Sendable, Hashable, Identifiable {
    public var person: PersonBadge
    /// Whose turn this occurrence is.
    public var isCurrentTurn: Bool

    public init(person: PersonBadge, isCurrentTurn: Bool) {
        self.person = person
        self.isCurrentTurn = isCurrentTurn
    }

    public var id: UUID { person.id }
}

/// Task screen: fields, assignee and creator names, status change (admin, creator, assignee), edit and delete
/// (admin, creator).
///
/// v2: the checklist (`checklist`, `checklistProgress` « 2 sur 5 »; add, rename, check / uncheck, delete with the
/// rights of `canManageChecklist`; checking shows at once and is rolled back on failure), the repetition
/// (`recurrenceText`, the next dates `upcomingDueTexts`), and the rotation (`rotationEntries` from the current turn,
/// `rotationText`).
///
/// Reloads when the group's revision changes. View: `.task(id: model.refreshKey) { await model.load() }`;
/// dismiss when `isGone` becomes true (deleted here or elsewhere, or no longer visible).
@MainActor
@Observable
public final class TaskDetailViewModel: ErrorPresenting {
    public static let goneMessage = "Cette tâche n’existe plus."
    /// v2: title of the next dates of a recurring task.
    public static let upcomingTitle = "Prochaines fois"
    /// v2: number of next dates shown.
    public static let upcomingCount = 3
    public static let checklistTitle = "Checklist"
    public static let addChecklistItemTitle = "Ajouter un élément"

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
    /// v2: the « Ajouter un élément » field (typing clears `checklistError`).
    public var newChecklistItemTitle: String {
        get { newChecklistItemTitleValue }
        set {
            newChecklistItemTitleValue = newValue
            if checklistError != nil { checklistError = nil }
        }
    }

    /// v2: the message of the checklist (a refused title, too many items).
    public private(set) var checklistError: String?
    /// v2: items with a change in progress.
    public private(set) var busyChecklistItemIds: Set<UUID> = []
    public private(set) var isAddingChecklistItem = false
    public var error: ErrorState?

    public let session: SessionModel
    private let runner = LoadRunner()
    private var loadedRevision: Int?
    private var fetchingRevision: Int?
    private var newChecklistItemTitleValue = ""

    /// - Parameter task: the task from the list, if known (shown before the first load). From « Mes tâches », its
    ///   group fields (`groupName`, `groupColor`, `groupEmoji`) are kept (`groupAppearance`).
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
            self.task = merged(task)
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

    /// A loaded task, with what the screen knows better: the group fields of a task handed over by « Mes tâches »,
    /// and the items whose change is in progress (shown as the user set them).
    private func merged(_ loaded: TaskItem) -> TaskItem {
        guard let current = task else { return loaded }
        var task = loaded
        task.groupName = loaded.groupName ?? current.groupName
        task.groupColor = loaded.groupColor ?? current.groupColor
        task.groupEmoji = loaded.groupEmoji ?? current.groupEmoji
        if !busyChecklistItemIds.isEmpty {
            task.checklist = task.checklist.map { item in
                guard busyChecklistItemIds.contains(item.id) else { return item }
                return current.checklist.first { $0.id == item.id } ?? item
            }
        }
        return task
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

    /// v2: the assignees as badges, the current user first, then by name.
    public var assignees: [PersonBadge] { directory.badges(of: task?.assigneeIds ?? []) }

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

    /// v2: the group's badge and name when the task came from « Mes tâches » (nil otherwise: the group screen is
    /// below this one).
    public var groupAppearance: AvatarAppearance? { task?.groupAppearance }
    public var groupName: String? { task?.groupName }

    // MARK: - Repetition (v2)

    /// « Chaque semaine, le samedi », « Toutes les 2 semaines, le mardi et le vendredi », « Chaque mois, le 25 »;
    /// nil for a plain task.
    public var recurrenceText: String? {
        guard let task, let rule = task.recurrence else { return nil }
        return RecurrenceText.description(rule, dueAt: task.dueAt)
    }

    /// The due dates of the next occurrences, as the server would create them if this one were done now
    /// (`NextDueCalculator.upcomingDueDates`); empty for a plain or done task.
    public var upcomingDueDates: [Date] {
        guard let task, task.status != .done, let rule = task.recurrence, let dueAt = task.dueAt else { return [] }
        return NextDueCalculator.upcomingDueDates(after: dueAt, rule: rule, now: referenceDate, count: Self.upcomingCount)
    }

    /// « Samedi 3 octobre à 11:00 », for `upcomingTitle`.
    public var upcomingDueTexts: [String] {
        upcomingDueDates.map { DateText.relative($0, now: referenceDate, calendar: session.platform.calendar) }
    }

    // MARK: - Rotation (v2)

    /// The rotation's current members in turn order, starting with the current turn holder (who left the group is
    /// left out: the next occurrence drops them); empty without rotation.
    public var rotationEntries: [RotationEntry] {
        guard let task, task.hasRotation else { return [] }
        let directory = directory
        let shortNames = directory.shortNames
        let memberIds = Set(members.map(\.user.id))
        var order = task.rotation
        if let turn = task.turnUserId, let index = order.firstIndex(of: turn) {
            order = Array(order[index...] + order[..<index])
        }
        return order.filter { memberIds.contains($0) }.map { userId in
            RotationEntry(person: directory.badge(of: userId, shortNames: shortNames), isCurrentTurn: userId == task.turnUserId)
        }
    }

    /// « C’est au tour de Lucas, puis Camille, puis Inès. », « C’est ton tour, puis Lucas. »; nil without rotation.
    public var rotationText: String? {
        let entries = rotationEntries
        guard let first = entries.first else { return nil }
        let head: String
        if !first.isCurrentTurn {
            head = "Tour de rôle\u{00A0}: \(Self.turnName(first.person))"
        } else if first.person.isMe {
            head = "C’est ton tour"
        } else {
            head = "C’est au tour \(FrenchText.de(first.person.shortName))"
        }
        let rest = entries.dropFirst().map { ", puis \(Self.turnName($0.person))" }.joined()
        return head + rest + "."
    }

    private static func turnName(_ person: PersonBadge) -> String {
        person.isMe ? "toi" : person.shortName
    }

    // MARK: - Checklist (v2)

    /// The checklist, in display order.
    public var checklist: [ChecklistItem] { task?.checklist ?? [] }

    /// « 2 sur 5 » (`ChecklistProgress.text`), nil without items.
    public var checklistProgress: ChecklistProgress? { ChecklistProgress(checklist) }

    /// Add, rename, check, uncheck and delete items: admins, the creator and the assignees.
    public var canManageChecklist: Bool {
        guard let task else { return false }
        return TaskPermissions.canManageChecklist(task, userId: session.userId, role: myRole)
    }

    /// The « Ajouter un élément » button: allowed, a title typed, fewer than `Limits.checklistItemsMax` items.
    public var canAddChecklistItem: Bool {
        canManageChecklist && !isAddingChecklistItem && !InputValidation.trimmed(newChecklistItemTitle).isEmpty
            && checklist.count < Limits.checklistItemsMax
    }

    /// Adds `newChecklistItemTitle` at the end (then clears the field). A refused title or a full checklist sets
    /// `checklistError`.
    @discardableResult
    public func addChecklistItem() async -> Bool {
        guard canManageChecklist else {
            present(AppError.forbidden)
            return false
        }
        guard !isAddingChecklistItem else { return false }
        error = nil
        let title: String
        do {
            title = try InputValidation.checklistItemTitle(newChecklistItemTitle)
        } catch {
            checklistError = AppError.invalidChecklistItem.messageFR
            return false
        }
        guard checklist.count < Limits.checklistItemsMax else {
            checklistError = AppError.tooManyChecklistItems.messageFR
            return false
        }
        isAddingChecklistItem = true
        defer { isAddingChecklistItem = false }
        do {
            let item = try await session.services.tasks.addChecklistItem(taskId: taskId, title: title)
            if var current = task {
                current.checklist = ChecklistItem.sorted(current.checklist.filter { $0.id != item.id } + [item])
                task = current
            }
            newChecklistItemTitle = ""
            didChangeChecklist()
            return true
        } catch {
            await handleChecklistFailure(error, itemId: nil)
            return false
        }
    }

    /// Renames an item. A refused title sets `checklistError`; the same title does nothing.
    @discardableResult
    public func renameChecklistItem(_ itemId: UUID, to newTitle: String) async -> Bool {
        guard canManageChecklist else {
            present(AppError.forbidden)
            return false
        }
        guard let item = checklist.first(where: { $0.id == itemId }), !busyChecklistItemIds.contains(itemId) else {
            return false
        }
        error = nil
        checklistError = nil
        let title: String
        do {
            title = try InputValidation.checklistItemTitle(newTitle)
        } catch {
            checklistError = AppError.invalidChecklistItem.messageFR
            return false
        }
        guard title != item.title else { return true }
        busyChecklistItemIds.insert(itemId)
        defer { busyChecklistItemIds.remove(itemId) }
        do {
            let renamed = try await session.services.tasks.renameChecklistItem(itemId: itemId, title: title)
            replaceChecklistItem(renamed)
            didChangeChecklist()
            return true
        } catch {
            await handleChecklistFailure(error, itemId: itemId)
            return false
        }
    }

    /// Checks or unchecks an item: shown at once, rolled back when the server refuses (`error` then says why).
    @discardableResult
    public func setChecklistItem(_ itemId: UUID, done: Bool) async -> Bool {
        guard canManageChecklist else {
            present(AppError.forbidden)
            return false
        }
        guard let previous = checklist.first(where: { $0.id == itemId }), previous.isDone != done,
              !busyChecklistItemIds.contains(itemId)
        else { return false }
        error = nil
        busyChecklistItemIds.insert(itemId)
        defer { busyChecklistItemIds.remove(itemId) }
        var optimistic = previous
        optimistic.isDone = done
        optimistic.doneAt = done ? session.platform.now() : nil
        optimistic.doneBy = done ? session.userId : nil
        replaceChecklistItem(optimistic)
        do {
            let saved = try await session.services.tasks.setChecklistItemDone(itemId: itemId, done: done)
            replaceChecklistItem(saved)
            didChangeChecklist()
            return true
        } catch {
            replaceChecklistItem(previous)
            await handleChecklistFailure(error, itemId: itemId)
            return false
        }
    }

    /// Checks an unchecked item, unchecks a checked one (`setChecklistItem(_:done:)`).
    @discardableResult
    public func toggleChecklistItem(_ itemId: UUID) async -> Bool {
        guard let item = checklist.first(where: { $0.id == itemId }) else { return false }
        return await setChecklistItem(itemId, done: !item.isDone)
    }

    /// Deletes an item (the others keep their places). An item already deleted elsewhere just disappears.
    @discardableResult
    public func deleteChecklistItem(_ itemId: UUID) async -> Bool {
        guard canManageChecklist else {
            present(AppError.forbidden)
            return false
        }
        guard checklist.contains(where: { $0.id == itemId }), !busyChecklistItemIds.contains(itemId) else {
            return false
        }
        error = nil
        busyChecklistItemIds.insert(itemId)
        defer { busyChecklistItemIds.remove(itemId) }
        do {
            try await session.services.tasks.deleteChecklistItem(itemId: itemId)
            removeChecklistItem(itemId)
            didChangeChecklist()
            return true
        } catch {
            if (error as? AppError) == .notFound {
                // Already gone: what was asked for. The reload says whether the task is gone too.
                removeChecklistItem(itemId)
                didChangeChecklist()
                return true
            }
            await handleChecklistFailure(error, itemId: itemId)
            return false
        }
    }

    private func replaceChecklistItem(_ item: ChecklistItem) {
        guard var current = task, let index = current.checklist.firstIndex(where: { $0.id == item.id }) else { return }
        current.checklist[index] = item
        task = current
    }

    private func removeChecklistItem(_ itemId: UUID) {
        guard var current = task else { return }
        current.checklist.removeAll { $0.id == itemId }
        task = current
    }

    /// Other screens (and this one) reload: the group's lists and « Mes tâches » show the progress.
    private func didChangeChecklist() {
        session.feed.bump(groupId: groupId)
        session.feed.bumpMyTasks()
    }

    private func handleChecklistFailure(_ error: any Error, itemId: UUID?) async {
        guard let appError = ErrorState(from: error)?.error else { return }
        switch appError {
        case .invalidChecklistItem, .tooManyChecklistItems:
            checklistError = appError.messageFR
        case .notFound:
            // The item or the task is gone: the reload shows what is left (or leaves the screen).
            if let itemId { removeChecklistItem(itemId) }
            present(appError)
            await reload()
        default:
            present(appError)
        }
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
            let updated = try await session.services.tasks.setStatus(taskId: taskId, status: status)
            task = merged(updated)
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
        task = merged(updated)
    }

    /// Confirmation text of « Supprimer la tâche ».
    public var deleteConfirmationMessage: String {
        "La tâche «\u{00A0}\(title)\u{00A0}» sera supprimée pour tous les membres du groupe."
    }
}
