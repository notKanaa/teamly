import Foundation
import Testing
@testable import TeamTasksCore

// Test doubles and fixtures for the Logic suites. Names are prefixed with `Logic` so they never clash with
// helpers of other suites of this test target.

// MARK: - Fixtures

enum LogicFixtures {
    static let paris = TimeZone(identifier: "Europe/Paris")!
    static let parisCalendar = Calendar.frenchGregorian(timeZone: paris)

    static let me = UUID(uuidString: "00000000-0000-0000-0000-00000000000A")!
    static let other = UUID(uuidString: "00000000-0000-0000-0000-00000000000B")!
    static let groupA = UUID(uuidString: "00000000-0000-0000-0000-0000000000A1")!
    static let groupB = UUID(uuidString: "00000000-0000-0000-0000-0000000000B2")!

    /// A date in Europe/Paris.
    static func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0, _ minute: Int = 0, _ second: Int = 0) -> Date {
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = minute
        components.second = second
        return parisCalendar.date(from: components)!
    }

    /// Deterministic UUID from a small number.
    static func uuid(_ number: Int) -> UUID {
        let hex = String(number, radix: 16)
        let padded = String(repeating: "0", count: 12 - hex.count) + hex
        return UUID(uuidString: "10000000-0000-0000-0000-\(padded)")!
    }

    static func task(
        _ number: Int,
        title: String? = nil,
        group: UUID = groupA,
        status: TaskStatus = .todo,
        priority: TaskPriority = .medium,
        due: Date? = nil,
        createdAt: Date = LogicFixtures.date(2026, 1, 1),
        completedAt: Date? = nil,
        assignees: [UUID] = [me],
        groupName: String? = "Coloc' rue des Lilas"
    ) -> TaskItem {
        TaskItem(
            id: uuid(number),
            groupId: group,
            title: title ?? "Tâche \(number)",
            status: status,
            priority: priority,
            dueAt: due,
            createdBy: other,
            createdAt: createdAt,
            updatedAt: createdAt,
            completedAt: status == .done ? (completedAt ?? createdAt) : nil,
            assigneeIds: assignees,
            groupName: groupName
        )
    }
}

// MARK: - Waiting

enum LogicWait {
    /// Polls `condition` (yielding, then sleeping 1 ms between checks) until it holds; records an issue after
    /// `timeout`. Only used to wait for other tasks to run; never to let simulated time pass.
    @MainActor
    static func until(
        _ description: String = "condition",
        timeout: Duration = .seconds(5),
        sourceLocation: SourceLocation = #_sourceLocation,
        _ condition: () -> Bool
    ) async {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        var attempts = 0
        while !condition() {
            if ContinuousClock.now >= deadline {
                Issue.record("Timed out waiting for \(description)", sourceLocation: sourceLocation)
                return
            }
            attempts += 1
            if attempts % 20 == 0 {
                try? await Task.sleep(nanoseconds: 1_000_000)
            } else {
                await Task.yield()
            }
        }
    }

    /// Lets already-enqueued jobs run (used before asserting that something did *not* happen).
    @MainActor
    static func settle() async {
        for _ in 0..<50 {
            await Task.yield()
        }
        try? await Task.sleep(nanoseconds: 2_000_000)
        for _ in 0..<50 {
            await Task.yield()
        }
    }
}

// MARK: - Test clock

/// Manually driven `Clock`: sleepers only resume when the test calls `advance(by:)`.
final class LogicTestClock: Clock, @unchecked Sendable {
    struct Instant: InstantProtocol, Hashable {
        var offset: Swift.Duration

        func advanced(by duration: Swift.Duration) -> Instant { Instant(offset: offset + duration) }
        func duration(to other: Instant) -> Swift.Duration { other.offset - offset }
        static func < (lhs: Instant, rhs: Instant) -> Bool { lhs.offset < rhs.offset }
    }

    private struct Sleeper {
        var deadline: Instant
        var continuation: CheckedContinuation<Void, any Error>
    }

    private let lock = NSLock()
    private var current = Instant(offset: .zero)
    private var sleepers: [Int: Sleeper] = [:]
    private var cancelledBeforeRegistration: Set<Int> = []
    private var nextId = 0

    var now: Instant { lock.withLock { current } }
    var minimumResolution: Swift.Duration { .zero }

    /// Number of tasks currently sleeping on this clock.
    var sleeperCount: Int { lock.withLock { sleepers.count } }

    func sleep(until deadline: Instant, tolerance: Swift.Duration?) async throws {
        let id = lock.withLock {
            nextId += 1
            return nextId
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                lock.lock()
                if cancelledBeforeRegistration.remove(id) != nil {
                    lock.unlock()
                    continuation.resume(throwing: CancellationError())
                } else if deadline <= current {
                    lock.unlock()
                    continuation.resume()
                } else {
                    sleepers[id] = Sleeper(deadline: deadline, continuation: continuation)
                    lock.unlock()
                }
            }
        } onCancel: {
            lock.lock()
            if let sleeper = sleepers.removeValue(forKey: id) {
                lock.unlock()
                sleeper.continuation.resume(throwing: CancellationError())
            } else {
                cancelledBeforeRegistration.insert(id)
                lock.unlock()
            }
        }
    }

    /// Moves time forward and wakes the sleepers whose deadline is reached.
    func advance(by duration: Swift.Duration) {
        lock.lock()
        current = current.advanced(by: duration)
        let now = current
        let due = sleepers.filter { $0.value.deadline <= now }.sorted { $0.value.deadline < $1.value.deadline }
        for (id, _) in due {
            sleepers.removeValue(forKey: id)
        }
        lock.unlock()
        for (_, sleeper) in due {
            sleeper.continuation.resume()
        }
    }
}

// MARK: - Notification scheduler

final class LogicFakeScheduler: NotificationScheduler, @unchecked Sendable {
    struct Failure: Error {}

    private let lock = NSLock()
    private var _authorization: NotificationAuthorization
    private var _pending: [String: LocalNotification] = [:]
    private var _added: [LocalNotification] = []
    private var _removeCalls: [[String]] = []
    private var _failingIds: Set<String> = []
    private var _authorizationChecks = 0

    init(authorization: NotificationAuthorization = .authorized) {
        _authorization = authorization
    }

    var authorization: NotificationAuthorization {
        get { lock.withLock { _authorization } }
        set { lock.withLock { _authorization = newValue } }
    }

    /// Ids whose `add` throws.
    var failingIds: Set<String> {
        get { lock.withLock { _failingIds } }
        set { lock.withLock { _failingIds = newValue } }
    }

    /// Pending (scheduled, not delivered) notifications by id.
    var pending: [String: LocalNotification] { lock.withLock { _pending } }
    var pendingIds: [String] { lock.withLock { _pending.keys.sorted() } }
    /// Every successful `add`, in order.
    var added: [LocalNotification] { lock.withLock { _added } }
    var removeCalls: [[String]] { lock.withLock { _removeCalls } }
    var authorizationChecks: Int { lock.withLock { _authorizationChecks } }

    /// Simulates an already-pending request (e.g. scheduled by a previous launch).
    func seedPending(_ notification: LocalNotification) {
        lock.withLock { _pending[notification.id] = notification }
    }

    func resetCallLog() {
        lock.withLock {
            _added = []
            _removeCalls = []
        }
    }

    func authorizationStatus() async -> NotificationAuthorization {
        lock.withLock {
            _authorizationChecks += 1
            return _authorization
        }
    }

    func requestAuthorization() async -> Bool {
        lock.withLock { _authorization == .authorized }
    }

    func pendingIdentifiers(prefix: String) async -> [String] {
        lock.withLock { _pending.keys.filter { $0.hasPrefix(prefix) }.sorted() }
    }

    func add(_ notification: LocalNotification) async throws {
        try lock.withLock {
            if _failingIds.contains(notification.id) { throw Failure() }
            _added.append(notification)
            // "Deliver now" requests are shown immediately and never stay pending.
            if notification.fireDate != nil {
                _pending[notification.id] = notification
            }
        }
    }

    func removePending(ids: [String]) async {
        lock.withLock {
            _removeCalls.append(ids)
            for id in ids {
                _pending.removeValue(forKey: id)
            }
        }
    }

    func setBadge(_ count: Int) async {}
}

/// Scheduler whose n-th `add` call (1-based) can be held until the test opens it, to reproduce interleavings
/// of concurrent callers. A held request is registered when released (like a late UNUserNotificationCenter call).
final class LogicGatedScheduler: NotificationScheduler, @unchecked Sendable {
    private let lock = NSLock()
    private var _pending: [String: LocalNotification] = [:]
    private var addCalls = 0
    private let gatedCalls: Set<Int>
    private var waiting: [Int: CheckedContinuation<Void, Never>] = [:]

    init(gatedCalls: Set<Int>) {
        self.gatedCalls = gatedCalls
    }

    var pending: [String: LocalNotification] { lock.withLock { _pending } }
    /// Calls currently held.
    var waitingCalls: Set<Int> { lock.withLock { Set(waiting.keys) } }
    var addCallCount: Int { lock.withLock { addCalls } }

    /// Releases the held call `call`.
    func open(_ call: Int) {
        let continuation = lock.withLock { waiting.removeValue(forKey: call) }
        continuation?.resume()
    }

    func authorizationStatus() async -> NotificationAuthorization { .authorized }
    func requestAuthorization() async -> Bool { true }

    func pendingIdentifiers(prefix: String) async -> [String] {
        lock.withLock { _pending.keys.filter { $0.hasPrefix(prefix) }.sorted() }
    }

    func add(_ notification: LocalNotification) async throws {
        let call = lock.withLock {
            addCalls += 1
            return addCalls
        }
        if gatedCalls.contains(call) {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                lock.withLock { waiting[call] = continuation }
            }
        }
        lock.withLock { _pending[notification.id] = notification }
    }

    func removePending(ids: [String]) async {
        lock.withLock {
            for id in ids {
                _pending.removeValue(forKey: id)
            }
        }
    }

    func setBadge(_ count: Int) async {}
}

// MARK: - Task service

final class LogicFakeTaskService: TaskService, @unchecked Sendable {
    private let lock = NSLock()
    private var _tasks: [UUID: TaskItem] = [:]
    private var _assignments: [AssignmentEvent] = []
    private var _assignmentsError: AppError?
    private var _lookups: [UUID] = []
    private var _sinceCalls: [Date] = []

    func put(_ task: TaskItem) {
        lock.withLock { _tasks[task.id] = task }
    }

    func removeTask(id: UUID) {
        lock.withLock { _tasks[id] = nil }
    }

    /// Server-side assignment rows returned by `assignments(since:)` (filtered on `assignedAt > since` only,
    /// so tests can check that the notifier also ignores self-assignments).
    var assignmentEvents: [AssignmentEvent] {
        get { lock.withLock { _assignments } }
        set { lock.withLock { _assignments = newValue } }
    }

    var assignmentsError: AppError? {
        get { lock.withLock { _assignmentsError } }
        set { lock.withLock { _assignmentsError = newValue } }
    }

    var lookups: [UUID] { lock.withLock { _lookups } }
    var sinceCalls: [Date] { lock.withLock { _sinceCalls } }

    func task(id: UUID) async throws -> TaskItem {
        try lock.withLock {
            _lookups.append(id)
            guard let task = _tasks[id] else { throw AppError.notFound }
            return task
        }
    }

    func assignments(since: Date) async throws -> [AssignmentEvent] {
        try lock.withLock {
            _sinceCalls.append(since)
            if let error = _assignmentsError { throw error }
            return _assignments.filter { $0.assignedAt > since }.sorted { $0.assignedAt < $1.assignedAt }
        }
    }

    func tasks(groupId: UUID, includeOldDone: Bool) async throws -> [TaskItem] { throw AppError.unknown("non utilisé") }
    func myTasks(includeDone: Bool) async throws -> [TaskItem] { throw AppError.unknown("non utilisé") }
    func create(groupId: UUID, draft: TaskDraft) async throws -> TaskItem { throw AppError.unknown("non utilisé") }
    func update(taskId: UUID, draft: TaskDraft) async throws -> TaskItem { throw AppError.unknown("non utilisé") }
    func setStatus(taskId: UUID, status: TaskStatus) async throws -> TaskItem { throw AppError.unknown("non utilisé") }
    func delete(taskId: UUID) async throws { throw AppError.unknown("non utilisé") }
    func addChecklistItem(taskId: UUID, title: String) async throws -> ChecklistItem { throw AppError.unknown("non utilisé") }
    func renameChecklistItem(itemId: UUID, title: String) async throws -> ChecklistItem { throw AppError.unknown("non utilisé") }
    func setChecklistItemDone(itemId: UUID, done: Bool) async throws -> ChecklistItem { throw AppError.unknown("non utilisé") }
    func deleteChecklistItem(itemId: UUID) async throws { throw AppError.unknown("non utilisé") }
    func completions(groupId: UUID, since: Date) async throws -> [TaskCompletion] { throw AppError.unknown("non utilisé") }
}

// MARK: - Realtime service

final class LogicFakeRealtime: RealtimeService, @unchecked Sendable {
    struct Subscription {
        var userId: UUID
        var groupIds: [UUID]
        var continuation: AsyncStream<RealtimeEvent>.Continuation
        var terminated = false
    }

    private let lock = NSLock()
    private var subscriptions: [Subscription] = []

    func events(userId: UUID, groupIds: [UUID]) -> AsyncStream<RealtimeEvent> {
        let (stream, continuation) = AsyncStream.makeStream(of: RealtimeEvent.self)
        let index = lock.withLock {
            subscriptions.append(Subscription(userId: userId, groupIds: groupIds, continuation: continuation))
            return subscriptions.count - 1
        }
        continuation.onTermination = { [weak self] _ in
            self?.lock.withLock { self?.subscriptions[index].terminated = true }
        }
        return stream
    }

    var subscriptionCount: Int { lock.withLock { subscriptions.count } }

    func groupIds(of index: Int) -> [UUID] { lock.withLock { subscriptions[index].groupIds } }
    func userId(of index: Int) -> UUID { lock.withLock { subscriptions[index].userId } }
    func isTerminated(_ index: Int) -> Bool { lock.withLock { subscriptions[index].terminated } }

    /// Sends an event on the latest subscription.
    func send(_ event: RealtimeEvent) {
        let continuation = lock.withLock { subscriptions.last?.continuation }
        continuation?.yield(event)
    }

    /// Ends the latest stream from the server side (connection lost).
    func finishLatest() {
        let continuation = lock.withLock { subscriptions.last?.continuation }
        continuation?.finish()
    }
}

// MARK: - Group ids provider

final class LogicGroupIdsSource: @unchecked Sendable {
    private let lock = NSLock()
    private var _ids: [UUID]
    private var _calls = 0
    private var _fails = false

    init(_ ids: [UUID]) {
        _ids = ids
    }

    var ids: [UUID] {
        get { lock.withLock { _ids } }
        set { lock.withLock { _ids = newValue } }
    }

    var fails: Bool {
        get { lock.withLock { _fails } }
        set { lock.withLock { _fails = newValue } }
    }

    var calls: Int { lock.withLock { _calls } }

    func fetch() throws -> [UUID] {
        try lock.withLock {
            _calls += 1
            if _fails { throw AppError.network }
            return _ids
        }
    }
}

/// Collects forwarded assignments.
final class LogicAssignmentSink: @unchecked Sendable {
    private let lock = NSLock()
    private var _received: [RealtimeAssignment] = []

    var received: [RealtimeAssignment] { lock.withLock { _received } }

    func receive(_ assignment: RealtimeAssignment) {
        lock.withLock { _received.append(assignment) }
    }
}

/// Mutable "now" shared with the code under test.
final class LogicNow: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: Date

    init(_ value: Date) {
        _value = value
    }

    var value: Date {
        get { lock.withLock { _value } }
        set { lock.withLock { _value = newValue } }
    }

    var provider: NowProvider { { [self] in value } }
}
