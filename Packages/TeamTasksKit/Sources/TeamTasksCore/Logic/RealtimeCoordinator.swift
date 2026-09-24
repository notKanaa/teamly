import Foundation

/// Consumes `RealtimeService.events(userId:groupIds:)` and turns the change signals into `ChangeFeed` bumps.
///
/// - `.connected` (first subscription and every reconnection) → `bumpAll()` immediately; pending
///   debounced bumps are dropped since they are covered. On a reconnection (a later `.connected` of the same
///   subscription), or while the group ids are stale, the group ids are fetched again: a membership change may
///   have been missed while the socket was down.
/// - `.groupActivity(g)` → bump of group `g` and of "Mes tâches" (an edit, a status change or an
///   unassignment in `g` may affect my tasks; unassignments only surface as group activity).
/// - `.membershipsChanged` → `bumpMemberships()` + `bumpMyTasks()`, then the group ids are fetched again.
/// - `.assigned` → `bumpMyTasks()` and the signal is forwarded, in order, to `onAssigned`
///   (typically `AssignmentNotifier.handleRealtime`), without blocking the event loop.
///
/// Every fetch of the group ids (`refreshGroupIds()`) re-subscribes the channel when the ids changed. A failed
/// fetch leaves the ids stale (`groupIdsAreStale`): it is retried on the next `.connected` and after
/// `retryDelay`, doubled after each failure up to `maxGroupIdsRetryDelay`. Without this, a cold start offline
/// (or a failed fetch after joining a group) would leave groups without live updates for the whole session,
/// since the Supabase stream never ends by itself.
///
/// Bumps are debounced per key (each group, memberships, my tasks): the first signal of a key opens a
/// window of `debounce` (300 ms by default) and every signal of that key received during the window is
/// coalesced into one bump at its end, so a burst never delays a reload by more than `debounce`.
/// The clock is injectable, so tests control time.
///
/// If the stream ends on its own (connection lost for good), the coordinator re-subscribes after
/// `retryDelay`. `stop()` (or releasing the coordinator) cancels everything and ends the stream.
@MainActor
public final class RealtimeCoordinator {
    /// Returns the ids of the current user's groups (e.g. `GroupService.myGroups()`).
    public typealias GroupIdsProvider = @Sendable () async throws -> [UUID]
    public typealias AssignmentHandler = @Sendable (RealtimeAssignment) async -> Void

    public static let defaultDebounce: Duration = .milliseconds(300)
    public static let defaultRetryDelay: Duration = .seconds(5)
    /// Longest wait between two attempts to fetch stale group ids.
    public static let maxGroupIdsRetryDelay: Duration = .seconds(60)

    /// Debounce key.
    enum BumpKey: Hashable, Sendable {
        case group(UUID)
        case memberships
        case myTasks
    }

    private let realtime: any RealtimeService
    private let userId: UUID
    private let feed: ChangeFeed
    private let groupIdsProvider: GroupIdsProvider
    private let onAssigned: AssignmentHandler?
    private let debounce: Duration
    private let retryDelay: Duration
    private let sleep: @Sendable (Duration) async throws -> Void
    /// Cancels the long-running tasks if the coordinator is released without `stop()`.
    private let lifetime = TaskCanceller()

    private var runTask: Task<Void, Never>?
    private var handlerTask: Task<Void, Never>?
    private var handlerContinuation: AsyncStream<RealtimeAssignment>.Continuation?
    private var refreshTask: Task<Void, Never>?
    /// A refresh was requested while one was running: run another one when it ends.
    private var refreshRequested = false
    private var groupIdsRetryTask: Task<Void, Never>?
    private var groupIdsFailures = 0
    private var pendingBumps: [BumpKey: (token: Int, task: Task<Void, Never>)] = [:]
    /// Changes on every `start()` and `stop()`: work of an earlier run never acts on a later one.
    private var runId = 0
    /// Changes on every subscription (and on `stop()`): events of a replaced subscription are ignored.
    private var generation = 0
    private var nextToken = 0
    /// The current subscription already received `.connected`: the next one is a reconnection.
    private var connectedOnCurrentSubscription = false

    /// Group ids of the current subscription (sorted), empty when stopped.
    public private(set) var subscribedGroupIds: [UUID] = []
    /// True when the last fetch of the group ids failed: the subscription may miss some groups until a fetch
    /// succeeds (retried on `.connected`, after a delay, and by `refreshGroupIds()`).
    public private(set) var groupIdsAreStale = false
    /// Number of events handled (diagnostics and tests).
    public private(set) var handledEventCount = 0

    public var isRunning: Bool { runTask != nil }

    /// Keys with a debounced bump waiting for the end of its window (tests).
    var pendingBumpKeys: Set<BumpKey> { Set(pendingBumps.keys) }

    /// - Parameters:
    ///   - groupIds: fetches the current group ids (initial subscription unless given to `start`, after
    ///     `.membershipsChanged`, on reconnection and while they are stale).
    ///   - clock: drives debouncing and retries (a test clock makes tests instant).
    ///   - onAssigned: receives every `.assigned` signal, in order.
    public init<C: Clock>(
        realtime: any RealtimeService,
        userId: UUID,
        feed: ChangeFeed,
        groupIds: @escaping GroupIdsProvider,
        debounce: Duration = RealtimeCoordinator.defaultDebounce,
        retryDelay: Duration = RealtimeCoordinator.defaultRetryDelay,
        clock: C,
        onAssigned: AssignmentHandler? = nil
    ) where C.Duration == Duration {
        self.realtime = realtime
        self.userId = userId
        self.feed = feed
        groupIdsProvider = groupIds
        self.onAssigned = onAssigned
        self.debounce = max(debounce, .zero)
        self.retryDelay = max(retryDelay, .zero)
        sleep = { duration in try await clock.sleep(for: duration) }
    }

    /// Same, with the real `ContinuousClock`.
    public convenience init(
        realtime: any RealtimeService,
        userId: UUID,
        feed: ChangeFeed,
        groupIds: @escaping GroupIdsProvider,
        debounce: Duration = RealtimeCoordinator.defaultDebounce,
        retryDelay: Duration = RealtimeCoordinator.defaultRetryDelay,
        onAssigned: AssignmentHandler? = nil
    ) {
        self.init(
            realtime: realtime,
            userId: userId,
            feed: feed,
            groupIds: groupIds,
            debounce: debounce,
            retryDelay: retryDelay,
            clock: ContinuousClock(),
            onAssigned: onAssigned
        )
    }

    deinit {
        lifetime.cancelAll()
    }

    // MARK: - Lifecycle

    /// Starts listening. No-op when already running.
    /// - Parameter groupIds: initial group ids if already known; otherwise the provider is called.
    public func start(groupIds initialGroupIds: [UUID]? = nil) {
        guard runTask == nil else { return }
        runId &+= 1

        if let onAssigned {
            let (stream, continuation) = AsyncStream.makeStream(of: RealtimeAssignment.self)
            handlerContinuation = continuation
            handlerTask = Task {
                for await assignment in stream {
                    await onAssigned(assignment)
                }
            }
        }
        runSubscriptions(groupIds: initialGroupIds)
    }

    /// Stops listening: ends the realtime stream, drops pending bumps and cancels the assignment handler.
    /// `start()` can be called again afterwards.
    public func stop() {
        runId &+= 1
        generation &+= 1
        runTask?.cancel()
        runTask = nil
        refreshTask?.cancel()
        refreshTask = nil
        refreshRequested = false
        groupIdsRetryTask?.cancel()
        groupIdsRetryTask = nil
        groupIdsFailures = 0
        groupIdsAreStale = false
        handlerContinuation?.finish()
        handlerContinuation = nil
        handlerTask?.cancel()
        handlerTask = nil
        cancelPendingBumps()
        subscribedGroupIds = []
        connectedOnCurrentSubscription = false
        lifetime.replace(with: [])
    }

    /// Fetches the group ids again and re-subscribes when they changed (e.g. on return to the foreground).
    /// Concurrent requests are coalesced. No-op when stopped.
    public func refreshGroupIds() {
        guard runTask != nil else { return }
        guard refreshTask == nil else {
            refreshRequested = true
            return
        }
        let currentRun = runId
        refreshTask = Task { [weak self] in
            await self?.performRefreshes(run: currentRun)
        }
        updateLifetime()
    }

    // MARK: - Subscription loop

    /// (Re)starts the subscription loop: with `groupIds`, or with ids fetched first.
    private func runSubscriptions(groupIds initialGroupIds: [UUID]?) {
        runTask?.cancel()
        generation &+= 1
        let currentGeneration = generation
        let currentRun = runId
        let realtime = realtime
        let userId = userId
        let sleep = sleep
        let retryDelay = retryDelay
        runTask = Task { [weak self] in
            var ids: [UUID]
            if let initialGroupIds {
                ids = initialGroupIds
            } else {
                ids = await self?.fetchGroupIds(run: currentRun, fallback: []) ?? []
            }

            while !Task.isCancelled {
                ids = RealtimeCoordinator.normalized(ids)
                guard self?.willSubscribe(to: ids, generation: currentGeneration) == true else { return }
                // The stream is scoped to one iteration: leaving it releases the stream, which terminates it.
                let stream = realtime.events(userId: userId, groupIds: ids)
                for await event in stream {
                    guard self?.handle(event, generation: currentGeneration) == true else { return }
                }

                // The stream ended by itself: retry later with fresh group ids.
                if Task.isCancelled { return }
                do {
                    try await sleep(retryDelay)
                } catch {
                    return
                }
                ids = await self?.fetchGroupIds(run: currentRun, fallback: ids) ?? ids
            }
        }
        updateLifetime()
    }

    private func willSubscribe(to groupIds: [UUID], generation expected: Int) -> Bool {
        guard expected == generation else { return false }
        subscribedGroupIds = groupIds
        connectedOnCurrentSubscription = false
        return true
    }

    // MARK: - Group ids

    /// Calls the provider; on failure returns `fallback` and marks the ids stale (retried later).
    private func fetchGroupIds(run: Int, fallback: [UUID]) async -> [UUID] {
        do {
            let ids = try await groupIdsProvider()
            if run == runId { groupIdsDidLoad() }
            return ids
        } catch {
            if run == runId { groupIdsDidFail() }
            return fallback
        }
    }

    private func performRefreshes(run: Int) async {
        repeat {
            refreshRequested = false
            let fresh: [UUID]
            do {
                fresh = try await groupIdsProvider()
            } catch {
                guard run == runId else { return }
                groupIdsDidFail()
                continue
            }
            guard run == runId else { return }
            groupIdsDidLoad()
            let normalizedFresh = RealtimeCoordinator.normalized(fresh)
            if normalizedFresh != subscribedGroupIds {
                runSubscriptions(groupIds: normalizedFresh)
            }
        } while refreshRequested && run == runId && !Task.isCancelled
        if run == runId {
            refreshTask = nil
            updateLifetime()
        }
    }

    private func groupIdsDidLoad() {
        groupIdsAreStale = false
        groupIdsFailures = 0
        groupIdsRetryTask?.cancel()
        groupIdsRetryTask = nil
    }

    /// Marks the ids stale and schedules one retry (`retryDelay`, doubled after each failure, capped).
    private func groupIdsDidFail() {
        groupIdsAreStale = true
        groupIdsFailures += 1
        guard runTask != nil, groupIdsRetryTask == nil else { return }
        let exponent = min(groupIdsFailures - 1, 16)
        let delay = min(retryDelay * (1 << exponent), max(retryDelay, Self.maxGroupIdsRetryDelay))
        let sleep = sleep
        let currentRun = runId
        groupIdsRetryTask = Task { [weak self] in
            do {
                try await sleep(delay)
            } catch {
                return
            }
            guard let self, self.runId == currentRun else { return }
            self.groupIdsRetryTask = nil
            self.refreshGroupIds()
        }
        updateLifetime()
    }

    // MARK: - Events

    /// Handles one event of the current subscription. Returns false when the subscription was replaced or stopped.
    private func handle(_ event: RealtimeEvent, generation expected: Int) -> Bool {
        guard expected == generation else { return false }
        handledEventCount += 1
        switch event {
        case .connected:
            cancelPendingBumps()
            feed.bumpAll()
            let isReconnection = connectedOnCurrentSubscription
            connectedOnCurrentSubscription = true
            if isReconnection || groupIdsAreStale {
                refreshGroupIds()
            }
        case let .groupActivity(groupId):
            scheduleBump(.group(groupId))
            scheduleBump(.myTasks)
        case .membershipsChanged:
            scheduleBump(.memberships)
            scheduleBump(.myTasks)
            refreshGroupIds()
        case let .assigned(taskId, groupId, assignedBy):
            scheduleBump(.myTasks)
            handlerContinuation?.yield(RealtimeAssignment(taskId: taskId, groupId: groupId, assignedBy: assignedBy))
        }
        return true
    }

    // MARK: - Debounce

    private func scheduleBump(_ key: BumpKey) {
        guard pendingBumps[key] == nil else { return }
        nextToken &+= 1
        let token = nextToken
        let sleep = sleep
        let interval = debounce
        let task = Task { [weak self] in
            do {
                try await sleep(interval)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            self?.fireBump(key, token: token)
        }
        pendingBumps[key] = (token, task)
    }

    private func fireBump(_ key: BumpKey, token: Int) {
        guard let entry = pendingBumps[key], entry.token == token else { return }
        pendingBumps[key] = nil
        switch key {
        case let .group(groupId): feed.bump(groupId: groupId)
        case .memberships: feed.bumpMemberships()
        case .myTasks: feed.bumpMyTasks()
        }
    }

    private func cancelPendingBumps() {
        for entry in pendingBumps.values {
            entry.task.cancel()
        }
        pendingBumps.removeAll()
    }

    private func updateLifetime() {
        lifetime.replace(with: [runTask, handlerTask, refreshTask, groupIdsRetryTask].compactMap { $0 })
    }

    private static func normalized(_ ids: [UUID]) -> [UUID] {
        Set(ids).sorted { $0.uuidString < $1.uuidString }
    }
}

/// Thread-safe holder of tasks to cancel from a nonisolated `deinit`.
final class TaskCanceller: @unchecked Sendable {
    private let lock = NSLock()
    private var tasks: [Task<Void, Never>] = []

    func replace(with tasks: [Task<Void, Never>]) {
        lock.withLock { self.tasks = tasks }
    }

    func cancelAll() {
        let tasks = lock.withLock {
            let current = self.tasks
            self.tasks = []
            return current
        }
        for task in tasks {
            task.cancel()
        }
    }
}
