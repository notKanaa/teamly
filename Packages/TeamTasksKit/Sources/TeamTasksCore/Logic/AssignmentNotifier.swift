import Foundation

/// A `RealtimeEvent.assigned` signal, forwarded by `RealtimeCoordinator` to `AssignmentNotifier`.
public struct RealtimeAssignment: Sendable, Hashable {
    public var taskId: UUID
    public var groupId: UUID
    /// Who assigned the task (nil when that account was deleted).
    public var assignedBy: UUID?

    public init(taskId: UUID, groupId: UUID, assignedBy: UUID?) {
        self.taskId = taskId
        self.groupId = groupId
        self.assignedBy = assignedBy
    }
}

/// Turns "a task was assigned to me" into local notifications, from two sources:
/// - realtime (`handleRealtime`): `RealtimeEvent.assigned` + a lookup through `TaskService.task(id:)`;
/// - catch-up (`catchUp`): `TaskService.assignments(since:)` from a persisted cursor (app launch,
///   foreground, background refresh).
///
/// The same assignment seen by both sources is notified once: the notifier persists, per user, the cursor
/// (latest `assignedAt` handled by catch-up) and a bounded list of already-handled tasks.
/// Assignments made by the current user are ignored. Up to `maxIndividual` new assignments produce one
/// `assigned-<taskId>` notification each; more produce a single `summary-<epochSeconds>` notification.
/// When notifications are not authorized nothing is posted, but the cursor still advances.
///
/// The cursor only ever holds server timestamps (the device clock may be wrong). Every catch-up re-reads
/// `catchUpOverlap` before it, because `assigned_at` is the transaction start time: a row can become visible
/// after a newer one. Re-read rows are recognized by the remembered records. A notification whose posting
/// failed holds the cursor back, so the next catch-up retries it.
///
/// Operations are serialized (a realtime lookup and a catch-up never interleave).
public actor AssignmentNotifier {
    /// Resolves a group's name for the notification body (e.g. from `GroupService.myGroups()`).
    public typealias GroupNameResolver = @Sendable (UUID) async -> String?

    public static let defaultMaxIndividual = 5
    public static let defaultRememberedLimit = 200
    /// Dedup window around a remembered notification:
    /// - a catch-up assignment of a task notified through realtime (server `assignedAt` unknown) is a
    ///   duplicate when assigned no later than this after the notification (absorbs device/server clock skew);
    /// - a realtime signal for a task notified less than this long ago is a duplicate (same assignment
    ///   already seen by catch-up, or a repeated delivery); an older one is a re-assignment.
    public static let realtimeDedupWindow: TimeInterval = 5 * 60
    /// How far back the first catch-up looks for existing assignments (history, never notified): the latest
    /// one becomes the cursor.
    public static let initialLookback: TimeInterval = 7 * 86_400
    /// How much every catch-up re-reads before the cursor (a transaction that started earlier can commit later).
    public static let catchUpOverlap: TimeInterval = 2 * 60

    public static let individualTitle = "Nouvelle tâche"
    public static let summaryTitle = "Nouvelles tâches"

    /// Persisted state (one `KeyValueStore` entry per user).
    struct State: Codable, Equatable {
        struct Record: Codable, Equatable {
            var taskId: UUID
            /// Server assignment date when known (catch-up), nil for a realtime notification.
            var assignedAt: Date?
            /// Device date of the notification.
            var notifiedAt: Date
        }

        /// Latest `assignedAt` handled by catch-up.
        var cursor: Date?
        /// Notified tasks, and tasks skipped as history or while notifications were not authorized.
        /// Oldest first, at most `rememberedLimit` entries.
        var notified: [Record] = []
    }

    private struct Item {
        var taskId: UUID
        var groupId: UUID
        var title: String
        var groupName: String?
        var assignedAt: Date?
    }

    private let userId: UUID
    private let tasks: any TaskService
    private let scheduler: any NotificationScheduler
    private let store: any KeyValueStore
    private let now: NowProvider
    private let groupName: GroupNameResolver
    private let maxIndividual: Int
    private let rememberedLimit: Int

    private var isBusy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    public init(
        userId: UUID,
        tasks: any TaskService,
        scheduler: any NotificationScheduler,
        store: any KeyValueStore,
        now: @escaping NowProvider = { Date() },
        groupName: @escaping GroupNameResolver = { _ in nil },
        maxIndividual: Int = AssignmentNotifier.defaultMaxIndividual,
        rememberedLimit: Int = AssignmentNotifier.defaultRememberedLimit
    ) {
        self.userId = userId
        self.tasks = tasks
        self.scheduler = scheduler
        self.store = store
        self.now = now
        self.groupName = groupName
        self.maxIndividual = max(0, maxIndividual)
        self.rememberedLimit = max(1, rememberedLimit)
    }

    /// `KeyValueStore` key of a user's state.
    public static func storageKey(userId: UUID) -> String {
        "assignments.state.\(userId.uuidString)"
    }

    public static func individualIdentifier(taskId: UUID) -> String {
        "assigned-\(taskId.uuidString)"
    }

    public static func summaryIdentifier(at date: Date) -> String {
        "summary-\(ReminderPlanner.epochSeconds(date))"
    }

    /// Latest `assignedAt` handled by catch-up (nil before the first catch-up).
    public var cursor: Date? { loadState().cursor }

    /// Ids of the tasks remembered as already handled (notified, or skipped as history or while notifications
    /// were not authorized), oldest first.
    public var rememberedTaskIds: [UUID] { loadState().notified.map(\.taskId) }

    /// Forgets the cursor and the remembered notifications (sign-out, account deletion).
    public func reset() async {
        await acquire()
        defer { release() }
        store.set(nil, forKey: Self.storageKey(userId: userId))
    }

    // MARK: - Realtime

    /// Handles a realtime assignment. Returns the notifications posted.
    /// Best effort: when the task cannot be read (deleted, network error) nothing is remembered, so the
    /// next catch-up still notifies it.
    @discardableResult
    public func handleRealtime(_ assignment: RealtimeAssignment) async -> [LocalNotification] {
        guard assignment.assignedBy != userId else { return [] }
        await acquire()
        defer { release() }

        var state = loadState()
        let date = now()
        // A realtime event is a new INSERT: it duplicates a remembered notification only when that one was
        // posted moments ago (same assignment seen by catch-up, or a duplicated delivery). An older record
        // means the task was unassigned and assigned again.
        if let record = state.notified.last(where: { $0.taskId == assignment.taskId }),
           date.timeIntervalSince(record.notifiedAt) < Self.realtimeDedupWindow {
            return []
        }
        guard await scheduler.authorizationStatus() == .authorized else { return [] }
        guard let task = try? await tasks.task(id: assignment.taskId), task.isAssigned(to: userId) else {
            return []
        }
        var name = task.groupName
        if name == nil {
            name = await groupName(task.groupId)
        }
        let item = Item(taskId: task.id, groupId: task.groupId, title: task.title, groupName: name, assignedAt: nil)
        let outcome = await post([item], state: &state)
        saveState(state)
        return outcome.posted
    }

    // MARK: - Catch-up

    /// Fetches the assignments made since the cursor and notifies the new ones. Returns the notifications
    /// posted. The first call only initializes the cursor (history is not notified): to the latest assignment
    /// of the last `initialLookback`, or to the start of that period when there is none.
    /// Throws the `TaskService` error; the cursor is then unchanged.
    @discardableResult
    public func catchUp() async throws -> [LocalNotification] {
        await acquire()
        defer { release() }

        var state = loadState()
        guard let cursor = state.cursor else {
            let start = now().addingTimeInterval(-Self.initialLookback)
            let history = try await tasks.assignments(since: start).sorted { $0.assignedAt < $1.assignedAt }
            let latest = max(start, history.last?.assignedAt ?? start)
            let date = now()
            for event in history where event.assignedAt > latest.addingTimeInterval(-Self.catchUpOverlap) {
                remember(taskId: event.taskId, assignedAt: event.assignedAt, at: date, in: &state)
            }
            state.cursor = latest
            saveState(state)
            return []
        }

        let events = try await tasks.assignments(since: cursor.addingTimeInterval(-Self.catchUpOverlap))
            .sorted { $0.assignedAt < $1.assignedAt }
        var items: [Item] = []
        var batchTaskIds = Set<UUID>()
        for event in events where event.assignedBy != userId {
            guard batchTaskIds.insert(event.taskId).inserted else { continue }
            if let index = state.notified.lastIndex(where: { $0.taskId == event.taskId }) {
                let record = state.notified[index]
                let isDuplicate: Bool
                if let known = record.assignedAt {
                    isDuplicate = event.assignedAt <= known
                } else {
                    isDuplicate = event.assignedAt <= record.notifiedAt.addingTimeInterval(Self.realtimeDedupWindow)
                }
                if isDuplicate {
                    state.notified[index].assignedAt = max(record.assignedAt ?? event.assignedAt, event.assignedAt)
                    continue
                }
            }
            items.append(Item(
                taskId: event.taskId,
                groupId: event.groupId,
                title: event.taskTitle,
                groupName: event.groupName,
                assignedAt: event.assignedAt
            ))
        }

        var newCursor = max(cursor, events.last?.assignedAt ?? cursor)
        let outcome = await post(items, state: &state)
        if !outcome.authorized {
            // Not notified, but handled: the next (overlapping) catch-up must not notify them either.
            let date = now()
            for item in items where (item.assignedAt ?? .distantPast) > newCursor.addingTimeInterval(-Self.catchUpOverlap) {
                remember(taskId: item.taskId, assignedAt: item.assignedAt, at: date, in: &state)
            }
        }
        // Retried by the next catch-up, which re-reads from the cursor minus the overlap.
        if let oldestFailure = outcome.failed.compactMap(\.assignedAt).min() {
            newCursor = min(newCursor, oldestFailure)
        }
        state.cursor = newCursor
        saveState(state)
        return outcome.posted
    }

    // MARK: - Posting

    private struct PostOutcome {
        var posted: [LocalNotification] = []
        /// Items whose notification could not be added.
        var failed: [Item] = []
        var authorized = true
    }

    /// Posts `items` and remembers the posted ones.
    private func post(_ items: [Item], state: inout State) async -> PostOutcome {
        guard !items.isEmpty else { return PostOutcome() }
        guard await scheduler.authorizationStatus() == .authorized else { return PostOutcome(authorized: false) }
        let date = now()

        let isSummary = items.count > maxIndividual
        let notifications: [LocalNotification]
        if isSummary {
            let groupIds = Set(items.map(\.groupId))
            let singleGroup = groupIds.count == 1 ? groupIds.first : nil
            notifications = [LocalNotification(
                id: Self.summaryIdentifier(at: date),
                title: Self.summaryTitle,
                body: "\(items.count) nouvelles tâches assignées",
                fireDate: nil,
                userInfo: singleGroup.map { ["groupId": $0.uuidString] } ?? [:],
                threadId: singleGroup?.uuidString
            )]
        } else {
            notifications = items.map { item in
                LocalNotification(
                    id: Self.individualIdentifier(taskId: item.taskId),
                    title: Self.individualTitle,
                    body: item.groupName.flatMap { $0.isEmpty ? nil : "\(item.title) — \($0)" } ?? item.title,
                    fireDate: nil,
                    userInfo: ["taskId": item.taskId.uuidString, "groupId": item.groupId.uuidString],
                    threadId: item.groupId.uuidString
                )
            }
        }

        var outcome = PostOutcome()
        for notification in notifications {
            do {
                try await scheduler.add(notification)
                outcome.posted.append(notification)
            } catch {
                continue
            }
        }

        let postedIds = Set(outcome.posted.map(\.id))
        for item in items {
            let id = isSummary ? notifications[0].id : Self.individualIdentifier(taskId: item.taskId)
            if postedIds.contains(id) {
                remember(taskId: item.taskId, assignedAt: item.assignedAt, at: date, in: &state)
            } else {
                outcome.failed.append(item)
            }
        }
        return outcome
    }

    private func remember(taskId: UUID, assignedAt: Date?, at date: Date, in state: inout State) {
        state.notified.removeAll { $0.taskId == taskId }
        state.notified.append(State.Record(taskId: taskId, assignedAt: assignedAt, notifiedAt: date))
        if state.notified.count > rememberedLimit {
            state.notified.removeFirst(state.notified.count - rememberedLimit)
        }
    }

    // MARK: - Persistence

    private func loadState() -> State {
        store.value(State.self, forKey: Self.storageKey(userId: userId)) ?? State()
    }

    private func saveState(_ state: State) {
        store.setValue(state, forKey: Self.storageKey(userId: userId))
    }

    // MARK: - Serialization

    private func acquire() async {
        if !isBusy {
            isBusy = true
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    private func release() {
        if waiters.isEmpty {
            isBusy = false
        } else {
            waiters.removeFirst().resume()
        }
    }
}
