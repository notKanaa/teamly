import Foundation

/// Consumes `RealtimeService.events(userId:groupIds:)` and turns the change signals into `ChangeFeed` bumps.
///
/// - `.connected` (first subscription and every reconnection) → `bumpAll()` immediately; pending
///   debounced bumps are dropped since they are covered.
/// - `.groupActivity(g)` → bump of group `g` and of "Mes tâches" (an edit, a status change or an
///   unassignment in `g` may affect my tasks; unassignments only surface as group activity).
/// - `.membershipsChanged` → `bumpMemberships()` + `bumpMyTasks()`, then the group ids are fetched again
///   and, if they changed, the channel is re-subscribed with them.
/// - `.assigned` → `bumpMyTasks()` and the signal is forwarded, in order, to `onAssigned`
///   (typically `AssignmentNotifier.handleRealtime`), without blocking the event loop.
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

    /// Debounce key.
    enum BumpKey: Hashable, Sendable {
        case group(UUID)
        case memberships
        case myTasks
    }

    private enum Disposition {
        case keep
        case refreshGroups
        case stop
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
    private var pendingBumps: [BumpKey: (token: Int, task: Task<Void, Never>)] = [:]
    private var generation = 0
    private var nextToken = 0

    /// Group ids of the current subscription (sorted), empty when stopped.
    public private(set) var subscribedGroupIds: [UUID] = []
    /// Number of events handled (diagnostics and tests).
    public private(set) var handledEventCount = 0

    public var isRunning: Bool { runTask != nil }

    /// Keys with a debounced bump waiting for the end of its window (tests).
    var pendingBumpKeys: Set<BumpKey> { Set(pendingBumps.keys) }

    /// - Parameters:
    ///   - groupIds: fetches the current group ids (initial subscription unless given to `start`, and
    ///     after `.membershipsChanged`).
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
        generation &+= 1
        let currentGeneration = generation

        if let onAssigned {
            let (stream, continuation) = AsyncStream.makeStream(of: RealtimeAssignment.self)
            handlerContinuation = continuation
            handlerTask = Task {
                for await assignment in stream {
                    await onAssigned(assignment)
                }
            }
        }

        let realtime = realtime
        let userId = userId
        let provider = groupIdsProvider
        let sleep = sleep
        let retryDelay = retryDelay
        runTask = Task { [weak self] in
            var ids: [UUID]
            if let initialGroupIds {
                ids = initialGroupIds
            } else {
                ids = (try? await provider()) ?? []
            }

            subscriptions: while !Task.isCancelled {
                ids = RealtimeCoordinator.normalized(ids)
                guard self?.willSubscribe(to: ids, generation: currentGeneration) == true else { return }
                // The stream is scoped to one iteration: leaving it releases the stream, which terminates it.
                let stream = realtime.events(userId: userId, groupIds: ids)
                for await event in stream {
                    switch self?.handle(event, generation: currentGeneration) ?? .stop {
                    case .stop:
                        return
                    case .keep:
                        continue
                    case .refreshGroups:
                        guard let fresh = try? await provider() else { continue }
                        if Task.isCancelled { return }
                        let normalizedFresh = RealtimeCoordinator.normalized(fresh)
                        if normalizedFresh != ids {
                            ids = normalizedFresh
                            continue subscriptions
                        }
                    }
                }

                // The stream ended by itself: retry later with fresh group ids.
                if Task.isCancelled { return }
                do {
                    try await sleep(retryDelay)
                } catch {
                    return
                }
                if let fresh = try? await provider() {
                    ids = fresh
                }
            }
        }
        lifetime.replace(with: [runTask, handlerTask].compactMap { $0 })
    }

    /// Stops listening: ends the realtime stream, drops pending bumps and cancels the assignment handler.
    /// `start()` can be called again afterwards.
    public func stop() {
        generation &+= 1
        runTask?.cancel()
        runTask = nil
        handlerContinuation?.finish()
        handlerContinuation = nil
        handlerTask?.cancel()
        handlerTask = nil
        cancelPendingBumps()
        subscribedGroupIds = []
        lifetime.replace(with: [])
    }

    // MARK: - Events

    private func willSubscribe(to groupIds: [UUID], generation expected: Int) -> Bool {
        guard expected == generation else { return false }
        subscribedGroupIds = groupIds
        return true
    }

    private func handle(_ event: RealtimeEvent, generation expected: Int) -> Disposition {
        guard expected == generation else { return .stop }
        handledEventCount += 1
        switch event {
        case .connected:
            cancelPendingBumps()
            feed.bumpAll()
            return .keep
        case let .groupActivity(groupId):
            scheduleBump(.group(groupId))
            scheduleBump(.myTasks)
            return .keep
        case .membershipsChanged:
            scheduleBump(.memberships)
            scheduleBump(.myTasks)
            return .refreshGroups
        case let .assigned(taskId, groupId, assignedBy):
            scheduleBump(.myTasks)
            handlerContinuation?.yield(RealtimeAssignment(taskId: taskId, groupId: groupId, assignedBy: assignedBy))
            return .keep
        }
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
