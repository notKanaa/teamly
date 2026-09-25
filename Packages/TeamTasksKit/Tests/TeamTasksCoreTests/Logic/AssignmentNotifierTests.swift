import Foundation
import Testing
@testable import TeamTasksCore

@Suite struct AssignmentNotifierTests {
    typealias F = LogicFixtures

    let tasks = LogicFakeTaskService()
    let scheduler = LogicFakeScheduler()
    let store = InMemoryKeyValueStore()
    let clock = LogicNow(LogicFixtures.date(2026, 9, 24, 12, 0))

    private func makeNotifier(
        userId: UUID = LogicFixtures.me,
        groupName: @escaping AssignmentNotifier.GroupNameResolver = { _ in nil },
        rememberedLimit: Int = AssignmentNotifier.defaultRememberedLimit
    ) -> AssignmentNotifier {
        AssignmentNotifier(
            userId: userId,
            tasks: tasks,
            scheduler: scheduler,
            store: store,
            now: clock.provider,
            groupName: groupName,
            rememberedLimit: rememberedLimit
        )
    }

    private func event(
        _ number: Int,
        at date: Date,
        by assigner: UUID? = LogicFixtures.other,
        group: UUID = LogicFixtures.groupA,
        groupName: String = "Coloc' rue des Lilas",
        rotation: Bool = false
    ) -> AssignmentEvent {
        AssignmentEvent(
            taskId: F.uuid(number),
            groupId: group,
            taskTitle: "Tâche \(number)",
            groupName: groupName,
            assignedBy: assigner,
            assignedAt: date,
            dueAt: nil,
            taskHasRotation: rotation
        )
    }

    /// A task of a rotation between the current user and another member.
    private func rotatingTask(_ number: Int, title: String? = nil, groupName: String? = "Coloc' rue des Lilas") -> TaskItem {
        var task = F.task(number, title: title, groupName: groupName)
        task.recurrence = RecurrenceRule(frequency: .weekly, timeZoneId: "Europe/Paris")
        task.rotation = [F.other, F.me]
        task.turnUserId = F.me
        return task
    }

    private func realtime(_ number: Int, by assigner: UUID? = LogicFixtures.other) -> RealtimeAssignment {
        RealtimeAssignment(taskId: F.uuid(number), groupId: F.groupA, assignedBy: assigner)
    }

    /// Initializes the cursor to the current fake date.
    private func initializedNotifier() async throws -> AssignmentNotifier {
        let notifier = makeNotifier()
        try await notifier.catchUp()
        return notifier
    }

    // MARK: Catch-up

    /// History is not notified; the cursor is the latest existing assignment (a server timestamp).
    @Test func firstCatchUpOnlyInitializesTheCursor() async throws {
        let history = clock.value.addingTimeInterval(-3600)
        tasks.assignmentEvents = [event(2, at: history.addingTimeInterval(-60)), event(1, at: history)]
        let notifier = makeNotifier()
        let posted = try await notifier.catchUp()
        #expect(posted.isEmpty)
        #expect(tasks.sinceCalls == [clock.value.addingTimeInterval(-AssignmentNotifier.initialLookback)])
        #expect(await notifier.cursor == history)
        #expect(scheduler.added.isEmpty)

        // The next catch-up re-reads the overlap before the cursor: history stays silent.
        clock.value = clock.value.addingTimeInterval(60)
        #expect(try await notifier.catchUp().isEmpty)
        #expect(tasks.sinceCalls.last == history.addingTimeInterval(-AssignmentNotifier.catchUpOverlap))
        #expect(scheduler.added.isEmpty)
    }

    /// Without any assignment yet, the cursor is the start of the lookback period: everything assigned later
    /// is new, whatever the device clock says.
    @Test func firstCatchUpWithoutHistoryStartsAtTheLookback() async throws {
        let notifier = makeNotifier()
        try await notifier.catchUp()
        #expect(await notifier.cursor == clock.value.addingTimeInterval(-AssignmentNotifier.initialLookback))
    }

    @Test func upToFiveAssignmentsAreNotifiedIndividually() async throws {
        let notifier = try await initializedNotifier()
        let start = clock.value
        let cursor = try #require(await notifier.cursor)
        tasks.assignmentEvents = (1...5).map { event($0, at: start.addingTimeInterval(Double($0))) }
        clock.value = start.addingTimeInterval(60)

        let posted = try await notifier.catchUp()
        #expect(tasks.sinceCalls.last == cursor.addingTimeInterval(-AssignmentNotifier.catchUpOverlap))
        #expect(posted.count == 5)
        #expect(posted.map(\.id) == (1...5).map { "assigned-\(F.uuid($0).uuidString)" })
        let first = try #require(posted.first)
        #expect(first.title == "Nouvelle tâche")
        #expect(first.body == "Tâche 1 — Coloc' rue des Lilas")
        #expect(first.fireDate == nil)
        #expect(first.userInfo == ["taskId": F.uuid(1).uuidString, "groupId": F.groupA.uuidString])
        #expect(first.threadId == F.groupA.uuidString)
        #expect(scheduler.added == posted)
        #expect(await notifier.cursor == start.addingTimeInterval(5))

        // Nothing new: the next catch-up re-reads the overlap before the new cursor and posts nothing.
        let again = try await notifier.catchUp()
        #expect(again.isEmpty)
        #expect(tasks.sinceCalls.last == start.addingTimeInterval(5 - AssignmentNotifier.catchUpOverlap))
    }

    @Test func sixAssignmentsGiveASingleSummary() async throws {
        let notifier = try await initializedNotifier()
        let start = clock.value
        tasks.assignmentEvents = (1...6).map { event($0, at: start.addingTimeInterval(Double($0))) }
        clock.value = start.addingTimeInterval(120)

        let posted = try await notifier.catchUp()
        let summary = try #require(posted.first)
        #expect(posted.count == 1)
        #expect(summary.id == "summary-\(ReminderPlanner.epochSeconds(clock.value))")
        #expect(summary.title == "Nouvelles tâches")
        #expect(summary.body == "6 nouvelles tâches assignées")
        #expect(summary.fireDate == nil)
        #expect(summary.userInfo == ["groupId": F.groupA.uuidString])
        #expect(summary.threadId == F.groupA.uuidString)
        #expect(Set(await notifier.rememberedTaskIds) == Set((1...6).map { F.uuid($0) }))

        // The summarized tasks are not notified again by realtime.
        tasks.put(F.task(3))
        #expect(await notifier.handleRealtime(realtime(3)).isEmpty)
    }

    @Test func summaryAcrossGroupsHasNoRoutingInfo() async throws {
        let notifier = try await initializedNotifier()
        let start = clock.value
        tasks.assignmentEvents = (1...7).map {
            event($0, at: start.addingTimeInterval(Double($0)), group: $0.isMultiple(of: 2) ? F.groupA : F.groupB)
        }
        let posted = try await notifier.catchUp()
        #expect(posted.count == 1)
        #expect(posted.first?.body == "7 nouvelles tâches assignées")
        #expect(posted.first?.userInfo == [:])
        #expect(posted.first?.threadId == nil)
    }

    @Test func alreadyNotifiedAssignmentsDoNotCountTowardsTheSummary() async throws {
        let notifier = try await initializedNotifier()
        let start = clock.value
        for number in 1...2 {
            tasks.put(F.task(number))
            await notifier.handleRealtime(realtime(number))
        }
        #expect(scheduler.added.count == 2)
        tasks.assignmentEvents = (1...7).map { event($0, at: start.addingTimeInterval(Double($0))) }

        let posted = try await notifier.catchUp()
        #expect(posted.map(\.id) == (3...7).map { "assigned-\(F.uuid($0).uuidString)" })
    }

    @Test func selfAssignmentsAreIgnoredButAdvanceTheCursor() async throws {
        let notifier = try await initializedNotifier()
        let start = clock.value
        tasks.assignmentEvents = [
            event(1, at: start.addingTimeInterval(1), by: F.me),
            event(2, at: start.addingTimeInterval(2), by: F.me),
        ]
        let posted = try await notifier.catchUp()
        #expect(posted.isEmpty)
        #expect(scheduler.added.isEmpty)
        #expect(await notifier.cursor == start.addingTimeInterval(2))

        tasks.put(F.task(3))
        #expect(await notifier.handleRealtime(realtime(3, by: F.me)).isEmpty)
        #expect(tasks.lookups.isEmpty)
    }

    @Test func assignmentByADeletedAccountIsNotified() async throws {
        let notifier = try await initializedNotifier()
        tasks.assignmentEvents = [event(1, at: clock.value.addingTimeInterval(1), by: nil)]
        #expect(try await notifier.catchUp().count == 1)

        tasks.put(F.task(2))
        #expect(await notifier.handleRealtime(realtime(2, by: nil)).count == 1)
    }

    @Test func catchUpErrorKeepsTheCursor() async throws {
        let notifier = try await initializedNotifier()
        let cursor = await notifier.cursor
        tasks.assignmentsError = .network
        await #expect(throws: AppError.network) {
            try await notifier.catchUp()
        }
        #expect(await notifier.cursor == cursor)

        tasks.assignmentsError = nil
        tasks.assignmentEvents = [event(1, at: clock.value.addingTimeInterval(1))]
        #expect(try await notifier.catchUp().count == 1)
    }

    /// Device clock 10 minutes ahead of the server: the cursor must come from server data, not from the device
    /// date, or assignments made during the skew window are never caught up.
    @Test func deviceClockAheadDoesNotLoseAssignmentsAfterTheFirstCatchUp() async throws {
        let serverNow = clock.value
        clock.value = serverNow.addingTimeInterval(600)
        let notifier = try await initializedNotifier()

        // Server 12:02: an assignment while the app is in background.
        tasks.assignmentEvents = [event(1, at: serverNow.addingTimeInterval(120))]
        clock.value = clock.value.addingTimeInterval(3600)
        let posted = try await notifier.catchUp()
        #expect(posted.map(\.id) == ["assigned-\(F.uuid(1).uuidString)"])
    }

    /// `assigned_at` is the transaction START time: a row can become visible after a newer one that catch-up
    /// already handled. It must still be notified (once).
    @Test func assignmentCommittedAfterANewerOneIsNotified() async throws {
        let notifier = try await initializedNotifier()
        let start = clock.value
        clock.value = start.addingTimeInterval(2)
        tasks.assignmentEvents = [event(2, at: start.addingTimeInterval(1.020))]
        #expect(try await notifier.catchUp().count == 1)

        tasks.assignmentEvents.append(event(1, at: start.addingTimeInterval(1.000)))
        clock.value = start.addingTimeInterval(60)
        let posted = try await notifier.catchUp()
        #expect(posted.map(\.id) == ["assigned-\(F.uuid(1).uuidString)"])
        #expect(try await notifier.catchUp().isEmpty)
        #expect(scheduler.added.count == 2)
    }

    /// A transient `add` failure during catch-up is retried by the next catch-up.
    @Test func failedCatchUpPostIsRetried() async throws {
        let notifier = try await initializedNotifier()
        let start = clock.value
        tasks.assignmentEvents = [event(1, at: start.addingTimeInterval(1)), event(2, at: start.addingTimeInterval(2))]
        scheduler.failingIds = ["assigned-\(F.uuid(1).uuidString)"]
        clock.value = start.addingTimeInterval(10)
        #expect(try await notifier.catchUp().map(\.id) == ["assigned-\(F.uuid(2).uuidString)"])

        scheduler.failingIds = []
        clock.value = start.addingTimeInterval(20)
        #expect(try await notifier.catchUp().map(\.id) == ["assigned-\(F.uuid(1).uuidString)"])
        #expect(try await notifier.catchUp().isEmpty)
    }

    @Test func failedSummaryIsRetried() async throws {
        let notifier = try await initializedNotifier()
        let start = clock.value
        tasks.assignmentEvents = (1...6).map { event($0, at: start.addingTimeInterval(Double($0))) }
        clock.value = start.addingTimeInterval(10)
        scheduler.failingIds = [AssignmentNotifier.summaryIdentifier(at: clock.value)]
        #expect(try await notifier.catchUp().isEmpty)

        clock.value = start.addingTimeInterval(20)
        let posted = try await notifier.catchUp()
        #expect(posted.map(\.body) == ["6 nouvelles tâches assignées"])
        #expect(try await notifier.catchUp().isEmpty)
    }

    // MARK: Realtime

    @Test func realtimeLooksUpTheTask() async throws {
        let notifier = makeNotifier()
        tasks.put(F.task(1, title: "Sortir les poubelles"))
        let posted = await notifier.handleRealtime(realtime(1))
        #expect(tasks.lookups == [F.uuid(1)])
        let notification = try #require(posted.first)
        #expect(posted.count == 1)
        #expect(notification.id == "assigned-\(F.uuid(1).uuidString)")
        #expect(notification.title == "Nouvelle tâche")
        #expect(notification.body == "Sortir les poubelles — Coloc' rue des Lilas")
        #expect(notification.userInfo == ["taskId": F.uuid(1).uuidString, "groupId": F.groupA.uuidString])
        #expect(notification.fireDate == nil)
    }

    @Test func realtimeResolvesTheGroupNameWhenTheTaskHasNone() async throws {
        let resolved = makeNotifier(groupName: { id in id == LogicFixtures.groupA ? "Projet Asso Sport" : nil })
        tasks.put(F.task(1, title: "Réserver le gymnase", groupName: nil))
        #expect(await resolved.handleRealtime(realtime(1)).first?.body == "Réserver le gymnase — Projet Asso Sport")

        let unresolved = makeNotifier(userId: F.me)
        tasks.put(F.task(2, title: "Créer l'affiche", group: F.groupB, groupName: nil))
        let posted = await unresolved.handleRealtime(RealtimeAssignment(taskId: F.uuid(2), groupId: F.groupB, assignedBy: F.other))
        #expect(posted.first?.body == "Créer l'affiche")
    }

    @Test func realtimeDuplicateDeliveryIsNotifiedOnce() async {
        let notifier = makeNotifier()
        tasks.put(F.task(1))
        #expect(await notifier.handleRealtime(realtime(1)).count == 1)
        #expect(await notifier.handleRealtime(realtime(1)).isEmpty)
        #expect(scheduler.added.count == 1)
    }

    @Test func realtimeThenCatchUpIsNotifiedOnce() async throws {
        let notifier = try await initializedNotifier()
        tasks.put(F.task(1))
        clock.value = clock.value.addingTimeInterval(10)
        #expect(await notifier.handleRealtime(realtime(1)).count == 1)

        // The server timestamp may even be slightly after the device's notification date (clock skew).
        tasks.assignmentEvents = [event(1, at: clock.value.addingTimeInterval(2))]
        clock.value = clock.value.addingTimeInterval(600)
        #expect(try await notifier.catchUp().isEmpty)
        #expect(scheduler.added.count == 1)
        #expect(await notifier.cursor == tasks.assignmentEvents[0].assignedAt)
    }

    @Test func catchUpThenRealtimeIsNotifiedOnce() async throws {
        let notifier = try await initializedNotifier()
        tasks.put(F.task(1))
        tasks.assignmentEvents = [event(1, at: clock.value.addingTimeInterval(1))]
        clock.value = clock.value.addingTimeInterval(2)
        #expect(try await notifier.catchUp().count == 1)

        clock.value = clock.value.addingTimeInterval(1)
        #expect(await notifier.handleRealtime(realtime(1)).isEmpty)
        #expect(tasks.lookups.isEmpty)
        #expect(scheduler.added.count == 1)
    }

    @Test func concurrentRealtimeAndCatchUpNotifyOnce() async throws {
        for _ in 0..<20 {
            let tasks = LogicFakeTaskService()
            let scheduler = LogicFakeScheduler()
            let clock = LogicNow(LogicFixtures.date(2026, 9, 24, 12, 0))
            let notifier = AssignmentNotifier(userId: F.me, tasks: tasks, scheduler: scheduler, store: InMemoryKeyValueStore(), now: clock.provider)
            try await notifier.catchUp()
            tasks.put(F.task(1))
            tasks.assignmentEvents = [event(1, at: clock.value.addingTimeInterval(1))]
            clock.value = clock.value.addingTimeInterval(2)

            async let fromRealtime = notifier.handleRealtime(realtime(1))
            async let fromCatchUp = notifier.catchUp()
            let realtimePosted = await fromRealtime
            let catchUpPosted = try await fromCatchUp
            #expect(realtimePosted.count + catchUpPosted.count == 1)
            #expect(scheduler.added.count == 1)
        }
    }

    @Test func failedLookupIsLeftToCatchUp() async throws {
        let notifier = try await initializedNotifier()
        // The task is not readable yet (or the network failed): nothing is posted nor remembered…
        #expect(await notifier.handleRealtime(realtime(1)).isEmpty)
        #expect(await notifier.rememberedTaskIds.isEmpty)
        // …so the next catch-up notifies it.
        tasks.assignmentEvents = [event(1, at: clock.value.addingTimeInterval(1))]
        #expect(try await notifier.catchUp().count == 1)
    }

    @Test func realtimeForATaskNoLongerAssignedToMeIsSkipped() async {
        let notifier = makeNotifier()
        tasks.put(F.task(1, assignees: [F.other]))
        #expect(await notifier.handleRealtime(realtime(1)).isEmpty)
    }

    @Test func reassignmentIsNotifiedAgain() async throws {
        let notifier = try await initializedNotifier()
        let start = clock.value
        tasks.assignmentEvents = [event(1, at: start.addingTimeInterval(1))]
        #expect(try await notifier.catchUp().count == 1)

        // Unassigned then assigned again later: a newer assignedAt.
        tasks.assignmentEvents = [event(1, at: start.addingTimeInterval(3600))]
        clock.value = start.addingTimeInterval(3601)
        #expect(try await notifier.catchUp().count == 1)
        #expect(scheduler.added.count == 2)

        // Realtime reassignment long after the previous notification.
        clock.value = clock.value.addingTimeInterval(AssignmentNotifier.realtimeDedupWindow + 1)
        tasks.put(F.task(1))
        #expect(await notifier.handleRealtime(realtime(1)).count == 1)
    }

    // MARK: Rotation turns (docs/CONTRACTS-V2.md §11)

    /// A turn handed out by the server (`assigned_by` NULL on a rotating task) is « C’est ton tour ».
    @Test func catchUpWordsRotationTurns() async throws {
        let notifier = try await initializedNotifier()
        let start = clock.value
        tasks.assignmentEvents = [
            event(1, at: start.addingTimeInterval(1), by: nil, rotation: true),
            // The first turn of a new rotation, given by the editor: the v1 wording.
            event(2, at: start.addingTimeInterval(2), by: F.other, rotation: true),
            // A continuation of a recurring task (assigned by the assignee): not notified.
            event(3, at: start.addingTimeInterval(3), by: F.me, rotation: true),
            // assigned_by NULL without rotation (a deleted assigner): the v1 wording.
            event(4, at: start.addingTimeInterval(4), by: nil),
        ]
        let posted = try await notifier.catchUp()
        #expect(posted.map(\.id) == [1, 2, 4].map { "assigned-\(F.uuid($0).uuidString)" })
        #expect(posted.map(\.title) == ["C’est ton tour", "Nouvelle tâche", "Nouvelle tâche"])
        #expect(posted.first?.body == "«\u{00A0}Tâche 1\u{00A0}» dans «\u{00A0}Coloc' rue des Lilas\u{00A0}»")
        #expect(posted.first?.userInfo == ["taskId": F.uuid(1).uuidString, "groupId": F.groupA.uuidString])
        #expect(posted.first?.threadId == F.groupA.uuidString)
        #expect(posted.dropFirst().map(\.body) == ["Tâche 2 — Coloc' rue des Lilas", "Tâche 4 — Coloc' rue des Lilas"])
    }

    @Test func realtimeWordsRotationTurns() async throws {
        let notifier = makeNotifier()
        tasks.put(rotatingTask(1, title: "Sortir les poubelles"))
        let turn = await notifier.handleRealtime(realtime(1, by: nil))
        #expect(turn.map(\.title) == [AssignmentNotifier.rotationTurnTitle])
        #expect(turn.map(\.body) == ["«\u{00A0}Sortir les poubelles\u{00A0}» dans «\u{00A0}Coloc' rue des Lilas\u{00A0}»"])

        // Assigned by the editor of the rotation: the v1 wording.
        tasks.put(rotatingTask(2, title: "Arroser les plantes"))
        let edited = await notifier.handleRealtime(realtime(2, by: F.other))
        #expect(edited.map(\.title) == [AssignmentNotifier.individualTitle])
        #expect(edited.map(\.body) == ["Arroser les plantes — Coloc' rue des Lilas"])
    }

    @Test func rotationTurnWithoutGroupName() async {
        let notifier = makeNotifier()
        tasks.put(rotatingTask(1, title: "Vaisselle", groupName: nil))
        #expect(await notifier.handleRealtime(realtime(1, by: nil)).map(\.body) == ["«\u{00A0}Vaisselle\u{00A0}»"])
        #expect(AssignmentNotifier.rotationTurnBody(taskTitle: "Vaisselle", groupName: "") == "«\u{00A0}Vaisselle\u{00A0}»")
    }

    /// More than `maxIndividual` new assignments still give the v1 summary, rotation turns included.
    @Test func rotationTurnsCountInTheSummary() async throws {
        let notifier = try await initializedNotifier()
        let start = clock.value
        tasks.assignmentEvents = (1...6).map { event($0, at: start.addingTimeInterval(Double($0)), by: nil, rotation: $0.isMultiple(of: 2)) }
        let posted = try await notifier.catchUp()
        #expect(posted.map(\.title) == ["Nouvelles tâches"])
        #expect(posted.map(\.body) == ["6 nouvelles tâches assignées"])
    }

    // MARK: Authorization

    @Test func notAuthorizedPostsNothingButAdvancesTheCursor() async throws {
        let notifier = try await initializedNotifier()
        let start = clock.value
        scheduler.authorization = .denied
        tasks.assignmentEvents = (1...3).map { event($0, at: start.addingTimeInterval(Double($0))) }

        #expect(try await notifier.catchUp().isEmpty)
        #expect(await notifier.cursor == start.addingTimeInterval(3))
        #expect(scheduler.added.isEmpty)

        tasks.put(F.task(9))
        #expect(await notifier.handleRealtime(realtime(9)).isEmpty)
        #expect(tasks.lookups.isEmpty)

        // Once authorized, only newer assignments are notified.
        scheduler.authorization = .authorized
        tasks.assignmentEvents.append(event(4, at: start.addingTimeInterval(4)))
        let posted = try await notifier.catchUp()
        #expect(posted.map(\.id) == ["assigned-\(F.uuid(4).uuidString)"])
    }

    @Test func notDeterminedIsTreatedAsNotGranted() async throws {
        let notifier = try await initializedNotifier()
        scheduler.authorization = .notDetermined
        tasks.assignmentEvents = [event(1, at: clock.value.addingTimeInterval(1))]
        #expect(try await notifier.catchUp().isEmpty)
        #expect(scheduler.added.isEmpty)
    }

    // MARK: Persistence

    @Test func rememberedSetIsBounded() async {
        let notifier = makeNotifier(rememberedLimit: 3)
        for number in 1...5 {
            tasks.put(F.task(number))
            await notifier.handleRealtime(realtime(number))
        }
        #expect(await notifier.rememberedTaskIds == [F.uuid(3), F.uuid(4), F.uuid(5)])
    }

    @Test func stateSurvivesANewInstance() async throws {
        let first = try await initializedNotifier()
        tasks.put(F.task(1))
        #expect(await first.handleRealtime(realtime(1)).count == 1)
        let cursor = await first.cursor

        let second = makeNotifier()
        #expect(await second.cursor == cursor)
        #expect(await second.rememberedTaskIds == [F.uuid(1)])
        #expect(await second.handleRealtime(realtime(1)).isEmpty)
        #expect(store.data(forKey: AssignmentNotifier.storageKey(userId: F.me)) != nil)
    }

    @Test func stateIsPerUser() async throws {
        let mine = try await initializedNotifier()
        tasks.put(F.task(1, assignees: [F.me, F.other]))
        #expect(await mine.handleRealtime(realtime(1)).count == 1)

        let theirs = makeNotifier(userId: F.other)
        #expect(await theirs.cursor == nil)
        #expect(await theirs.rememberedTaskIds.isEmpty)
        let posted = await theirs.handleRealtime(RealtimeAssignment(taskId: F.uuid(1), groupId: F.groupA, assignedBy: F.me))
        #expect(posted.count == 1)
    }

    @Test func resetForgetsEverything() async throws {
        let notifier = try await initializedNotifier()
        tasks.put(F.task(1))
        await notifier.handleRealtime(realtime(1))
        await notifier.reset()
        #expect(await notifier.cursor == nil)
        #expect(await notifier.rememberedTaskIds.isEmpty)
    }

    @Test func failedPostIsNotRemembered() async {
        let notifier = makeNotifier()
        tasks.put(F.task(1))
        scheduler.failingIds = ["assigned-\(F.uuid(1).uuidString)"]
        #expect(await notifier.handleRealtime(realtime(1)).isEmpty)
        #expect(await notifier.rememberedTaskIds.isEmpty)
        scheduler.failingIds = []
        #expect(await notifier.handleRealtime(realtime(1)).count == 1)
    }
}
