import Foundation
import Observation
import Testing
@testable import TeamTasksCore

@MainActor
@Suite struct ChangeFeedTests {
    typealias F = LogicFixtures

    @Test func startsAtZero() {
        let feed = ChangeFeed()
        #expect(feed.membershipsRevision == 0)
        #expect(feed.myTasksRevision == 0)
        #expect(feed.allRevision == 0)
        #expect(feed.groupRevision(F.groupA) == 0)
    }

    @Test func groupBumpsAreIndependent() {
        let feed = ChangeFeed()
        feed.bump(groupId: F.groupA)
        feed.bump(groupId: F.groupA)
        #expect(feed.groupRevision(F.groupA) == 2)
        #expect(feed.groupRevision(F.groupB) == 0)
        #expect(feed.membershipsRevision == 0)
        #expect(feed.myTasksRevision == 0)
    }

    @Test func individualCounters() {
        let feed = ChangeFeed()
        feed.bumpMemberships()
        #expect(feed.membershipsRevision == 1)
        #expect(feed.myTasksRevision == 0)
        feed.bumpMyTasks()
        feed.bumpMyTasks()
        #expect(feed.myTasksRevision == 2)
        #expect(feed.groupRevision(F.groupA) == 0)
    }

    @Test func bumpAllChangesEveryRevisionIncludingUnknownGroups() {
        let feed = ChangeFeed()
        feed.bump(groupId: F.groupA)
        let before = (feed.groupRevision(F.groupA), feed.groupRevision(F.groupB), feed.membershipsRevision, feed.myTasksRevision)
        feed.bumpAll()
        #expect(feed.groupRevision(F.groupA) == before.0 + 1)
        #expect(feed.groupRevision(F.groupB) == before.1 + 1)
        #expect(feed.groupRevision(UUID()) == 1)
        #expect(feed.membershipsRevision == before.2 + 1)
        #expect(feed.myTasksRevision == before.3 + 1)
    }

    @Test func revisionsAreObservable() {
        let feed = ChangeFeed()
        let flag = LogicFlag()
        withObservationTracking {
            _ = feed.groupRevision(F.groupA)
        } onChange: {
            flag.set()
        }
        feed.bumpMyTasks()
        #expect(!flag.isSet)
        feed.bumpAll()
        #expect(flag.isSet)

        let groupFlag = LogicFlag()
        withObservationTracking {
            _ = feed.groupRevision(F.groupA)
        } onChange: {
            groupFlag.set()
        }
        feed.bump(groupId: F.groupA)
        #expect(groupFlag.isSet)
    }
}

final class LogicFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool { lock.withLock { value } }
    func set() { lock.withLock { value = true } }
}

@MainActor
@Suite struct RealtimeCoordinatorTests {
    typealias F = LogicFixtures
    typealias Key = RealtimeCoordinator.BumpKey

    let realtime = LogicFakeRealtime()
    let feed = ChangeFeed()
    let clock = LogicTestClock()
    let groups = LogicGroupIdsSource([LogicFixtures.groupA])
    let sink = LogicAssignmentSink()

    private func makeCoordinator() -> RealtimeCoordinator {
        let groups = groups
        let sink = sink
        return RealtimeCoordinator(
            realtime: realtime,
            userId: F.me,
            feed: feed,
            groupIds: { try groups.fetch() },
            clock: clock,
            onAssigned: { sink.receive($0) }
        )
    }

    /// Starts a coordinator and waits for its first subscription.
    private func started(groupIds: [UUID]? = nil) async -> RealtimeCoordinator {
        let coordinator = makeCoordinator()
        coordinator.start(groupIds: groupIds)
        await LogicWait.until("first subscription") { realtime.subscriptionCount == 1 }
        return coordinator
    }

    /// Sends events on the current subscription and waits until the coordinator handled them.
    private func send(_ events: RealtimeEvent..., to coordinator: RealtimeCoordinator) async {
        let target = coordinator.handledEventCount + events.count
        for event in events {
            realtime.send(event)
        }
        await LogicWait.until("\(events.count) handled event(s)") { coordinator.handledEventCount == target }
    }

    // MARK: Subscription

    @Test func subscribesWithTheProvidedGroupIds() async {
        groups.ids = [F.groupB, F.groupA, F.groupB]
        let coordinator = await started()
        #expect(realtime.userId(of: 0) == F.me)
        #expect(Set(realtime.groupIds(of: 0)) == [F.groupA, F.groupB])
        #expect(realtime.groupIds(of: 0).count == 2)
        #expect(coordinator.subscribedGroupIds == realtime.groupIds(of: 0))
        #expect(coordinator.isRunning)
        #expect(groups.calls == 1)
        coordinator.stop()
    }

    @Test func initialGroupIdsSkipTheProvider() async {
        let coordinator = await started(groupIds: [F.groupB])
        #expect(realtime.groupIds(of: 0) == [F.groupB])
        #expect(groups.calls == 0)
        coordinator.stop()
    }

    @Test func startIsIdempotent() async {
        let coordinator = await started()
        coordinator.start()
        await LogicWait.settle()
        #expect(realtime.subscriptionCount == 1)
        coordinator.stop()
    }

    @Test func failingProviderSubscribesWithoutGroups() async {
        groups.fails = true
        let coordinator = await started()
        #expect(realtime.groupIds(of: 0).isEmpty)
        coordinator.stop()
    }

    // MARK: Mapping and debounce

    @Test func connectedBumpsAllImmediately() async {
        let coordinator = await started()
        await send(.connected, to: coordinator)
        #expect(feed.allRevision == 1)
        #expect(feed.membershipsRevision == 1)
        #expect(feed.myTasksRevision == 1)
        #expect(clock.sleeperCount == 0)
        coordinator.stop()
    }

    @Test func groupActivityIsDebouncedPerKey() async {
        let coordinator = await started()
        await send(.groupActivity(groupId: F.groupA), .groupActivity(groupId: F.groupA), .groupActivity(groupId: F.groupB), .groupActivity(groupId: F.groupA), to: coordinator)
        #expect(coordinator.pendingBumpKeys == [Key.group(F.groupA), Key.group(F.groupB), Key.myTasks])
        await LogicWait.until("3 debounce timers") { clock.sleeperCount == 3 }
        #expect(feed.groupRevision(F.groupA) == 0)
        #expect(feed.myTasksRevision == 0)

        clock.advance(by: .milliseconds(299))
        await LogicWait.settle()
        #expect(feed.groupRevision(F.groupA) == 0)
        #expect(feed.groupRevision(F.groupB) == 0)
        #expect(feed.myTasksRevision == 0)

        clock.advance(by: .milliseconds(1))
        await LogicWait.until("coalesced bumps") { coordinator.pendingBumpKeys.isEmpty }
        #expect(feed.groupRevision(F.groupA) == 1)
        #expect(feed.groupRevision(F.groupB) == 1)
        #expect(feed.myTasksRevision == 1)
        #expect(feed.membershipsRevision == 0)
        coordinator.stop()
    }

    @Test func aNewWindowOpensAfterAFlush() async {
        let coordinator = await started()
        await send(.groupActivity(groupId: F.groupA), to: coordinator)
        await LogicWait.until("timers") { clock.sleeperCount == 2 }
        clock.advance(by: .milliseconds(300))
        await LogicWait.until("first flush") { feed.groupRevision(F.groupA) == 1 && feed.myTasksRevision == 1 }

        await send(.groupActivity(groupId: F.groupA), to: coordinator)
        await LogicWait.until("new timers") { clock.sleeperCount == 2 }
        #expect(feed.groupRevision(F.groupA) == 1)
        clock.advance(by: .milliseconds(300))
        await LogicWait.until("second flush") { feed.groupRevision(F.groupA) == 2 && feed.myTasksRevision == 2 }
        coordinator.stop()
    }

    @Test func burstLongerThanTheWindowBumpsAtMostOncePerWindow() async {
        let coordinator = await started()
        await send(.groupActivity(groupId: F.groupA), to: coordinator)
        await LogicWait.until("timers") { clock.sleeperCount == 2 }
        clock.advance(by: .milliseconds(200))
        await send(.groupActivity(groupId: F.groupA), to: coordinator) // coalesced into the open window
        clock.advance(by: .milliseconds(100))
        await LogicWait.until("flush") { coordinator.pendingBumpKeys.isEmpty }
        #expect(feed.groupRevision(F.groupA) == 1)
        coordinator.stop()
    }

    @Test func connectedSupersedesPendingBumps() async {
        let coordinator = await started()
        await send(.groupActivity(groupId: F.groupA), .membershipsChanged, to: coordinator)
        await LogicWait.until("timers") { clock.sleeperCount == 3 }
        await send(.connected, to: coordinator)
        await LogicWait.until("timers cancelled") { clock.sleeperCount == 0 }
        #expect(coordinator.pendingBumpKeys.isEmpty)
        clock.advance(by: .seconds(1))
        await LogicWait.settle()
        #expect(feed.groupRevision(F.groupA) == 1)
        #expect(feed.membershipsRevision == 1)
        #expect(feed.myTasksRevision == 1)
        coordinator.stop()
    }

    @Test func reconnectBumpsAllEveryTime() async {
        let coordinator = await started()
        await send(.connected, to: coordinator)
        await send(.connected, to: coordinator)
        #expect(feed.allRevision == 2)
        #expect(feed.groupRevision(F.groupB) == 2)
        coordinator.stop()
    }

    // MARK: Memberships

    @Test func membershipsChangeWithSameGroupsKeepsTheSubscription() async {
        let coordinator = await started()
        await send(.membershipsChanged, to: coordinator)
        await LogicWait.until("provider refreshed") { groups.calls == 2 }
        await LogicWait.until("timers") { clock.sleeperCount == 2 }
        clock.advance(by: .milliseconds(300))
        await LogicWait.until("bumps") { feed.membershipsRevision == 1 && feed.myTasksRevision == 1 }
        #expect(realtime.subscriptionCount == 1)
        #expect(!realtime.isTerminated(0))
        #expect(feed.allRevision == 0)
        coordinator.stop()
    }

    @Test func membershipsChangeResubscribesWithFreshGroupIds() async {
        let coordinator = await started()
        groups.ids = [F.groupA, F.groupB]
        await send(.membershipsChanged, to: coordinator)
        await LogicWait.until("resubscription") { realtime.subscriptionCount == 2 }
        #expect(Set(realtime.groupIds(of: 1)) == [F.groupA, F.groupB])
        #expect(coordinator.subscribedGroupIds == realtime.groupIds(of: 1))
        await LogicWait.until("old stream terminated") { realtime.isTerminated(0) }
        #expect(!realtime.isTerminated(1))

        // The new subscription emits .connected: one bumpAll covers the pending debounced bumps.
        await send(.connected, to: coordinator)
        #expect(feed.allRevision == 1)
        await LogicWait.until("timers cancelled") { clock.sleeperCount == 0 }
        clock.advance(by: .seconds(1))
        await LogicWait.settle()
        #expect(feed.membershipsRevision == 1)
        #expect(feed.myTasksRevision == 1)

        // Events of the new subscription are handled.
        await send(.groupActivity(groupId: F.groupB), to: coordinator)
        await LogicWait.until("timers") { clock.sleeperCount == 2 }
        clock.advance(by: .milliseconds(300))
        await LogicWait.until("group bump") { feed.groupRevision(F.groupB) == 2 }
        coordinator.stop()
    }

    @Test func membershipsChangeWithFailingProviderKeepsTheSubscription() async {
        let coordinator = await started()
        groups.fails = true
        await send(.membershipsChanged, to: coordinator)
        await LogicWait.until("provider called") { groups.calls == 2 }
        await send(.groupActivity(groupId: F.groupA), to: coordinator)
        #expect(realtime.subscriptionCount == 1)
        #expect(!realtime.isTerminated(0))
        coordinator.stop()
    }

    // MARK: Assignments

    @Test func assignedIsForwardedInOrderAndBumpsMyTasks() async {
        let coordinator = await started()
        let first = RealtimeAssignment(taskId: F.uuid(1), groupId: F.groupA, assignedBy: F.other)
        let second = RealtimeAssignment(taskId: F.uuid(2), groupId: F.groupB, assignedBy: nil)
        await send(
            .assigned(taskId: first.taskId, groupId: first.groupId, assignedBy: first.assignedBy),
            .assigned(taskId: second.taskId, groupId: second.groupId, assignedBy: second.assignedBy),
            to: coordinator
        )
        await LogicWait.until("forwarded") { sink.received.count == 2 }
        #expect(sink.received == [first, second])
        #expect(coordinator.pendingBumpKeys == [Key.myTasks])
        await LogicWait.until("timer") { clock.sleeperCount == 1 }
        clock.advance(by: .milliseconds(300))
        await LogicWait.until("bump") { feed.myTasksRevision == 1 }
        #expect(feed.groupRevision(F.groupA) == 0)
        coordinator.stop()
    }

    @Test func assignmentsReachTheNotifier() async throws {
        let tasks = LogicFakeTaskService()
        let scheduler = LogicFakeScheduler()
        let date = LogicFixtures.date(2026, 9, 24, 12, 0)
        let notifier = AssignmentNotifier(userId: F.me, tasks: tasks, scheduler: scheduler, store: InMemoryKeyValueStore(), now: { date })
        tasks.put(F.task(1, title: "Faire les courses"))
        let groups = groups
        let coordinator = RealtimeCoordinator(
            realtime: realtime, userId: F.me, feed: feed, groupIds: { try groups.fetch() }, clock: clock,
            onAssigned: { await notifier.handleRealtime($0) }
        )
        coordinator.start()
        await LogicWait.until("subscription") { realtime.subscriptionCount == 1 }
        realtime.send(.assigned(taskId: F.uuid(1), groupId: F.groupA, assignedBy: F.other))
        realtime.send(.assigned(taskId: F.uuid(1), groupId: F.groupA, assignedBy: F.me))
        await LogicWait.until("notification") { scheduler.added.count == 1 }
        await LogicWait.settle()
        #expect(scheduler.added.map(\.body) == ["Faire les courses — Coloc' rue des Lilas"])
        coordinator.stop()
    }

    // MARK: Lifecycle

    @Test func stopEndsTheStreamAndDropsPendingBumps() async {
        let coordinator = await started()
        await send(.groupActivity(groupId: F.groupA), to: coordinator)
        await LogicWait.until("timers") { clock.sleeperCount == 2 }

        coordinator.stop()
        #expect(!coordinator.isRunning)
        #expect(coordinator.subscribedGroupIds.isEmpty)
        await LogicWait.until("stream terminated") { realtime.isTerminated(0) }
        await LogicWait.until("timers cancelled") { clock.sleeperCount == 0 }

        let handled = coordinator.handledEventCount
        realtime.send(.connected)
        clock.advance(by: .seconds(10))
        await LogicWait.settle()
        #expect(coordinator.handledEventCount == handled)
        #expect(feed.allRevision == 0)
        #expect(feed.groupRevision(F.groupA) == 0)
        #expect(realtime.subscriptionCount == 1)
    }

    @Test func canRestartAfterStop() async {
        let coordinator = await started()
        coordinator.stop()
        coordinator.start()
        await LogicWait.until("second subscription") { realtime.subscriptionCount == 2 }
        await send(.connected, to: coordinator)
        #expect(feed.allRevision == 1)
        coordinator.stop()
    }

    @Test func stopBeforeTheFirstSubscriptionIsSafe() async {
        let coordinator = makeCoordinator()
        coordinator.start()
        coordinator.stop()
        await LogicWait.settle()
        #expect(realtime.subscriptionCount == 0)
        #expect(!coordinator.isRunning)
    }

    @Test func releasingTheCoordinatorEndsTheStream() async {
        var coordinator: RealtimeCoordinator? = makeCoordinator()
        coordinator?.start()
        await LogicWait.until("subscription") { realtime.subscriptionCount == 1 }
        await send(.groupActivity(groupId: F.groupA), to: coordinator!)
        await LogicWait.until("timers") { clock.sleeperCount == 2 }

        weak var weakCoordinator: RealtimeCoordinator?
        weakCoordinator = coordinator
        coordinator = nil
        #expect(weakCoordinator == nil)
        await LogicWait.until("stream terminated") { realtime.isTerminated(0) }
        clock.advance(by: .seconds(1))
        await LogicWait.settle()
        #expect(feed.groupRevision(F.groupA) == 0)
    }

    @Test func streamEndedByTheServerIsRetriedAfterTheDelay() async {
        let coordinator = await started()
        groups.ids = [F.groupB]
        realtime.finishLatest()
        await LogicWait.until("retry timer") { clock.sleeperCount == 1 }
        #expect(realtime.subscriptionCount == 1)

        clock.advance(by: .seconds(4))
        await LogicWait.settle()
        #expect(realtime.subscriptionCount == 1)

        clock.advance(by: .seconds(1))
        await LogicWait.until("resubscribed") { realtime.subscriptionCount == 2 }
        #expect(realtime.groupIds(of: 1) == [F.groupB])
        await send(.connected, to: coordinator)
        #expect(feed.allRevision == 1)
        coordinator.stop()
    }
}
