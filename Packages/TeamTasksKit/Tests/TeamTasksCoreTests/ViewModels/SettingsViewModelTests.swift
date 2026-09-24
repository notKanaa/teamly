import Foundation
import Testing
@testable import TeamTasksCore
import TeamTasksMocks

@MainActor
@Suite struct SettingsViewModelTests {
    typealias F = VMFixtures
    typealias T = VMFixtures.Tasks

    @Test func loadsProfilePushAndPermission() async {
        let harness = VMHarness()
        let model = SettingsViewModel(session: harness.makeSession())
        await model.load()
        #expect(model.loadState == .loaded)
        #expect(model.profile?.displayName == "Camille Martin")
        #expect(model.displayName == "Camille Martin")
        #expect(model.email == "camille@example.com")
        #expect(!model.canSaveDisplayName)
        #expect(model.pushTopic == nil)
        #expect(!model.isPushEnabled)
        #expect(model.notificationStatus == .authorized)
        #expect(model.notificationStatusText == "Activées")
        #expect(model.notificationHint == nil)
        #expect(model.leadTime == .oneHour)
        #expect(model.leadTimeOptions.count == 5)
        await model.load()
        #expect(harness.faults.calls(.myProfile) == 1)
    }

    @Test func editsTheDisplayName() async throws {
        let harness = VMHarness()
        let session = harness.makeSession()
        let model = SettingsViewModel(session: session)
        await model.load()

        model.displayName = "   "
        #expect(!model.canSaveDisplayName)
        #expect(await !model.saveDisplayName())
        #expect(model.displayNameError == AppError.invalidDisplayName.messageFR)
        #expect(harness.faults.calls(.updateDisplayName) == 0)

        model.displayName = " Camille M. "
        #expect(model.displayNameError == nil)
        #expect(model.canSaveDisplayName)
        let allRevision = session.feed.allRevision
        #expect(await model.saveDisplayName())
        #expect(model.profile?.displayName == "Camille M.")
        #expect(model.displayName == "Camille M.")
        #expect(session.feed.allRevision == allRevision + 1)
        #expect(try await harness.device(F.lucas).groups.members(groupId: F.lilas).contains { $0.user.displayName == "Camille M." })

        // A reload keeps a name being edited.
        model.displayName = "Brouillon"
        await model.reload()
        #expect(model.displayName == "Brouillon")
    }

    @Test func leadTimeIsPersistedAndReschedulesReminders() async throws {
        let harness = VMHarness()
        let session = harness.makeSession()
        let model = SettingsViewModel(session: session)
        await model.load()
        #expect(await session.synchronizeReminders())
        let poubellesDue = try #require(try await harness.services.tasks.task(id: T.sortirPoubelles).dueAt)
        let poubellesId = ReminderPlanner.identifier(taskId: T.sortirPoubelles, dueAt: poubellesDue)
        #expect(harness.scheduler.pending[poubellesId]?.fireDate == poubellesDue.addingTimeInterval(-3600))

        #expect(await model.setLeadTime(.fifteenMinutes))
        #expect(model.leadTime == .fifteenMinutes)
        #expect(ReminderLeadTime.load(from: harness.store) == .fifteenMinutes)
        #expect(harness.scheduler.pending[poubellesId]?.fireDate == poubellesDue.addingTimeInterval(-900))

        // The picker binding persists and resynchronizes in the background.
        model.leadTime = .off
        await model.waitForBackgroundWork()
        #expect(ReminderLeadTime.load(from: harness.store) == .off)
        #expect(harness.scheduler.dueIds.isEmpty)

        // A failed list keeps the current schedule.
        model.leadTime = .oneHour
        await model.waitForBackgroundWork()
        #expect(harness.scheduler.dueIds.count == 3)
        harness.faults.fail(.myTasks, with: AppError.network)
        #expect(await !model.setLeadTime(.atDueTime))
        #expect(harness.scheduler.dueIds.count == 3)
        #expect(harness.scheduler.pending[poubellesId]?.fireDate == poubellesDue.addingTimeInterval(-3600))
    }

    @Test func pushTopicLifecycle() async throws {
        let harness = VMHarness()
        let model = SettingsViewModel(session: harness.makeSession())
        await model.load()
        #expect(SettingsViewModel.pushInstructionSteps.count == 3)
        #expect(SettingsViewModel.pushInstructionSteps[0].contains("ntfy"))
        #expect(SettingsViewModel.pushInstructionSteps[2]
            == "Une notification vous prévient quand une tâche vous est assignée, même quand Équipe est fermée.")

        #expect(await model.setPushEnabled(true))
        let topic = try #require(model.pushTopic)
        #expect(topic.hasPrefix("equipe-"))
        #expect(model.isPushEnabled)
        #expect(model.pushTopicURL?.absoluteString == "https://ntfy.sh/\(topic)")
        #expect(model.ntfyAppURL?.absoluteString == "ntfy://ntfy.sh/\(topic)")
        #expect(try await harness.services.push.currentTopic() == topic)

        #expect(await model.enablePush())
        #expect(model.pushTopic == topic)

        #expect(await model.setPushEnabled(false))
        #expect(model.pushTopic == nil)
        #expect(model.pushTopicURL == nil)
        #expect(try await harness.services.push.currentTopic() == nil)

        harness.faults.fail(.enablePush, with: AppError.network)
        #expect(await !model.enablePush())
        #expect(model.errorMessage == AppError.network.messageFR)
        #expect(!model.isPushEnabled)
    }

    @Test func notificationPermission() async throws {
        let harness = VMHarness(authorization: .notDetermined)
        let model = SettingsViewModel(session: harness.makeSession())
        await model.load()
        #expect(model.notificationStatus == .notDetermined)
        #expect(model.canRequestNotifications)
        #expect(model.notificationStatusText == "Pas encore demandées")
        #expect(model.notificationHint != nil)

        #expect(await model.requestNotifications())
        #expect(model.notificationStatus == .authorized)
        #expect(!model.canRequestNotifications)
        // Granted: the reminders are scheduled right away.
        let expected = try await harness.reminderIds([T.sortirPoubelles, T.faireCourses, T.reserverGymnase])
        #expect(harness.scheduler.dueIds == expected)

        // Asking again does not prompt again.
        #expect(await model.requestNotifications())
        #expect(harness.scheduler.requestCount == 1)
    }

    @Test func refusedNotifications() async {
        let harness = VMHarness(authorization: .notDetermined)
        harness.scheduler.grantOnRequest = false
        let model = SettingsViewModel(session: harness.makeSession())
        #expect(await !model.requestNotifications())
        #expect(model.notificationStatus == .denied)
        #expect(model.notificationStatusText == "Refusées")
        #expect(model.notificationHint?.contains("Réglages") == true)
        #expect(harness.scheduler.dueIds.isEmpty)

        harness.scheduler.authorization = .authorized
        await model.refreshNotificationStatus()
        #expect(model.notificationStatus == .authorized)
    }

    @Test func accountDeletionNeedsTheExactWord() async throws {
        let harness = VMHarness()
        let session = harness.makeSession()
        let model = SettingsViewModel(session: session)
        harness.store.setValue(F.now, forKey: MyTasksViewModel.lastSeenKey(userId: F.camille.id))
        #expect(!model.canDeleteAccount)
        model.deleteConfirmation = "supprimer"
        #expect(!model.canDeleteAccount)
        #expect(await !model.deleteAccount())
        #expect(model.errorMessage == "Tapez «\u{00A0}SUPPRIMER\u{00A0}» pour confirmer.")
        model.deleteConfirmation = " SUPPRIMER"
        #expect(!model.canDeleteAccount)
        #expect(harness.faults.calls(.deleteAccount) == 0)

        model.deleteConfirmation = "SUPPRIMER"
        #expect(model.canDeleteAccount)
        #expect(SettingsViewModel.deleteAccountWarning.contains("«\u{00A0}SUPPRIMER\u{00A0}»"))
        #expect(SettingsViewModel.deleteAccountWarning.contains("deviendra admin si vous étiez le seul admin."))
        #expect(await model.deleteAccount())
        #expect(await harness.services.auth.currentUser() == nil)
        #expect(harness.backend.userId(forEmail: F.camille.email) == nil)
        #expect(harness.store.data(forKey: MyTasksViewModel.lastSeenKey(userId: F.camille.id)) == nil)
        #expect(model.deleteConfirmation.isEmpty)
    }

    @Test func deletionFailureIsShown() async {
        let harness = VMHarness()
        let model = SettingsViewModel(session: harness.makeSession())
        model.deleteConfirmation = "SUPPRIMER"
        harness.faults.fail(.deleteAccount, with: AppError.network)
        #expect(await !model.deleteAccount())
        #expect(model.errorMessage == AppError.network.messageFR)
        #expect(await harness.services.auth.currentUser() != nil)
    }

    /// `delete_my_account` ran but its answer was lost: « Réessayer » finds the account gone, which is the requested
    /// end state. The app signs out and the reminders of the deleted account are removed (review VM-2).
    @Test func retryAfterALostAnswerCompletesTheDeletion() async throws {
        let harness = VMHarness()
        let app = harness.makeApp()
        app.start()
        await VMWait.until("signed in") { app.session != nil }
        let session = try #require(app.session)
        await session.startupTask?.value
        #expect(harness.scheduler.dueIds.count == 3)
        let settings = SettingsViewModel(session: session)
        settings.deleteConfirmation = SettingsViewModel.deleteConfirmationWord
        harness.store.setValue(F.now, forKey: MyTasksViewModel.lastSeenKey(userId: F.camille.id))

        // Server side the account is deleted; client side the answer never arrives.
        try await harness.device(F.camille).auth.deleteAccount()
        harness.faults.fail(.deleteAccount, with: AppError.network)
        #expect(await !settings.deleteAccount())
        #expect(settings.errorMessage == AppError.network.messageFR)

        #expect(await settings.deleteAccount(), "retry error: \(settings.errorMessage ?? "-")")
        await VMWait.until("signed out") { app.phase == .signedOut }
        await VMWait.until("reminders removed") { harness.scheduler.dueIds.isEmpty }
        #expect(harness.store.data(forKey: MyTasksViewModel.lastSeenKey(userId: F.camille.id)) == nil)
        #expect(await harness.services.auth.currentUser() == nil)
        await app.shutdown()
    }

    @Test func signsOut() async {
        let harness = VMHarness()
        let model = SettingsViewModel(session: harness.makeSession())
        #expect(await model.signOut())
        #expect(await harness.services.auth.currentUser() == nil)
        #expect(!model.isSigningOut)
    }

    @Test func loadFailure() async {
        let harness = VMHarness()
        let model = SettingsViewModel(session: harness.makeSession())
        harness.faults.fail(.currentTopic, with: AppError.network)
        await model.load()
        #expect(model.loadState == .failed(AppError.network.messageFR))
        await model.load()
        #expect(model.loadState == .loaded)
    }

    @Test func reloadsWhenMembershipsSignalArrives() async {
        let harness = VMHarness()
        let session = harness.makeSession()
        let model = SettingsViewModel(session: session)
        await model.load()
        session.feed.bumpMemberships()
        #expect(model.needsRefresh)
        await model.load()
        #expect(harness.faults.calls(.myProfile) == 2)
    }
}
