import Foundation
import Observation

/// A section of « Mes tâches ».
public struct MyTasksSection: Sendable, Hashable, Identifiable {
    public var bucket: DueBucket
    public var rows: [TaskRow]

    public var id: DueBucket { bucket }
    /// « En retard », « Aujourd'hui », « Cette semaine », « Plus tard », « Sans échéance », « Terminées ».
    public var title: String { bucket.title }

    public init(bucket: DueBucket, rows: [TaskRow]) {
        self.bucket = bucket
        self.rows = rows
    }
}

/// « Mes tâches » tab: tasks assigned to the current user in every group, in due-date sections, with a
/// « Nouveau » badge on tasks assigned by someone else since the user last looked (`markAllSeen()`).
///
/// Every successful load also synchronizes the due-date reminders with the loaded list (never after a failed
/// load). Reloads when the « Mes tâches » revision changes and when `includeDone` flips.
/// View: `.task(id: model.refreshKey) { await model.load() }`, `.refreshable { await model.reload() }`,
/// `.onDisappear { model.markAllSeen() }`, tab badge `model.newCount`.
@MainActor
@Observable
public final class MyTasksViewModel: ErrorPresenting {
    public static let emptyTitle = "Aucune tâche"
    public static let emptyMessage = "Les tâches qui vous sont assignées apparaîtront ici."
    public static let newBadgeText = "Nouveau"

    public private(set) var tasks: [TaskItem] = []
    public private(set) var loadState: LoadState = .idle
    /// Also show done tasks (« Terminées » section).
    public var includeDone = false
    /// Assignments after this date are « Nouveau » (nil: never looked, every assignment by someone else is new).
    public private(set) var lastSeenAt: Date?
    public private(set) var referenceDate: Date
    public private(set) var busyTaskIds: Set<UUID> = []
    public var error: ErrorState?

    public let session: SessionModel
    private let runner = LoadRunner()
    private var loadedKey: RefreshKey?
    private var fetchingKey: RefreshKey?
    private var hasReadLastSeen = false

    public init(session: SessionModel) {
        self.session = session
        referenceDate = session.platform.now()
    }

    /// `KeyValueStore` key of the user's « last seen » date.
    public static func lastSeenKey(userId: UUID) -> String {
        "myTasks.lastSeen.\(userId.uuidString)"
    }

    // MARK: - Loading

    public var refreshKey: RefreshKey {
        RefreshKey(revision: session.feed.myTasksRevision, includeDone: includeDone)
    }

    public var needsRefresh: Bool { loadState != .loaded || loadedKey != refreshKey }

    public func load() async {
        guard needsRefresh else { return }
        let upToDate = runner.isRunning && fetchingKey == refreshKey
        await runner.run(rerunIfRunning: !upToDate) { [weak self] in await self?.fetch() }
    }

    public func reload() async {
        await runner.run(rerunIfRunning: true) { [weak self] in await self?.fetch() }
    }

    private func fetch() async {
        let key = refreshKey
        fetchingKey = key
        defer { fetchingKey = nil }
        if !hasReadLastSeen {
            hasReadLastSeen = true
            lastSeenAt = session.platform.store.value(Date.self, forKey: Self.lastSeenKey(userId: session.userId))
        }
        if loadState != .loaded { loadState = .loading }
        let loaded: [TaskItem]
        do {
            loaded = try await session.services.tasks.myTasks(includeDone: key.includeDone)
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
            return
        }
        tasks = loaded
        referenceDate = session.platform.now()
        loadedKey = key
        loadState = .loaded
        // Only a successfully loaded list may drive the reminders (docs/CONTRACTS.md §7).
        await session.synchronizeReminders(with: loaded)
    }

    // MARK: - Display

    /// Non-empty sections in display order (done tasks only when `includeDone`).
    public var sections: [MyTasksSection] {
        let now = referenceDate
        let calendar = session.platform.calendar
        let visible = includeDone ? tasks : tasks.filter { $0.status != .done }
        return DueBucket.sections(for: visible, now: now, calendar: calendar).map { section in
            MyTasksSection(bucket: section.bucket, rows: section.tasks.map { row(for: $0, now: now, calendar: calendar) })
        }
    }

    public var isEmpty: Bool { loadState == .loaded && sections.isEmpty }

    /// Number of « Nouveau » tasks (tab badge).
    public var newCount: Int { tasks.filter { isNew($0) }.count }

    /// Assigned to me by someone else after `lastSeenAt`, not done. Tasks I created are never new.
    public func isNew(_ task: TaskItem) -> Bool {
        guard task.status != .done, task.createdBy != session.userId, let assignedAt = task.myAssignedAt else { return false }
        guard let lastSeenAt else { return true }
        return assignedAt > lastSeenAt
    }

    private func row(for task: TaskItem, now: Date, calendar: Calendar) -> TaskRow {
        TaskRow(
            task: task,
            dueText: task.dueAt.map { DateText.relative($0, now: now, calendar: calendar) },
            isOverdue: task.isOverdue(at: now),
            assigneesText: nil,
            groupName: task.groupName,
            isNew: isNew(task),
            // An assignee may always change the status; editing needs the role, known on the group screens.
            canChangeStatus: task.isAssigned(to: session.userId),
            canEdit: false,
            canDelete: false
        )
    }

    // MARK: - Actions

    /// Clears every « Nouveau » badge (persisted per user). Uses the latest assignment date when the device
    /// clock is behind the server.
    public func markAllSeen() {
        let latest = tasks.compactMap(\.myAssignedAt).max() ?? .distantPast
        let mark = max(session.platform.now(), latest)
        lastSeenAt = mark
        hasReadLastSeen = true
        session.platform.store.setValue(mark, forKey: Self.lastSeenKey(userId: session.userId))
    }

    /// Changes the status of one of my tasks (assignees may always do it).
    @discardableResult
    public func setStatus(_ status: TaskStatus, for task: TaskItem) async -> Bool {
        guard !busyTaskIds.contains(task.id) else { return false }
        error = nil
        busyTaskIds.insert(task.id)
        defer { busyTaskIds.remove(task.id) }
        do {
            let updated = try await session.services.tasks.setStatus(taskId: task.id, status: status)
            if let index = tasks.firstIndex(where: { $0.id == task.id }) {
                var merged = updated
                merged.myAssignedAt = tasks[index].myAssignedAt
                merged.groupName = tasks[index].groupName
                tasks[index] = merged
            }
            session.feed.bump(groupId: task.groupId)
            session.feed.bumpMyTasks()
            return true
        } catch {
            if present(error) == .notFound {
                tasks.removeAll { $0.id == task.id }
                session.feed.bumpMyTasks()
            }
            return false
        }
    }
}
