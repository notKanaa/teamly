import Foundation
import Testing
@testable import TeamTasksCore

@Suite struct ReminderLeadTimeTests {
    typealias F = LogicFixtures
    let calendar = LogicFixtures.parisCalendar

    @Test func defaultIsOneHour() {
        #expect(ReminderLeadTime.default == .oneHour)
        #expect(ReminderLeadTime.load(from: InMemoryKeyValueStore()) == .oneHour)
    }

    @Test func frenchLabels() {
        #expect(ReminderLeadTime.allCases.map(\.label) == [
            "À l’heure de l’échéance", "15 minutes avant", "1 heure avant", "1 jour avant", "Aucun rappel",
        ])
    }

    @Test func persistsInKeyValueStore() {
        let store = InMemoryKeyValueStore()
        for leadTime in ReminderLeadTime.allCases {
            leadTime.save(to: store)
            #expect(ReminderLeadTime.load(from: store) == leadTime)
        }
    }

    @Test func unreadableValueFallsBackToDefault() {
        let store = InMemoryKeyValueStore()
        store.set(Data("\"twoWeeks\"".utf8), forKey: ReminderLeadTime.storageKey)
        #expect(ReminderLeadTime.load(from: store) == .oneHour)
        store.set(Data([0xFF, 0x00]), forKey: ReminderLeadTime.storageKey)
        #expect(ReminderLeadTime.load(from: store) == .oneHour)
    }

    @Test func codableUsesStableRawValues() throws {
        let data = try JSONEncoder().encode([ReminderLeadTime.fifteenMinutes, .off])
        #expect(String(decoding: data, as: UTF8.self) == "[\"fifteenMinutes\",\"off\"]")
        #expect(try JSONDecoder().decode([ReminderLeadTime].self, from: data) == [.fifteenMinutes, .off])
    }

    @Test func fireDates() {
        let due = F.date(2026, 9, 24, 20, 0)
        #expect(ReminderLeadTime.atDueTime.fireDate(forDueAt: due, calendar: calendar) == due)
        #expect(ReminderLeadTime.fifteenMinutes.fireDate(forDueAt: due, calendar: calendar) == F.date(2026, 9, 24, 19, 45))
        #expect(ReminderLeadTime.oneHour.fireDate(forDueAt: due, calendar: calendar) == F.date(2026, 9, 24, 19, 0))
        #expect(ReminderLeadTime.oneDay.fireDate(forDueAt: due, calendar: calendar) == F.date(2026, 9, 23, 20, 0))
        #expect(ReminderLeadTime.off.fireDate(forDueAt: due, calendar: calendar) == nil)
        #expect(!ReminderLeadTime.off.isEnabled)
        #expect(ReminderLeadTime.atDueTime.isEnabled)
    }

    @Test func oneDayKeepsTheWallClockTimeAcrossDST() throws {
        // Due Sunday 29 March 2026 20:00 (CEST): the day before at 20:00 (CET) is only 23 hours earlier.
        let due = F.date(2026, 3, 29, 20, 0)
        let fire = try #require(ReminderLeadTime.oneDay.fireDate(forDueAt: due, calendar: calendar))
        #expect(fire == F.date(2026, 3, 28, 20, 0))
        #expect(due.timeIntervalSince(fire) == 23 * 3600)
        // Due Sunday 25 October 2026 20:00 (CET): Saturday 20:00 (CEST) is 25 hours earlier.
        let fallDue = F.date(2026, 10, 25, 20, 0)
        let fallFire = try #require(ReminderLeadTime.oneDay.fireDate(forDueAt: fallDue, calendar: calendar))
        #expect(fallFire == F.date(2026, 10, 24, 20, 0))
        #expect(fallDue.timeIntervalSince(fallFire) == 25 * 3600)
    }
}

@Suite struct ReminderPlannerTests {
    typealias F = LogicFixtures
    let planner = ReminderPlanner(calendar: LogicFixtures.parisCalendar)
    let now = LogicFixtures.date(2026, 9, 24, 12, 0)

    @Test func identifierFormat() {
        let taskId = UUID(uuidString: "3F2504E0-4F89-11D3-9A0C-0305E82C3301")!
        let due = Date(timeIntervalSince1970: 1_790_000_000.75)
        #expect(ReminderPlanner.identifier(taskId: taskId, dueAt: due) == "due-3F2504E0-4F89-11D3-9A0C-0305E82C3301-1790000000")
        #expect(ReminderPlanner.epochSeconds(Date(timeIntervalSince1970: -0.5)) == -1)
    }

    @Test func buildsAFrenchReminder() throws {
        let task = F.task(1, title: "Sortir les poubelles", due: F.date(2026, 9, 24, 20, 0))
        let plan = planner.plan(tasks: [task], userId: F.me, leadTime: .oneHour, now: now)
        let reminder = try #require(plan.first)
        #expect(plan.count == 1)
        #expect(reminder.id == ReminderPlanner.identifier(taskId: task.id, dueAt: task.dueAt!))
        #expect(reminder.id.hasPrefix("due-"))
        #expect(reminder.title == "Échéance proche")
        #expect(reminder.body == "Sortir les poubelles — Coloc' rue des Lilas, aujourd’hui à 20:00")
        #expect(reminder.fireDate == F.date(2026, 9, 24, 19, 0))
        #expect(reminder.userInfo == ["taskId": task.id.uuidString, "groupId": F.groupA.uuidString])
        #expect(reminder.threadId == F.groupA.uuidString)
    }

    @Test func wordingIsRelativeToTheFireDate() throws {
        // With "1 jour avant", the reminder is shown the day before: the due date reads "demain".
        let task = F.task(1, title: "Réserver le gymnase", due: F.date(2026, 9, 26, 9, 30), groupName: "Projet Asso Sport")
        let reminder = try #require(planner.plan(tasks: [task], userId: F.me, leadTime: .oneDay, now: now).first)
        #expect(reminder.body == "Réserver le gymnase — Projet Asso Sport, demain à 09:30")
        #expect(reminder.fireDate == F.date(2026, 9, 25, 9, 30))
    }

    @Test func groupNameFallbacks() throws {
        let unnamed = F.task(1, title: "Payer le loyer", due: F.date(2026, 9, 24, 20, 0), groupName: nil)
        let withFallback = planner.plan(tasks: [unnamed], userId: F.me, leadTime: .oneHour, now: now, groupNames: [F.groupA: "Coloc"])
        #expect(withFallback.first?.body == "Payer le loyer — Coloc, aujourd’hui à 20:00")
        let withoutName = planner.plan(tasks: [unnamed], userId: F.me, leadTime: .oneHour, now: now)
        #expect(withoutName.first?.body == "Payer le loyer, aujourd’hui à 20:00")
        let emptyName = F.task(2, title: "Payer le loyer", due: F.date(2026, 9, 24, 20, 0), groupName: "")
        let withEmptyName = planner.plan(tasks: [emptyName], userId: F.me, leadTime: .oneHour, now: now, groupNames: [F.groupA: "Coloc"])
        #expect(withEmptyName.first?.body == "Payer le loyer — Coloc, aujourd’hui à 20:00")
    }

    @Test func keepsOnlyMyOpenTasksWithADueDate() {
        let due = F.date(2026, 9, 25, 10, 0)
        let tasks = [
            F.task(1, due: due),
            F.task(2, status: .inProgress, due: due),
            F.task(3, status: .done, due: due),
            F.task(4, due: nil),
            F.task(5, due: due, assignees: [F.other]),
            F.task(6, due: due, assignees: []),
        ]
        let plan = planner.plan(tasks: tasks, userId: F.me, leadTime: .oneHour, now: now)
        #expect(plan.map { $0.userInfo["taskId"] } == [F.uuid(1).uuidString, F.uuid(2).uuidString])
    }

    @Test func leadTimeOffPlansNothing() {
        let tasks = [F.task(1, due: F.date(2026, 9, 25, 10, 0))]
        #expect(planner.plan(tasks: tasks, userId: F.me, leadTime: .off, now: now).isEmpty)
    }

    @Test func fireDateMustBeStrictlyInTheFuture() {
        let tasks = [
            F.task(1, due: now.addingTimeInterval(3600)), // fires exactly now → skipped
            F.task(2, due: now.addingTimeInterval(3601)), // fires in 1 s → kept
            F.task(3, due: now.addingTimeInterval(1800)), // due in 30 min, fire date passed → skipped
            F.task(4, due: now.addingTimeInterval(-60)), // overdue → skipped
        ]
        let plan = planner.plan(tasks: tasks, userId: F.me, leadTime: .oneHour, now: now)
        #expect(plan.map { $0.userInfo["taskId"] } == [F.uuid(2).uuidString])
        // At due time, a task due in 1 s is kept; one due now is not.
        let atDue = planner.plan(
            tasks: [F.task(5, due: now), F.task(6, due: now.addingTimeInterval(1))],
            userId: F.me, leadTime: .atDueTime, now: now
        )
        #expect(atDue.map { $0.userInfo["taskId"] } == [F.uuid(6).uuidString])
    }

    @Test func sixtyIsKeptInFull() {
        let tasks = (1...60).map { F.task($0, due: now.addingTimeInterval(Double(7200 + $0 * 60))) }
        let plan = planner.plan(tasks: tasks, userId: F.me, leadTime: .oneHour, now: now)
        #expect(plan.count == 60)
    }

    @Test func sixtyOneKeepsTheSixtySoonest() {
        // Built in reverse so the input order is not the fire order.
        let tasks = (1...61).reversed().map { F.task($0, due: now.addingTimeInterval(Double(7200 + $0 * 60))) }
        let plan = planner.plan(tasks: tasks, userId: F.me, leadTime: .oneHour, now: now)
        #expect(plan.count == ReminderPlanner.defaultMaxPending)
        #expect(plan.map { $0.userInfo["taskId"] } == (1...60).map { F.uuid($0).uuidString })
        #expect(!plan.contains { $0.userInfo["taskId"] == F.uuid(61).uuidString })
        let fireDates = plan.compactMap(\.fireDate)
        #expect(fireDates == fireDates.sorted())
    }

    @Test func soonestFirstWithDeterministicTies() {
        let due = F.date(2026, 9, 25, 10, 0)
        let tasks = [F.task(3, due: due), F.task(1, due: due.addingTimeInterval(60)), F.task(2, due: due)]
        let plan = planner.plan(tasks: tasks, userId: F.me, leadTime: .oneHour, now: now)
        #expect(plan.map { $0.userInfo["taskId"] } == [F.uuid(2).uuidString, F.uuid(3).uuidString, F.uuid(1).uuidString])
        let shuffled = planner.plan(tasks: tasks.reversed(), userId: F.me, leadTime: .oneHour, now: now)
        #expect(shuffled == plan)
    }

    @Test func duplicatedTasksAreScheduledOnce() {
        let task = F.task(1, due: F.date(2026, 9, 25, 10, 0))
        #expect(planner.plan(tasks: [task, task], userId: F.me, leadTime: .oneHour, now: now).count == 1)
    }

    @Test func customCap() {
        let small = ReminderPlanner(calendar: LogicFixtures.parisCalendar, maxPending: 2)
        let tasks = (1...5).map { F.task($0, due: now.addingTimeInterval(Double(7200 + $0))) }
        #expect(small.plan(tasks: tasks, userId: F.me, leadTime: .oneHour, now: now).count == 2)
        let none = ReminderPlanner(calendar: LogicFixtures.parisCalendar, maxPending: 0)
        #expect(none.plan(tasks: tasks, userId: F.me, leadTime: .oneHour, now: now).isEmpty)
    }
}

@Suite struct ReminderReconcilerTests {
    typealias F = LogicFixtures
    let planner = ReminderPlanner(calendar: LogicFixtures.parisCalendar)
    let now = LogicFixtures.date(2026, 9, 24, 12, 0)

    private func plan(_ tasks: [TaskItem], leadTime: ReminderLeadTime = .oneHour) -> [LocalNotification] {
        planner.plan(tasks: tasks, userId: F.me, leadTime: leadTime, now: now)
    }

    @Test func firstApplySchedulesEverything() async {
        let scheduler = LogicFakeScheduler()
        let reconciler = ReminderReconciler(scheduler: scheduler, store: InMemoryKeyValueStore())
        let desired = plan([F.task(1, due: F.date(2026, 9, 25, 10, 0)), F.task(2, due: F.date(2026, 9, 26, 10, 0))])
        let result = await reconciler.apply(desired)
        #expect(result.added == desired.map(\.id))
        #expect(result.removed.isEmpty && result.replaced.isEmpty && result.failed.isEmpty)
        #expect(scheduler.pendingIds == desired.map(\.id).sorted())
        #expect(scheduler.pending[desired[0].id] == desired[0])
    }

    @Test func applyIsIdempotent() async {
        let scheduler = LogicFakeScheduler()
        let reconciler = ReminderReconciler(scheduler: scheduler, store: InMemoryKeyValueStore())
        let desired = plan([F.task(1, due: F.date(2026, 9, 25, 10, 0)), F.task(2, due: F.date(2026, 9, 26, 10, 0))])
        await reconciler.apply(desired)
        scheduler.resetCallLog()

        let second = await reconciler.apply(desired)
        #expect(second.isNoOp)
        #expect(second.unchanged == 2)
        #expect(scheduler.added.isEmpty)
        #expect(scheduler.removeCalls.isEmpty)
    }

    @Test func dueDateChangeReplacesTheId() async {
        let scheduler = LogicFakeScheduler()
        let reconciler = ReminderReconciler(scheduler: scheduler, store: InMemoryKeyValueStore())
        let before = plan([F.task(1, due: F.date(2026, 9, 25, 10, 0))])
        await reconciler.apply(before)

        let after = plan([F.task(1, due: F.date(2026, 9, 27, 18, 0))])
        #expect(before[0].id != after[0].id)
        let result = await reconciler.apply(after)
        #expect(result.removed == [before[0].id])
        #expect(result.added == [after[0].id])
        #expect(scheduler.pendingIds == [after[0].id])
    }

    @Test func tasksNoLongerDesiredAreRemoved() async {
        let scheduler = LogicFakeScheduler()
        let reconciler = ReminderReconciler(scheduler: scheduler, store: InMemoryKeyValueStore())
        let tasks = [F.task(1, due: F.date(2026, 9, 25, 10, 0)), F.task(2, due: F.date(2026, 9, 26, 10, 0))]
        let initial = plan(tasks)
        await reconciler.apply(initial)

        // Task 2 is done now.
        var done = tasks[1]
        done.status = .done
        let result = await reconciler.apply(plan([tasks[0], done]))
        #expect(result.removed == [initial[1].id])
        #expect(result.added.isEmpty)
        #expect(scheduler.pendingIds == [initial[0].id])
    }

    @Test func leadTimeChangeReplacesPendingRequestsWithTheSameIds() async {
        let scheduler = LogicFakeScheduler()
        let reconciler = ReminderReconciler(scheduler: scheduler, store: InMemoryKeyValueStore())
        let tasks = [F.task(1, due: F.date(2026, 9, 25, 10, 0))]
        await reconciler.apply(plan(tasks, leadTime: .oneHour))
        scheduler.resetCallLog()

        let fifteen = plan(tasks, leadTime: .fifteenMinutes)
        let result = await reconciler.apply(fifteen)
        #expect(result.replaced == [fifteen[0].id])
        #expect(result.added.isEmpty && result.removed.isEmpty)
        #expect(scheduler.removeCalls == [[fifteen[0].id]])
        #expect(scheduler.pending[fifteen[0].id]?.fireDate == F.date(2026, 9, 25, 9, 45))

        let again = await reconciler.apply(fifteen)
        #expect(again.isNoOp)
    }

    @Test func renamedTaskIsReplaced() async {
        let scheduler = LogicFakeScheduler()
        let reconciler = ReminderReconciler(scheduler: scheduler, store: InMemoryKeyValueStore())
        await reconciler.apply(plan([F.task(1, title: "Ancien titre", due: F.date(2026, 9, 25, 10, 0))]))
        let renamed = plan([F.task(1, title: "Nouveau titre", due: F.date(2026, 9, 25, 10, 0))])
        let result = await reconciler.apply(renamed)
        #expect(result.replaced == [renamed[0].id])
        #expect(scheduler.pending[renamed[0].id]?.body.hasPrefix("Nouveau titre") == true)
    }

    @Test func turningRemindersOffRemovesAllDueRequestsOnly() async {
        let scheduler = LogicFakeScheduler()
        scheduler.seedPending(LocalNotification(id: "assigned-X", title: "Nouvelle tâche", body: "b", fireDate: now.addingTimeInterval(60)))
        let reconciler = ReminderReconciler(scheduler: scheduler, store: InMemoryKeyValueStore())
        let desired = plan([F.task(1, due: F.date(2026, 9, 25, 10, 0)), F.task(2, due: F.date(2026, 9, 26, 10, 0))])
        await reconciler.apply(desired)

        let result = await reconciler.apply(plan([F.task(1, due: F.date(2026, 9, 25, 10, 0))], leadTime: .off))
        #expect(result.removed == desired.map(\.id).sorted())
        #expect(scheduler.pendingIds == ["assigned-X"])
    }

    @Test func unknownPendingRequestFromAPreviousInstallIsReplacedOnce() async {
        let scheduler = LogicFakeScheduler()
        let desired = plan([F.task(1, due: F.date(2026, 9, 25, 10, 0))])
        scheduler.seedPending(desired[0])
        let store = InMemoryKeyValueStore()
        let reconciler = ReminderReconciler(scheduler: scheduler, store: store)

        let first = await reconciler.apply(desired)
        #expect(first.replaced == [desired[0].id])
        let second = await reconciler.apply(desired)
        #expect(second.isNoOp)
        // A new reconciler on the same store (next launch) sees the same state.
        let third = await ReminderReconciler(scheduler: scheduler, store: store).apply(desired)
        #expect(third.isNoOp)
    }

    @Test func failedAddIsRetriedNextTime() async {
        let scheduler = LogicFakeScheduler()
        let reconciler = ReminderReconciler(scheduler: scheduler, store: InMemoryKeyValueStore())
        let desired = plan([F.task(1, due: F.date(2026, 9, 25, 10, 0)), F.task(2, due: F.date(2026, 9, 26, 10, 0))])
        scheduler.failingIds = [desired[1].id]

        let first = await reconciler.apply(desired)
        #expect(first.added == [desired[0].id])
        #expect(first.failed == [desired[1].id])
        #expect(scheduler.pendingIds == [desired[0].id])

        scheduler.failingIds = []
        let second = await reconciler.apply(desired)
        #expect(second.added == [desired[1].id])
        #expect(second.unchanged == 1)
        #expect(Set(scheduler.pendingIds) == Set(desired.map(\.id)))
    }

    @Test func nonReminderIdsInTheDesiredSetAreIgnored() async {
        let scheduler = LogicFakeScheduler()
        let reconciler = ReminderReconciler(scheduler: scheduler, store: InMemoryKeyValueStore())
        let stray = LocalNotification(id: "assigned-1", title: "t", body: "b", fireDate: now.addingTimeInterval(60))
        let result = await reconciler.apply([stray])
        #expect(result.isNoOp)
        #expect(scheduler.added.isEmpty)
    }

    @Test func fingerprintIsStableAndContentSensitive() {
        let base = LocalNotification(id: "due-1-2", title: "Échéance proche", body: "b", fireDate: now, userInfo: ["taskId": "1", "groupId": "2"], threadId: "2")
        #expect(ReminderReconciler.fingerprint(of: base) == ReminderReconciler.fingerprint(of: base))
        var moved = base
        moved.fireDate = now.addingTimeInterval(1)
        #expect(ReminderReconciler.fingerprint(of: moved) != ReminderReconciler.fingerprint(of: base))
        var reworded = base
        reworded.body = "c"
        #expect(ReminderReconciler.fingerprint(of: reworded) != ReminderReconciler.fingerprint(of: base))
        #expect(StableHash.fnv1a64Hex("") == "cbf29ce484222325")
        #expect(StableHash.fnv1a64Hex("a") == "af63dc4c8601ec8c")
    }
}

@Suite struct ReminderSynchronizerTests {
    typealias F = LogicFixtures
    let now = LogicFixtures.date(2026, 9, 24, 12, 0)

    private func makeSynchronizer(_ scheduler: LogicFakeScheduler, _ store: InMemoryKeyValueStore) -> ReminderSynchronizer {
        let date = now
        return ReminderSynchronizer(scheduler: scheduler, store: store, calendar: LogicFixtures.parisCalendar, now: { date })
    }

    @Test func usesTheStoredLeadTime() async {
        let scheduler = LogicFakeScheduler()
        let store = InMemoryKeyValueStore()
        let synchronizer = makeSynchronizer(scheduler, store)
        let tasks = [F.task(1, due: F.date(2026, 9, 26, 10, 0))]

        await synchronizer.synchronize(myTasks: tasks, userId: F.me)
        #expect(scheduler.pending.values.map(\.fireDate) == [F.date(2026, 9, 26, 9, 0)])

        ReminderLeadTime.oneDay.save(to: store)
        let result = await synchronizer.synchronize(myTasks: tasks, userId: F.me)
        #expect(result.replaced.count == 1)
        #expect(scheduler.pending.values.map(\.fireDate) == [F.date(2026, 9, 25, 10, 0)])
    }

    @Test func oneDayReminderAlreadyPassedIsNotScheduled() async {
        let scheduler = LogicFakeScheduler()
        let store = InMemoryKeyValueStore()
        ReminderLeadTime.oneDay.save(to: store)
        let result = await makeSynchronizer(scheduler, store).synchronize(
            myTasks: [F.task(1, due: F.date(2026, 9, 25, 10, 0))], // fire date: 24/09 10:00 < now (12:00)
            userId: F.me
        )
        #expect(result.isNoOp)
        #expect(scheduler.pendingIds.isEmpty)
    }

    @Test func offRemovesEverything() async {
        let scheduler = LogicFakeScheduler()
        let store = InMemoryKeyValueStore()
        let synchronizer = makeSynchronizer(scheduler, store)
        let tasks = [F.task(1, due: F.date(2026, 9, 25, 10, 0)), F.task(2, due: F.date(2026, 9, 26, 10, 0))]
        await synchronizer.synchronize(myTasks: tasks, userId: F.me)
        #expect(scheduler.pendingIds.count == 2)

        ReminderLeadTime.off.save(to: store)
        let result = await synchronizer.synchronize(myTasks: tasks, userId: F.me)
        #expect(result.removed.count == 2)
        #expect(scheduler.pendingIds.isEmpty)
    }

    @Test(arguments: [NotificationAuthorization.denied, .notDetermined])
    func notAuthorizedRemovesPendingReminders(status: NotificationAuthorization) async {
        let scheduler = LogicFakeScheduler()
        let store = InMemoryKeyValueStore()
        let synchronizer = makeSynchronizer(scheduler, store)
        let tasks = [F.task(1, due: F.date(2026, 9, 25, 10, 0))]
        await synchronizer.synchronize(myTasks: tasks, userId: F.me)
        #expect(scheduler.pendingIds.count == 1)

        scheduler.authorization = status
        await synchronizer.synchronize(myTasks: tasks, userId: F.me)
        #expect(scheduler.pendingIds.isEmpty)
    }

    @Test func capRollsForwardAsRemindersFire() async {
        let scheduler = LogicFakeScheduler()
        let clock = LogicNow(now)
        let synchronizer = ReminderSynchronizer(
            scheduler: scheduler, store: InMemoryKeyValueStore(), calendar: LogicFixtures.parisCalendar, now: clock.provider
        )
        // Task k fires at now + 3600 + 60·k (1 h before its due date).
        let start = now
        let tasks = (1...61).map { F.task($0, due: start.addingTimeInterval(Double(7200 + $0 * 60))) }
        let first = await synchronizer.synchronize(myTasks: tasks, userId: F.me)
        #expect(first.added.count == 60)
        #expect(scheduler.pendingIds.count == 60)
        #expect(!scheduler.pendingIds.contains { $0.contains(F.uuid(61).uuidString) })

        // Task 1's reminder is delivered (no longer pending) and time passes: task 61 takes the free slot.
        let delivered = ReminderPlanner.identifier(taskId: F.uuid(1), dueAt: tasks[0].dueAt!)
        await scheduler.removePending(ids: [delivered])
        clock.value = start.addingTimeInterval(3600 + 61)
        let second = await synchronizer.synchronize(myTasks: tasks, userId: F.me)
        #expect(second.added == [ReminderPlanner.identifier(taskId: F.uuid(61), dueAt: tasks[60].dueAt!)])
        #expect(second.removed.isEmpty)
        #expect(second.unchanged == 59)
        #expect(scheduler.pendingIds.count == 60)
    }

    @Test func removeAllClearsReminders() async {
        let scheduler = LogicFakeScheduler()
        let synchronizer = makeSynchronizer(scheduler, InMemoryKeyValueStore())
        await synchronizer.synchronize(myTasks: [F.task(1, due: F.date(2026, 9, 25, 10, 0))], userId: F.me)
        await synchronizer.removeAll()
        #expect(scheduler.pendingIds.isEmpty)
    }

    /// Sign-out (`removeAll`) while a "Mes tâches" reload is still scheduling: the in-flight request that the
    /// platform registers late must not stay pending.
    @MainActor @Test func removeAllDuringAnInFlightSynchronizeLeavesNoReminder() async {
        let scheduler = LogicGatedScheduler(gatedCalls: [1])
        let date = now
        let synchronizer = ReminderSynchronizer(
            scheduler: scheduler, store: InMemoryKeyValueStore(), calendar: LogicFixtures.parisCalendar, now: { date }
        )
        let tasks = [F.task(1, title: "Payer le loyer", due: F.date(2026, 9, 25, 10, 0))]
        let inFlight = Task { await synchronizer.synchronize(myTasks: tasks, userId: F.me) }
        await LogicWait.until("first add held") { scheduler.waitingCalls == [1] }

        await synchronizer.removeAll()
        scheduler.open(1)
        _ = await inFlight.value

        #expect(scheduler.pending.isEmpty, "still pending after sign-out: \(scheduler.pending.values.map(\.body))")
        // A later synchronization works normally.
        await synchronizer.synchronize(myTasks: tasks, userId: F.me)
        #expect(scheduler.pending.count == 1)
    }

    /// Lead time changed (1 h → 15 min) while a reload is still scheduling: the two synchronizations must not
    /// interleave, otherwise the stored fingerprints stop describing the pending requests and later
    /// synchronizations never repair them.
    @MainActor @Test func overlappingSynchronizationsConverge() async {
        let scheduler = LogicGatedScheduler(gatedCalls: [2, 5])
        let store = InMemoryKeyValueStore()
        let date = now
        let synchronizer = ReminderSynchronizer(scheduler: scheduler, store: store, calendar: LogicFixtures.parisCalendar, now: { date })
        let t1 = F.task(1, due: F.date(2026, 9, 24, 15, 0))
        let t2 = F.task(2, due: F.date(2026, 9, 24, 16, 0))
        let t3 = F.task(3, due: F.date(2026, 9, 24, 17, 0))

        ReminderLeadTime.oneHour.save(to: store)
        let first = Task { await synchronizer.synchronize(myTasks: [t1, t2], userId: F.me) }
        await LogicWait.until("first synchronization held on its 2nd add") { scheduler.waitingCalls == [2] }

        ReminderLeadTime.fifteenMinutes.save(to: store)
        let second = Task { await synchronizer.synchronize(myTasks: [t1, t2, t3], userId: F.me) }
        await LogicWait.settle()
        scheduler.open(2)
        _ = await first.value
        await LogicWait.until("5th add held") { scheduler.waitingCalls == [5] }
        scheduler.open(5)
        _ = await second.value

        await synchronizer.synchronize(myTasks: [t1, t2, t3], userId: F.me)
        await synchronizer.synchronize(myTasks: [t1, t2, t3], userId: F.me)
        for (task, fire) in [(t1, F.date(2026, 9, 24, 14, 45)), (t2, F.date(2026, 9, 24, 15, 45)), (t3, F.date(2026, 9, 24, 16, 45))] {
            let id = ReminderPlanner.identifier(taskId: task.id, dueAt: task.dueAt!)
            #expect(scheduler.pending[id]?.fireDate == fire, "\(task.title) fires at \(String(describing: scheduler.pending[id]?.fireDate))")
        }
    }

    @Test func platformInitializerUsesPlatformServices() async {
        let scheduler = LogicFakeScheduler()
        let date = now
        let platform = PlatformServices(notifications: scheduler, store: InMemoryKeyValueStore(), now: { date }, calendar: LogicFixtures.parisCalendar)
        let synchronizer = ReminderSynchronizer(platform: platform)
        await synchronizer.synchronize(myTasks: [F.task(1, due: F.date(2026, 9, 25, 10, 0))], userId: F.me)
        #expect(scheduler.pendingIds.count == 1)
        #expect(synchronizer.planner.calendar.timeZone == LogicFixtures.paris)
    }
}
