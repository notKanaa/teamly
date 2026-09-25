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

/// v2: « Ta journée » on « Mes tâches »: what the user did today out of what they planned.
public struct DaySummary: Sendable, Hashable {
    public static let title = "Ta journée"

    /// My tasks done today (completed today, whatever their due date).
    public var doneCount: Int
    /// My tasks still to do that are due today (earlier today included), plus those done today.
    public var plannedCount: Int
    /// My overdue tasks (not done, due before now).
    public var overdueCount: Int
    /// My « Nouveau » tasks.
    public var newCount: Int

    public init(doneCount: Int, plannedCount: Int, overdueCount: Int, newCount: Int) {
        self.doneCount = doneCount
        self.plannedCount = plannedCount
        self.overdueCount = overdueCount
        self.newCount = newCount
    }

    /// 0…1, for the ring.
    public var fraction: Double { plannedCount == 0 ? 0 : Double(doneCount) / Double(plannedCount) }

    /// « 2/4 », inside the ring.
    public var ringText: String { "\(doneCount)/\(plannedCount)" }

    /// « 2 tâches faites sur 4 prévues », « Tout est fait pour aujourd’hui ! », « Rien de prévu aujourd’hui ».
    public var subtitle: String {
        if plannedCount == 0 { return "Rien de prévu aujourd’hui" }
        if doneCount >= plannedCount { return "Tout est fait pour aujourd’hui\u{00A0}!" }
        let done = FrenchText.count(doneCount, "tâche faite", "tâches faites")
        return "\(done) sur \(plannedCount) \(FrenchText.isSingular(plannedCount) ? "prévue" : "prévues")"
    }

    /// « 1 en retard », nil when none.
    public var overdueText: String? {
        overdueCount == 0 ? nil : "\(overdueCount) en retard"
    }

    /// « 1 nouvelle », « 2 nouvelles », nil when none.
    public var newText: String? {
        newCount == 0 ? nil : FrenchText.count(newCount, "nouvelle", "nouvelles")
    }
}

/// « Mes tâches » tab: tasks assigned to the current user in every group, in due-date sections, with a
/// « Nouveau » badge on tasks assigned by someone else since the user last looked (`markAllSeen()`).
///
/// v2: the rows carry the group's badge and short name, « Ton tour », the checklist progress; « Ta journée »
/// (`daySummary`, `todayText`) and « n tâches terminées aujourd’hui » (`doneTodayText`, `doneTodayRows`).
///
/// Reads, one per load: `TaskService.myTasks(doneSince:)` from the start of today in the injected calendar, i.e. the
/// tasks not done and those done today (« Ta journée » and the tasks done today need no more), so that the read does
/// not grow with the done occurrences of recurring tasks; while « Terminées » is shown (`includeDone`), from
/// `Limits.oldDoneTaskDays` days back (`now − 30 × 24 h`, the bound of the group screen): the done tasks of the last
/// 30 days, never the whole history. `tasks` keeps the v1 content (without the done tasks unless `includeDone`), and
/// `doneTasks` holds the done ones. Every successful load also synchronizes the due-date reminders with the loaded list
/// (never after a failed load). Reloads when the « Mes tâches » revision changes (a new day bumps every revision:
/// `SessionModel.handleSignificantTimeChange()`) and when `includeDone` flips.
/// View: `.task(id: model.refreshKey) { await model.load() }`, `.refreshable { await model.reload() }`,
/// `.onDisappear { model.markAllSeen() }`, tab badge `model.newCount`.
@MainActor
@Observable
public final class MyTasksViewModel: ErrorPresenting {
    public static let emptyTitle = "Aucune tâche"
    public static let emptyMessage = "Les tâches qui te sont assignées apparaîtront ici."
    public static let newBadgeText = "Nouveau"

    /// The tasks shown in the sections: without the done ones unless `includeDone` (a task completed here stays until
    /// the next load).
    public private(set) var tasks: [TaskItem] = []
    /// v2: the done tasks of the last load: those done since the start of that day, or those of the last 30 days while
    /// `includeDone`.
    public private(set) var doneTasks: [TaskItem] = []
    public private(set) var loadState: LoadState = .idle
    /// Also show the tasks done in the last 30 days (« Terminées » section, `Limits.oldDoneTaskDays`).
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
            loaded = try await session.services.tasks.myTasks(doneSince: doneSince(includeDone: key.includeDone))
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
        tasks = key.includeDone ? loaded : loaded.filter { $0.status != .done }
        doneTasks = loaded.filter { $0.status == .done }
        referenceDate = session.platform.now()
        loadedKey = key
        loadState = .loaded
        // Only a successfully loaded list may drive the reminders (docs/CONTRACTS.md §7); done tasks are ignored.
        await session.synchronizeReminders(with: loaded)
    }

    /// The oldest completion a load reads: the start of today in the injected calendar (« Ta journée » and the tasks
    /// done today), or, with « Terminées », `Limits.oldDoneTaskDays` days back from now (`now − 30 × 24 h`, like the
    /// group screen's bound on old done tasks).
    private func doneSince(includeDone: Bool) -> Date {
        let now = session.platform.now()
        if includeDone {
            return now.addingTimeInterval(-TimeInterval(Limits.oldDoneTaskDays) * 86_400)
        }
        return session.platform.calendar.startOfDay(for: now)
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

    /// Assigned to me by someone else (or by a since-deleted account) after `lastSeenAt`, not done. Tasks I created
    /// and tasks I assigned to myself are never new (like `AssignmentNotifier`, which ignores self-assignments).
    public func isNew(_ task: TaskItem) -> Bool {
        guard task.status != .done, task.createdBy != session.userId, task.myAssignedBy != session.userId,
              let assignedAt = task.myAssignedAt
        else { return false }
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
            canDelete: false,
            isMyTurn: GroupDetailViewModel.isTurn(of: session.userId, in: task)
        )
    }

    // MARK: - Today (v2)

    /// « Vendredi 25 septembre », above the title.
    public var todayText: String {
        let formatter = FrenchDateFormatter(timeZone: session.platform.calendar.timeZone)
        return FrenchDateFormatter.capitalizingFirstLetter(formatter.day(referenceDate, includeYear: false))
    }

    /// « Ta journée »: done today, planned today, overdue and new.
    public var daySummary: DaySummary {
        let bounds = DueBucketBoundaries(now: referenceDate, calendar: session.platform.calendar)
        let isToday = { (date: Date?) -> Bool in
            guard let date else { return false }
            return date >= bounds.startOfToday && date < bounds.startOfTomorrow
        }
        let all = allTasks
        let doneToday = all.filter { $0.status == .done && isToday($0.completedAt) }.count
        let toDoToday = all.filter { $0.status != .done && isToday($0.dueAt) }.count
        return DaySummary(
            doneCount: doneToday,
            plannedCount: doneToday + toDoToday,
            overdueCount: all.filter { $0.isOverdue(at: referenceDate) }.count,
            newCount: newCount
        )
    }

    /// My tasks done today, most recently completed first (the « terminées aujourd’hui » entry).
    public var doneTodayRows: [TaskRow] {
        let now = referenceDate
        let calendar = session.platform.calendar
        let bounds = DueBucketBoundaries(now: now, calendar: calendar)
        return allTasks
            .filter { task in
                guard task.status == .done, let completedAt = task.completedAt else { return false }
                return completedAt >= bounds.startOfToday && completedAt < bounds.startOfTomorrow
            }
            .sorted { ($0.completedAt ?? .distantPast) > ($1.completedAt ?? .distantPast) }
            .map { row(for: $0, now: now, calendar: calendar) }
    }

    /// « 2 tâches terminées aujourd’hui », « 1 tâche terminée aujourd’hui »; nil when none.
    public var doneTodayText: String? {
        let count = doneTodayRows.count
        guard count > 0 else { return nil }
        return "\(FrenchText.count(count, "tâche terminée", "tâches terminées")) aujourd’hui"
    }

    /// `tasks` then the done tasks not in it (a local status change wins).
    private var allTasks: [TaskItem] {
        var seen = Set<UUID>()
        return (tasks + doneTasks).filter { seen.insert($0.id).inserted }
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

    /// Changes the status of one of my tasks (assignees may always do it), also from the « terminées aujourd’hui »
    /// list.
    @discardableResult
    public func setStatus(_ status: TaskStatus, for task: TaskItem) async -> Bool {
        guard !busyTaskIds.contains(task.id) else { return false }
        error = nil
        busyTaskIds.insert(task.id)
        defer { busyTaskIds.remove(task.id) }
        do {
            let updated = try await session.services.tasks.setStatus(taskId: task.id, status: status)
            if let index = tasks.firstIndex(where: { $0.id == task.id }) {
                tasks[index] = Self.merge(updated, into: tasks[index])
            }
            if let index = doneTasks.firstIndex(where: { $0.id == task.id }) {
                doneTasks[index] = Self.merge(updated, into: doneTasks[index])
            }
            session.feed.bump(groupId: task.groupId)
            session.feed.bumpMyTasks()
            return true
        } catch {
            if present(error) == .notFound {
                tasks.removeAll { $0.id == task.id }
                doneTasks.removeAll { $0.id == task.id }
                session.feed.bumpMyTasks()
            }
            return false
        }
    }

    /// `updated` with the fields only `myTasks` fills, taken from `current`.
    private static func merge(_ updated: TaskItem, into current: TaskItem) -> TaskItem {
        var merged = updated
        merged.myAssignedAt = current.myAssignedAt
        merged.myAssignedBy = current.myAssignedBy
        merged.groupName = current.groupName
        merged.groupColor = current.groupColor
        merged.groupEmoji = current.groupEmoji
        return merged
    }
}
