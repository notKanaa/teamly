import Foundation
import TeamTasksContract
import TeamTasksCore
import TeamTasksMocks
import Testing

/// Deliberate misbehaviours injected around the mock services. A contract scenario that still passes on a
/// misbehaving backend would not protect the Supabase adapters, so each mutation must be detected.
enum ScenarioMutation: String, CaseIterable, Sendable, CustomTestStringConvertible {
    /// A non-member renaming an existing group gets `.notFound` (lead decision: `.forbidden`).
    case renameNonMemberNotFound
    /// Renaming an unknown group gives `.forbidden` (lead decision: `.notFound`).
    case renameUnknownForbidden
    case deleteNonMemberNotFound
    case deleteUnknownForbidden
    /// Non-members reading members / tasks get an error instead of an empty list.
    case nonMemberReadsThrow
    /// `regenerate_invite_code`, `set_member_role`, `remove_member` on an unknown group → `.notFound`
    /// (lead decision: `.forbidden`).
    case unknownGroupNotFound
    /// An RPC called without a session → `.forbidden` (contract: `.notAuthenticated`).
    case signedOutForbidden
    /// Every subscriber receives `.assigned` for every new assignment (missing `user_id=eq.<me>` filter).
    case assignedToEveryone
    /// Every subscriber receives `.membershipsChanged` for everyone's membership changes (missing `id=eq.<me>`).
    case membershipsChangedToEveryone
    /// Subscribers receive `.groupActivity` for groups of their filter they are not a member of (no RLS).
    case activityToNonMembers
    /// Real-server race: changes committed before the subscription arrive after `.connected` (released on the
    /// first write that follows); combined with `create_task` emitting no signal.
    case staleEventsAndSilentTaskCreation

    var testDescription: String { rawValue }
}

/// `MockHarness` whose users' services are wrapped by decorators applying one mutation (none: transparent).
struct MutationHarness: ContractHarness {
    let base = MockHarness()
    let registry: MutationRegistry

    init(_ mutation: ScenarioMutation?) {
        registry = MutationRegistry(mutation: mutation)
    }

    func makeUser(displayName: String) async throws -> ContractUser {
        let user = try await base.makeUser(displayName: displayName)
        let plain = user.services
        let services = AppServices(
            auth: plain.auth,
            profiles: MutatedProfileService(base: plain.profiles, registry: registry),
            groups: MutatedGroupService(base: plain.groups, registry: registry),
            tasks: MutatedTaskService(base: plain.tasks, groups: plain.groups, owner: user.id, registry: registry),
            realtime: MutatedRealtimeService(base: plain.realtime, owner: user.id, registry: registry),
            push: plain.push
        )
        return ContractUser(
            authUser: user.authUser, displayName: user.displayName, email: user.email, password: user.password, services: services
        )
    }
}

/// Shared state of the decorated services of one harness: known groups and live Realtime subscriptions.
final class MutationRegistry: @unchecked Sendable {
    struct Subscription {
        let owner: UUID
        let groupIds: [UUID]
        let continuation: AsyncStream<RealtimeEvent>.Continuation
        var staleArmed: Bool
        var suppressed: [UUID: Int] = [:]
    }

    let mutation: ScenarioMutation?
    private let lock = NSLock()
    private var subscriptions: [UUID: Subscription] = [:]
    private var knownGroups: Set<UUID> = []

    init(mutation: ScenarioMutation?) {
        self.mutation = mutation
    }

    func rememberGroup(_ groupId: UUID) {
        lock.withLock { _ = knownGroups.insert(groupId) }
    }

    func isKnownGroup(_ groupId: UUID) -> Bool {
        lock.withLock { knownGroups.contains(groupId) }
    }

    /// Wraps a Realtime stream: events are forwarded in order; mutations may drop or inject some.
    func subscribe(_ base: AsyncStream<RealtimeEvent>, owner: UUID, groupIds: [UUID]) -> AsyncStream<RealtimeEvent> {
        let (stream, continuation) = AsyncStream.makeStream(of: RealtimeEvent.self, bufferingPolicy: .unbounded)
        let id = UUID()
        lock.withLock {
            subscriptions[id] = Subscription(
                owner: owner, groupIds: groupIds, continuation: continuation,
                staleArmed: mutation == .staleEventsAndSilentTaskCreation
            )
        }
        let forwarder = Task { [weak self] in
            for await event in base {
                if case let .groupActivity(groupId) = event, self?.consumeSuppression(id, groupId) == true { continue }
                continuation.yield(event)
            }
            continuation.finish()
        }
        continuation.onTermination = { [weak self] _ in
            forwarder.cancel()
            self?.remove(id)
        }
        return stream
    }

    private func remove(_ id: UUID) {
        lock.withLock { _ = subscriptions.removeValue(forKey: id) }
    }

    private func consumeSuppression(_ id: UUID, _ groupId: UUID) -> Bool {
        lock.withLock {
            guard let count = subscriptions[id]?.suppressed[groupId], count > 0 else { return false }
            subscriptions[id]?.suppressed[groupId] = count - 1
            return true
        }
    }

    /// Yields `event` into every subscription matching `condition` (synchronously, before the caller goes on).
    func inject(_ event: RealtimeEvent, where condition: (Subscription) -> Bool = { _ in true }) {
        lock.withLock {
            for subscription in subscriptions.values where condition(subscription) {
                subscription.continuation.yield(event)
            }
        }
    }

    /// Called before every write: releases the stale events of the subscriptions made since the last write.
    func beforeWrite() {
        guard mutation == .staleEventsAndSilentTaskCreation else { return }
        lock.withLock {
            for (id, subscription) in subscriptions where subscription.staleArmed {
                for groupId in subscription.groupIds {
                    subscription.continuation.yield(.groupActivity(groupId: groupId))
                }
                subscription.continuation.yield(.membershipsChanged)
                subscriptions[id]?.staleArmed = false
            }
        }
    }

    /// Drops the next `.groupActivity(groupId)` of every subscription watching the group.
    func suppressNextActivity(of groupId: UUID) {
        lock.withLock {
            for (id, subscription) in subscriptions where subscription.groupIds.contains(groupId) {
                subscriptions[id]?.suppressed[groupId, default: 0] += 1
            }
        }
    }

    /// After a write that bumps `groupId`.
    func groupChanged(_ groupId: UUID) {
        guard mutation == .activityToNonMembers else { return }
        inject(.groupActivity(groupId: groupId)) { $0.groupIds.contains(groupId) }
    }

    /// After a write that changes someone's membership.
    func membershipChanged() {
        guard mutation == .membershipsChangedToEveryone else { return }
        inject(.membershipsChanged)
    }

    /// After new assignment rows of `userIds`.
    func assigned(_ userIds: Set<UUID>, taskId: UUID, groupId: UUID, by assigner: UUID) {
        guard mutation == .assignedToEveryone else { return }
        for userId in userIds {
            inject(.assigned(taskId: taskId, groupId: groupId, assignedBy: assigner)) { $0.owner != userId }
        }
    }
}

struct MutatedRealtimeService: RealtimeService {
    let base: any RealtimeService
    let owner: UUID
    let registry: MutationRegistry

    func events(userId: UUID, groupIds: [UUID]) -> AsyncStream<RealtimeEvent> {
        registry.subscribe(base.events(userId: userId, groupIds: groupIds), owner: owner, groupIds: groupIds)
    }
}

struct MutatedProfileService: ProfileService {
    let base: any ProfileService
    let registry: MutationRegistry

    func myProfile() async throws -> UserProfile {
        try await base.myProfile()
    }

    func updateDisplayName(_ name: String) async throws -> UserProfile {
        registry.beforeWrite()
        return try await base.updateDisplayName(name)
    }
}

struct MutatedGroupService: GroupService {
    let base: any GroupService
    let registry: MutationRegistry

    private var mutation: ScenarioMutation? { registry.mutation }

    private func isMember(_ groupId: UUID) async -> Bool {
        ((try? await base.myGroups()) ?? []).contains { $0.id == groupId }
    }

    func myGroups() async throws -> [GroupSummary] {
        try await base.myGroups()
    }

    func createGroup(name: String) async throws -> GroupSummary {
        registry.beforeWrite()
        do {
            let summary = try await base.createGroup(name: name)
            registry.rememberGroup(summary.id)
            registry.membershipChanged()
            return summary
        } catch AppError.notAuthenticated where mutation == .signedOutForbidden {
            throw AppError.forbidden
        }
    }

    func join(code: InviteCode) async throws -> JoinResult {
        registry.beforeWrite()
        let result = try await base.join(code: code)
        if !result.alreadyMember {
            registry.membershipChanged()
            registry.groupChanged(result.groupId)
        }
        return result
    }

    func rename(groupId: UUID, name: String) async throws -> TeamGroup {
        registry.beforeWrite()
        do {
            let group = try await base.rename(groupId: groupId, name: name)
            registry.groupChanged(groupId)
            return group
        } catch AppError.forbidden where mutation == .renameNonMemberNotFound {
            let member = await isMember(groupId)
            throw member ? AppError.forbidden : AppError.notFound
        } catch AppError.notFound where mutation == .renameUnknownForbidden {
            throw AppError.forbidden
        }
    }

    func deleteGroup(groupId: UUID) async throws {
        registry.beforeWrite()
        do {
            try await base.deleteGroup(groupId: groupId)
            registry.membershipChanged()
        } catch AppError.forbidden where mutation == .deleteNonMemberNotFound {
            let member = await isMember(groupId)
            throw member ? AppError.forbidden : AppError.notFound
        } catch AppError.notFound where mutation == .deleteUnknownForbidden {
            throw AppError.forbidden
        }
    }

    func members(groupId: UUID) async throws -> [Membership] {
        if mutation == .nonMemberReadsThrow, !(await isMember(groupId)) { throw AppError.forbidden }
        return try await base.members(groupId: groupId)
    }

    func inviteCode(groupId: UUID) async throws -> InviteCode {
        try await base.inviteCode(groupId: groupId)
    }

    func regenerateInviteCode(groupId: UUID) async throws -> InviteCode {
        registry.beforeWrite()
        do {
            return try await base.regenerateInviteCode(groupId: groupId)
        } catch AppError.forbidden where mutation == .unknownGroupNotFound && !registry.isKnownGroup(groupId) {
            throw AppError.notFound
        }
    }

    func setRole(groupId: UUID, userId: UUID, role: MemberRole) async throws {
        registry.beforeWrite()
        do {
            try await base.setRole(groupId: groupId, userId: userId, role: role)
            registry.membershipChanged()
            registry.groupChanged(groupId)
        } catch AppError.forbidden where mutation == .unknownGroupNotFound && !registry.isKnownGroup(groupId) {
            throw AppError.notFound
        }
    }

    func removeMember(groupId: UUID, userId: UUID) async throws {
        registry.beforeWrite()
        do {
            try await base.removeMember(groupId: groupId, userId: userId)
            registry.membershipChanged()
            registry.groupChanged(groupId)
        } catch AppError.forbidden where mutation == .unknownGroupNotFound && !registry.isKnownGroup(groupId) {
            throw AppError.notFound
        }
    }

    func leave(groupId: UUID) async throws {
        registry.beforeWrite()
        try await base.leave(groupId: groupId)
        registry.membershipChanged()
        registry.groupChanged(groupId)
    }
}

struct MutatedTaskService: TaskService {
    let base: any TaskService
    let groups: any GroupService
    let owner: UUID
    let registry: MutationRegistry

    private var mutation: ScenarioMutation? { registry.mutation }

    private func isMember(_ groupId: UUID) async -> Bool {
        ((try? await groups.myGroups()) ?? []).contains { $0.id == groupId }
    }

    func tasks(groupId: UUID, includeOldDone: Bool) async throws -> [TaskItem] {
        if mutation == .nonMemberReadsThrow, !(await isMember(groupId)) { throw AppError.notFound }
        return try await base.tasks(groupId: groupId, includeOldDone: includeOldDone)
    }

    func myTasks(includeDone: Bool) async throws -> [TaskItem] {
        try await base.myTasks(includeDone: includeDone)
    }

    func task(id: UUID) async throws -> TaskItem {
        try await base.task(id: id)
    }

    func create(groupId: UUID, draft: TaskDraft) async throws -> TaskItem {
        registry.beforeWrite()
        if mutation == .staleEventsAndSilentTaskCreation {
            registry.suppressNextActivity(of: groupId)
        }
        let task = try await base.create(groupId: groupId, draft: draft)
        registry.assigned(Set(task.assigneeIds), taskId: task.id, groupId: task.groupId, by: owner)
        registry.groupChanged(task.groupId)
        return task
    }

    func update(taskId: UUID, draft: TaskDraft) async throws -> TaskItem {
        registry.beforeWrite()
        let before = Set((try? await base.task(id: taskId))?.assigneeIds ?? [])
        let task = try await base.update(taskId: taskId, draft: draft)
        registry.assigned(Set(task.assigneeIds).subtracting(before), taskId: task.id, groupId: task.groupId, by: owner)
        registry.groupChanged(task.groupId)
        return task
    }

    func setStatus(taskId: UUID, status: TaskStatus) async throws -> TaskItem {
        registry.beforeWrite()
        let task = try await base.setStatus(taskId: taskId, status: status)
        registry.groupChanged(task.groupId)
        return task
    }

    func delete(taskId: UUID) async throws {
        registry.beforeWrite()
        try await base.delete(taskId: taskId)
    }

    func assignments(since: Date) async throws -> [AssignmentEvent] {
        try await base.assignments(since: since)
    }
}

@Suite struct ScenarioMutationTests {
    /// Failing scenarios (name → failure) of `scenarios` run on a harness applying `mutation`.
    static func failingScenarios(
        _ mutation: ScenarioMutation?, among scenarios: [ContractScenario] = ContractScenarios.all
    ) async -> [String: String] {
        var failures: [String: String] = [:]
        for scenario in scenarios {
            do {
                try await scenario.run(MutationHarness(mutation))
            } catch {
                failures[scenario.name] = "\(error)"
            }
        }
        return failures
    }

    /// Scenarios that must catch each mutation (lead decisions and docs/CONTRACTS.md §6).
    static let detectors: [ScenarioMutation: [String]] = [
        .renameNonMemberNotFound: ["group.rename", "matrix.groupAdminActions"],
        .renameUnknownForbidden: ["group.rename"],
        .deleteNonMemberNotFound: ["group.delete", "matrix.groupAdminActions"],
        .deleteUnknownForbidden: ["group.delete"],
        .nonMemberReadsThrow: ["group.nonMemberSeesNothing", "matrix.seeGroupMembersAndTasks", "group.delete"],
        .unknownGroupNotFound: ["matrix.groupAdminActions"],
        .signedOutForbidden: ["auth.signOutAndSignIn"],
        .assignedToEveryone: ["realtime.assignedOnlyToMe"],
        .membershipsChangedToEveryone: ["realtime.membershipsChangedOnlyForMe"],
        .activityToNonMembers: ["realtime.groupActivityOnlyForMembers"],
    ]

    @Test func decoratorsAloneBreakNothing() async {
        let failures = await Self.failingScenarios(nil)
        #expect(failures.isEmpty, "\(failures)")
    }

    @Test(arguments: ScenarioMutation.allCases.filter { $0 != .staleEventsAndSilentTaskCreation })
    func catalogDetects(_ mutation: ScenarioMutation) async throws {
        let detectors = try #require(Self.detectors[mutation])
        let failures = await Self.failingScenarios(mutation)
        for name in detectors {
            #expect(failures[name] != nil, "\(name) does not detect \(mutation); failing: \(failures.keys.sorted())")
        }
    }

    /// On a real server, a change committed before the subscription can arrive after `.connected`: it must not
    /// stand in for the signal under test (here `create_task` emits none, which must be detected).
    @Test func staleEventCannotStandInForAMissingSignal() async throws {
        let scenario = try #require(ContractScenarios.named("realtime.groupActivity"))
        let failures = await Self.failingScenarios(.staleEventsAndSilentTaskCreation, among: [scenario])
        #expect(failures[scenario.name] != nil, "a stale event satisfied the wait for the create_task signal")
    }
}
