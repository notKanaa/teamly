import Foundation
import Testing
@testable import TeamTasksCore
import TeamTasksMocks

@MainActor
@Suite struct AppModelTests {
    typealias F = VMFixtures
    typealias T = VMFixtures.Tasks

    @Test func restoresTheSessionAndStartsIt() async throws {
        let harness = VMHarness()
        let app = harness.makeApp()
        #expect(app.phase == .launching)
        #expect(app.session == nil)
        app.start()
        app.start()
        await VMWait.until("signed in") { app.session != nil }
        let session = try #require(app.session)
        #expect(session.userId == F.camille.id)
        #expect(session.user.email == F.camille.email)
        #expect(session.isRunning)
        #expect(app.router.isActive)
        #expect(app.phase == .signedIn(session))
        await VMWait.until("realtime subscribed") { harness.backend.realtimeSubscriberCount == 1 }
        await session.startupTask?.value
        // Startup synchronizes the reminders with « Mes tâches ».
        let expected = try await harness.reminderIds([T.sortirPoubelles, T.faireCourses, T.reserverGymnase])
        #expect(harness.scheduler.dueIds == expected)
        await app.shutdown()
        #expect(app.phase == .signedOut)
        await VMWait.until("realtime stopped") { harness.backend.realtimeSubscriberCount == 0 }
    }

    @Test func signedOutThenSignIn() async throws {
        let harness = VMHarness(.signedOut)
        let app = harness.makeApp()
        app.start()
        await VMWait.until("signed out") { app.phase == .signedOut }
        #expect(!app.router.isActive)

        let login = app.makeLoginViewModel(email: F.camille.email)
        login.password = DemoData.password
        #expect(await login.signIn())
        await VMWait.until("signed in") { app.session != nil }
        #expect(app.session?.userId == F.camille.id)
        await app.shutdown()
    }

    @Test func signOutTearsTheSessionDown() async throws {
        let harness = VMHarness()
        let app = harness.makeApp()
        app.start()
        await VMWait.until("signed in") { app.session != nil }
        let session = try #require(app.session)
        await session.startupTask?.value
        await VMWait.until("realtime subscribed") { harness.backend.realtimeSubscriberCount == 1 }
        #expect(harness.scheduler.dueIds.count == 3)
        #expect(harness.store.data(forKey: AssignmentNotifier.storageKey(userId: F.camille.id)) != nil)
        app.router.showTask(groupId: F.lilas, taskId: T.faireCourses)

        let settings = SettingsViewModel(session: session)
        #expect(await settings.signOut())
        await VMWait.until("signed out") { app.phase == .signedOut }
        await VMWait.until("session stopped") { session.isStopped }
        await VMWait.until("reminders removed") { harness.scheduler.dueIds.isEmpty }
        await VMWait.until("realtime stopped") { harness.backend.realtimeSubscriberCount == 0 }
        await VMWait.until("notifier reset") {
            harness.store.data(forKey: AssignmentNotifier.storageKey(userId: F.camille.id)) == nil
        }
        #expect(!session.isRunning)
        #expect(!app.router.isActive)
        #expect(app.router.groupsPath.isEmpty)
        // A stopped session schedules nothing any more.
        #expect(await !session.synchronizeReminders())
        session.start()
        #expect(!session.isRunning)
        await app.shutdown()
    }

    @Test func accountDeletionEndsTheSession() async throws {
        let harness = VMHarness()
        let app = harness.makeApp()
        app.start()
        await VMWait.until("signed in") { app.session != nil }
        let session = try #require(app.session)
        await session.startupTask?.value
        let settings = SettingsViewModel(session: session)
        settings.deleteConfirmation = SettingsViewModel.deleteConfirmationWord
        #expect(await settings.deleteAccount())
        await VMWait.until("signed out") { app.phase == .signedOut }
        await VMWait.until("reminders removed") { harness.scheduler.dueIds.isEmpty }
        await app.shutdown()
    }

    @Test func switchingUserReplacesTheSession() async throws {
        let harness = VMHarness()
        let app = harness.makeApp()
        app.start()
        await VMWait.until("signed in") { app.session != nil }
        let first = try #require(app.session)
        await first.startupTask?.value

        try await harness.services.auth.signIn(email: F.lucas.email, password: DemoData.password)
        await VMWait.until("second session") { app.session != nil && app.session !== first }
        let second = try #require(app.session)
        #expect(second.userId == F.lucas.id)
        #expect(first.isStopped)
        #expect(second.isRunning)
        await second.startupTask?.value
        // Lucas's reminders: « Faire les courses » and « Créer l'affiche du tournoi ».
        let expected = try await harness.reminderIds([T.faireCourses, T.creerAffiche])
        #expect(harness.scheduler.dueIds == expected)
        await app.shutdown()
    }

    @Test func deepLinkReceivedWhileSignedOutOpensAfterSignIn() async throws {
        let harness = VMHarness(.signedOut)
        let app = harness.makeApp()
        app.start()
        await VMWait.until("signed out") { app.phase == .signedOut }
        let url = DeepLink.task(groupId: F.lilas, taskId: T.faireCourses).url
        #expect(app.open(url: url))
        #expect(app.router.pendingDeepLink == .task(groupId: F.lilas, taskId: T.faireCourses))
        #expect(app.router.groupsPath.isEmpty)

        try await harness.services.auth.signIn(email: F.camille.email, password: DemoData.password)
        await VMWait.until("signed in") { app.session != nil }
        #expect(app.router.groupsPath == [.group(F.lilas), .task(groupId: F.lilas, taskId: T.faireCourses)])
        #expect(app.router.pendingDeepLink == nil)
        #expect(!app.open(url: URL(string: "https://example.com")!))
        await app.shutdown()
    }

    @Test func foregroundReloadsEverythingAndResynchronizes() async throws {
        let harness = VMHarness()
        let app = harness.makeApp()
        app.start()
        await VMWait.until("signed in") { app.session != nil }
        let session = try #require(app.session)
        await session.startupTask?.value
        harness.scheduler.clearPending()
        let allRevision = session.feed.allRevision

        await app.handleForeground()
        #expect(session.feed.allRevision > allRevision)
        #expect(harness.scheduler.dueIds.count == 3)

        await app.handleSignificantTimeChange()
        #expect(session.feed.allRevision > allRevision + 1)
        await app.shutdown()
    }

    @Test func backgroundRefreshWorksWithoutTheRootView() async throws {
        let harness = VMHarness()
        let app = harness.makeApp()
        // No `start()` from a view: launched in the background.
        await app.handleBackgroundRefresh()
        let session = try #require(app.session)
        #expect(session.userId == F.camille.id)
        await session.startupTask?.value
        #expect(harness.scheduler.dueIds.count == 3)
        // The auth stream then confirms the same user: same session.
        await VMWait.settle()
        #expect(app.session === session)
        await app.shutdown()
    }

    @Test func backgroundRefreshNeverClearsRemindersOnFailure() async throws {
        let harness = VMHarness()
        let app = harness.makeApp()
        app.start()
        await VMWait.until("signed in") { app.session != nil }
        let session = try #require(app.session)
        await session.startupTask?.value
        let before = harness.scheduler.dueIds
        #expect(before.count == 3)

        harness.faults.fail(.myTasks, with: AppError.network)
        harness.faults.fail(.assignments, with: AppError.network)
        await app.handleBackgroundRefresh()
        #expect(harness.scheduler.dueIds == before)
        await app.shutdown()
    }

    @Test func backgroundRefreshWhileSignedOutDoesNothing() async {
        let harness = VMHarness(.signedOut)
        let app = harness.makeApp()
        await app.handleBackgroundRefresh()
        await VMWait.until("signed out") { app.phase == .signedOut }
        #expect(app.session == nil)
        #expect(harness.faults.calls(.myTasks) == 0)
        await app.shutdown()
    }

    @Test func realtimeAssignmentPostsANotification() async throws {
        let harness = VMHarness()
        let app = harness.makeApp()
        app.start()
        await VMWait.until("signed in") { app.session != nil }
        let session = try #require(app.session)
        await session.startupTask?.value
        await VMWait.until("realtime subscribed") { harness.backend.realtimeSubscriberCount == 1 }
        // The first `.connected` bumps everything.
        await VMWait.until("connected") { session.feed.allRevision >= 1 }
        let myTasksRevision = session.feed.myTasksRevision

        let task = try await harness.device(F.lucas).tasks.create(
            groupId: F.lilas,
            draft: TaskDraft(title: "Descendre le carton", assigneeIds: [F.camille.id])
        )
        let id = AssignmentNotifier.individualIdentifier(taskId: task.id)
        await VMWait.until("notification") { harness.scheduler.delivered.contains { $0.id == id } }
        let notification = try #require(harness.scheduler.delivered.first { $0.id == id })
        #expect(notification.title == "Nouvelle tâche")
        #expect(notification.body == "Descendre le carton — Coloc' rue des Lilas")
        #expect(notification.userInfo == ["taskId": task.id.uuidString, "groupId": F.lilas.uuidString])
        await VMWait.until("my tasks bumped") { session.feed.myTasksRevision > myTasksRevision }
        await VMWait.until("group bumped") { session.feed.groupRevision(F.lilas) > session.feed.allRevision }

        // Tapping it routes to the task.
        app.router.open(DeepLink(notificationUserInfo: notification.userInfo))
        #expect(app.router.groupsPath == [.group(F.lilas), .task(groupId: F.lilas, taskId: task.id)])
        await app.shutdown()
    }
}

@MainActor
@Suite struct SessionModelTests {
    typealias F = VMFixtures
    typealias T = VMFixtures.Tasks

    @Test func startsOnceAndSubscribesToTheUsersGroups() async {
        let harness = VMHarness()
        let session = harness.makeSession()
        #expect(!session.isRunning)
        session.start()
        session.start()
        #expect(session.isRunning)
        await VMWait.until("subscribed") { session.realtime.subscribedGroupIds.count == 2 }
        #expect(Set(session.realtime.subscribedGroupIds) == [F.lilas, F.sport])
        #expect(harness.backend.realtimeSubscriberCount == 1)
        await session.startupTask?.value
        await session.stop()
        await session.stop()
        #expect(session.isStopped)
        #expect(session.realtime.subscribedGroupIds.isEmpty)
        await VMWait.until("unsubscribed") { harness.backend.realtimeSubscriberCount == 0 }
    }

    @Test func groupActivityBumpsTheFeed() async throws {
        let harness = VMHarness()
        let session = harness.makeSession()
        session.start()
        await VMWait.until("connected") { session.feed.allRevision >= 1 }
        let before = session.feed.groupRevision(F.sport)
        _ = try await harness.device(F.lucas).tasks.setStatus(taskId: T.creerAffiche, status: .done)
        await VMWait.until("sport bumped") { session.feed.groupRevision(F.sport) > before }
        await session.stop()
    }

    /// Cold start offline (the first `myGroups()` fails): the groups are subscribed as soon as the channel connects,
    /// and group activity reaches the feed (review VM-1 / ADP-1).
    @Test func failedFirstGroupFetchIsRecovered() async throws {
        let harness = VMHarness()
        harness.faults.fail(.myGroups, with: AppError.network)
        let session = harness.makeSession()
        session.start()
        await VMWait.until("subscribed to both groups") { session.realtime.subscribedGroupIds == [F.lilas, F.sport] }
        #expect(!session.realtime.groupIdsAreStale)
        await session.startupTask?.value

        let before = session.feed.groupRevision(F.sport)
        _ = try await harness.device(F.lucas).tasks.setStatus(taskId: T.creerAffiche, status: .done)
        await VMWait.until("sport bumped") { session.feed.groupRevision(F.sport) > before }
        await session.stop()
    }

    @Test func foregroundFetchesTheRealtimeGroupIdsAgain() async throws {
        let harness = VMHarness()
        let session = harness.makeSession()
        session.start()
        await VMWait.until("subscribed") { session.realtime.subscribedGroupIds.count == 2 }
        await session.startupTask?.value
        let calls = harness.faults.calls(.myGroups)
        await session.handleForeground()
        await VMWait.until("group ids fetched again") { harness.faults.calls(.myGroups) > calls }
        await session.stop()
    }

    @Test func catchUpNotifiesAssignmentsMadeWhileAway() async throws {
        let harness = VMHarness()
        let session = harness.makeSession()
        // First catch-up: history is not notified, only the cursor is set.
        await session.catchUpAssignments()
        #expect(harness.scheduler.delivered.isEmpty)

        harness.clock.advance(by: 300)
        let task = try await harness.device(F.lucas).tasks.create(
            groupId: F.sport,
            draft: TaskDraft(title: "Acheter les ballons", assigneeIds: [F.camille.id])
        )
        harness.clock.advance(by: 300)
        await session.catchUpAssignments()
        #expect(harness.scheduler.delivered.map(\.id) == [AssignmentNotifier.individualIdentifier(taskId: task.id)])
        #expect(harness.scheduler.delivered.first?.body == "Acheter les ballons — Projet Asso Sport")

        // Nothing new: nothing posted again.
        await session.catchUpAssignments()
        #expect(harness.scheduler.delivered.count == 1)
    }

    @Test func remindersFollowOnlySuccessfulLists() async throws {
        let harness = VMHarness()
        let session = harness.makeSession()
        #expect(await session.synchronizeReminders())
        #expect(harness.scheduler.dueIds.count == 3)

        harness.faults.fail(.myTasks, with: AppError.network)
        #expect(await !session.synchronizeReminders())
        #expect(harness.scheduler.dueIds.count == 3)

        await session.synchronizeReminders(with: [])
        #expect(harness.scheduler.dueIds.isEmpty)
    }

    @Test func notificationAuthorizationRequest() async {
        let harness = VMHarness(authorization: .notDetermined)
        let session = harness.makeSession()
        #expect(await session.requestNotificationAuthorizationIfNeeded() == .authorized)
        #expect(harness.scheduler.requestCount == 1)
        #expect(harness.scheduler.dueIds.count == 3)

        let denied = VMHarness(authorization: .denied)
        let other = denied.makeSession()
        #expect(await other.requestNotificationAuthorizationIfNeeded() == .denied)
        #expect(denied.scheduler.requestCount == 0)
    }

    @Test func notAuthorizedMeansNoReminders() async {
        let harness = VMHarness(authorization: .denied)
        let session = harness.makeSession()
        #expect(await session.synchronizeReminders())
        #expect(harness.scheduler.dueIds.isEmpty)
    }

    @Test func foregroundIsIgnoredUntilStarted() async {
        let harness = VMHarness()
        let session = harness.makeSession()
        await session.handleForeground()
        #expect(session.feed.allRevision == 0)
        #expect(harness.faults.calls(.myTasks) == 0)
        await session.handleBackgroundRefresh()
        #expect(harness.faults.calls(.myTasks) == 1)
    }
}
