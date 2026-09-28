import Foundation
import Observation

/// v3 « Échanger mon tour » (docs/CONTRACTS-V3.md §3): the turns proposed to the current user, waiting for their answer,
/// with « Accepter » and « Refuser ». On « Mes tâches » (every group) and on a group screen (`groupId`).
///
/// Reads `TaskService.pendingTurnSwaps()` and keeps the proposals made to the user, then, for each one, its task (title,
/// due date), the proposer (the members of its group) and, on « Mes tâches », its group (name and badge). A task that
/// can no longer be read leaves its proposal without a title. A failed read shows nothing (the screen has more
/// important content) and is retried at the next signal.
///
/// Reloads on « Mes tâches »'s revision (every swap signal bumps it) and, for a group, on the group's revision.
/// View: `.task(id: model.refreshKey) { await model.load() }`.
@MainActor
@Observable
public final class TurnSwapRequestsViewModel: ErrorPresenting {
    /// nil: every group (« Mes tâches »).
    public let groupId: UUID?
    /// The proposals, oldest first.
    public private(set) var requests: [TurnSwapRequest] = []
    public private(set) var loadState: LoadState = .idle
    /// Proposals being answered.
    public private(set) var busySwapIds: Set<UUID> = []
    /// The confirmation of the last answer (« Tu prends le tour de Lucas »).
    public var toast: ToastNotice?
    public var error: ErrorState?

    public let session: SessionModel
    private let runner = LoadRunner()
    private var loadedRevision: Int?
    private var fetchingRevision: Int?

    public init(session: SessionModel, groupId: UUID? = nil) {
        self.session = session
        self.groupId = groupId
    }

    // MARK: - Loading

    public var refreshKey: RefreshKey {
        RefreshKey(revision: session.feed.myTasksRevision &+ (groupId.map { session.feed.groupRevision($0) } ?? 0))
    }

    public var needsRefresh: Bool { loadState != .loaded || loadedRevision != refreshKey.revision }

    public func load() async {
        guard needsRefresh else { return }
        let upToDate = runner.isRunning && fetchingRevision == refreshKey.revision
        await runner.run(rerunIfRunning: !upToDate) { [weak self] in await self?.fetch() }
    }

    public func reload() async {
        await runner.run(rerunIfRunning: true) { [weak self] in await self?.fetch() }
    }

    private func fetch() async {
        let revision = refreshKey.revision
        fetchingRevision = revision
        defer { fetchingRevision = nil }
        if loadState != .loaded { loadState = .loading }
        let me = session.userId
        let groupId = groupId
        let services = session.services
        do {
            let pending = try await services.tasks.pendingTurnSwaps().filter { swap in
                TaskPermissions.canRespond(to: swap, userId: me) && (groupId == nil || swap.groupId == groupId)
            }
            var built: [Built] = []
            if !pending.isEmpty {
                built = try await Self.requests(
                    for: TurnSwap.sorted(pending), services: services, userId: me, showsGroup: groupId == nil
                )
            }
            let now = session.platform.now()
            let calendar = session.platform.calendar
            requests = built.map { item in
                var request = item.request
                request.dueText = item.dueDate.map { DateText.relative($0, now: now, calendar: calendar) }
                return request
            }
            loadedRevision = revision
            loadState = .loaded
        } catch {
            // Secondary content: nothing to show, no alert.
            if ErrorState.isCancellation(error) {
                if loadState == .loading { loadState = .idle }
                return
            }
            requests = []
            loadState = .failed(AppError.wrap(error).messageFR)
        }
    }

    /// A request and the due date of its task (its text is made by the view model, which knows today).
    private struct Built: Sendable {
        var request: TurnSwapRequest
        var dueDate: Date?
    }

    /// Reads the tasks, the members and the groups of `swaps` in parallel.
    private nonisolated static func requests(
        for swaps: [TurnSwap],
        services: AppServices,
        userId: UUID,
        showsGroup: Bool
    ) async throws -> [Built] {
        let groupIds = Array(Set(swaps.map(\.groupId)))
        let taskIds = Array(Set(swaps.map(\.taskId)))
        async let groupsRequest: [GroupSummary] = showsGroup ? services.groups.myGroups() : []
        let members = try await withThrowingTaskGroup(
            of: (UUID, [Membership]).self,
            returning: [UUID: [Membership]].self
        ) { group in
            for groupId in groupIds {
                group.addTask { (groupId, try await services.groups.members(groupId: groupId)) }
            }
            var result: [UUID: [Membership]] = [:]
            for try await (groupId, list) in group {
                result[groupId] = list
            }
            return result
        }
        let tasks = await withTaskGroup(of: (UUID, TaskItem?).self, returning: [UUID: TaskItem].self) { group in
            for taskId in taskIds {
                group.addTask { (taskId, try? await services.tasks.task(id: taskId)) }
            }
            var result: [UUID: TaskItem] = [:]
            for await (taskId, task) in group {
                if let task { result[taskId] = task }
            }
            return result
        }
        let groups = try await groupsRequest
        return swaps.map { swap in
            let directory = MemberDirectory(members: members[swap.groupId] ?? [], currentUserId: userId)
            let task = tasks[swap.taskId]
            let group = groups.first { $0.id == swap.groupId }?.group
            return Built(
                request: TurnSwapRequest(
                    swap: swap,
                    from: directory.badge(of: swap.fromUserId),
                    taskTitle: task?.title,
                    groupName: group?.name,
                    groupAppearance: group?.appearance
                ),
                dueDate: task?.dueAt
            )
        }
    }

    // MARK: - Display

    public var isEmpty: Bool { requests.isEmpty }

    /// Something to show: a proposal, the confirmation of an answer, or why an answer failed.
    public var hasContent: Bool { !requests.isEmpty || toast != nil || error != nil }

    /// « Échanges de tour ».
    public static let title = TurnSwapText.requestsTitle

    // MARK: - Actions

    /// Accepts or declines a proposal: it leaves the list; `toast` « Tu prends le tour de Lucas » or « Proposition de
    /// Lucas refusée ». A proposal no longer pending (withdrawn, or the task changed) leaves the list with `error`.
    @discardableResult
    public func respond(to request: TurnSwapRequest, accept: Bool) async -> Bool {
        guard !busySwapIds.contains(request.id) else { return false }
        error = nil
        busySwapIds.insert(request.id)
        defer { busySwapIds.remove(request.id) }
        let name = request.from.shortName
        do {
            _ = try await session.services.tasks.respondToTurnSwap(swapId: request.id, accept: accept)
            requests.removeAll { $0.id == request.id }
            toast = accept
                ? ToastNotice(TurnSwapText.acceptedMessage(from: name), systemImage: "arrow.left.arrow.right")
                : ToastNotice(TurnSwapText.declinedMessage(from: name), systemImage: "xmark")
            didRespond(in: request.groupId)
            return true
        } catch {
            switch present(error) {
            case .swapNotPending?, .notFound?, .forbidden?, .invalidRotation?:
                requests.removeAll { $0.id == request.id }
                didRespond(in: request.groupId)
            default:
                break
            }
            return false
        }
    }

    /// The group's screens and « Mes tâches » show the new turn.
    private func didRespond(in groupId: UUID) {
        session.feed.bump(groupId: groupId)
        session.feed.bumpMyTasks()
    }
}
