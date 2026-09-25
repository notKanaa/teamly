import Foundation
import Testing
@testable import TeamTasksCore
import TeamTasksMocks

// v2 « Réglages »: the avatar and the weekly recap notification; the session schedules the recap while signed in.

@MainActor
@Suite struct SettingsV2Tests {
    typealias F = VMFixtures

    @Test func avatarSheetSavesAndShowsTheNewAvatar() async throws {
        let harness = VMHarness()
        let session = harness.makeSession()
        let settings = SettingsViewModel(session: session)
        #expect(settings.makeAvatarEditor() == nil)
        #expect(settings.avatarAppearance == nil)
        await settings.load()
        #expect(settings.avatarAppearance == AvatarAppearance(color: .coral, emoji: nil, initials: "CM"))
        let editor = try #require(settings.makeAvatarEditor())
        editor.selectColor(.violet)
        editor.selectEmoji("\u{1F43C}")
        let allRevision = session.feed.allRevision
        #expect(await editor.save())
        #expect(session.feed.allRevision == allRevision + 1)
        // The answer of the PATCH keeps what only myProfile() reads.
        #expect(editor.profile.createdAt != nil && editor.profile.onboardedAt != nil)
        settings.apply(editor.profile)
        #expect(settings.avatarAppearance == AvatarAppearance(color: .violet, emoji: "\u{1F43C}", initials: "CM"))
        let seenByLucas = try await harness.device(F.lucas).groups.members(groupId: F.lilas)
        #expect(seenByLucas.first { $0.user.id == F.camille.id }?.user.appearance.emoji == "\u{1F43C}")

        // Back to the initials and the automatic color.
        let again = try #require(settings.makeAvatarEditor())
        again.selectEmoji(nil)
        again.selectColor(.coral)
        #expect(await again.save())
        #expect(again.profile.avatarEmoji == nil)
        #expect(again.profile.avatarColor == .coral)
    }

    @Test func avatarErrorsAreShown() async throws {
        let harness = VMHarness()
        let settings = SettingsViewModel(session: harness.makeSession())
        await settings.load()
        let editor = try #require(settings.makeAvatarEditor())
        editor.selectColor(.teal)
        harness.faults.fail(.updateAvatar, with: AppError.network)
        #expect(await !editor.save())
        #expect(editor.errorMessage == AppError.network.messageFR)
        #expect(editor.color == .teal)
        #expect(editor.hasChanges)
        #expect(await editor.save())
        #expect(!editor.hasChanges)
    }

    @Test func weeklyRecapSwitch() async {
        let harness = VMHarness()
        let session = harness.makeSession()
        let settings = SettingsViewModel(session: session)
        let id = WeeklyRecapNotifier.identifier
        #expect(settings.isWeeklyRecapEnabled)
        #expect(SettingsViewModel.weeklyRecapTitle == "Récap de la semaine")
        #expect(await settings.setWeeklyRecapEnabled(true))
        #expect(harness.scheduler.pending[id]?.repeatsWeekly == WeeklyRecapNotifier.schedule)

        settings.isWeeklyRecapEnabled = false
        await settings.waitForBackgroundWork()
        #expect(!settings.isWeeklyRecapEnabled)
        #expect(!WeeklyRecapNotifier.isEnabled(in: harness.store))
        #expect(harness.scheduler.pending[id] == nil)

        settings.isWeeklyRecapEnabled = true
        await settings.waitForBackgroundWork()
        #expect(harness.scheduler.pending[id] != nil)

        // Not authorized: nothing scheduled, whatever the switch.
        harness.scheduler.authorization = .denied
        #expect(await !settings.setWeeklyRecapEnabled(true))
        #expect(harness.scheduler.pending[id] == nil)
        #expect(settings.isWeeklyRecapEnabled)
    }

    @Test func accountDeletionForgetsTheOnboarding() async {
        let harness = VMHarness()
        let settings = SettingsViewModel(session: harness.makeSession())
        OnboardingStore.markSettled(userId: F.camille.id, in: harness.store)
        OnboardingStore.setPendingCompletion(true, userId: F.camille.id, in: harness.store)
        settings.deleteConfirmation = SettingsViewModel.deleteConfirmationWord
        #expect(await settings.deleteAccount())
        #expect(!OnboardingStore.isSettled(userId: F.camille.id, in: harness.store))
        #expect(!OnboardingStore.hasPendingCompletion(userId: F.camille.id, in: harness.store))
    }
}

@MainActor
@Suite struct SessionWeeklyRecapTests {
    typealias F = VMFixtures

    /// Signed in: the recap is scheduled every Monday at 09:00 (first on Monday 28 September); signed out: removed.
    @Test func scheduledWhileSignedIn() async throws {
        let harness = VMHarness()
        let app = harness.makeApp()
        app.start()
        await VMWait.until("signed in") { app.session != nil }
        let session = try #require(app.session)
        await session.startupTask?.value
        let recap = try #require(harness.scheduler.pending[WeeklyRecapNotifier.identifier])
        #expect(recap.title == "Le récap de la semaine est prêt")
        #expect(recap.repeatsWeekly == WeeklyRepeat(weekday: 1, hour: 9))
        #expect(recap.fireDate == F.date(2026, 9, 28, 9))
        // Due-date reminders are not affected.
        #expect(harness.scheduler.dueIds.count == 3)

        try await harness.services.auth.signOut()
        await VMWait.until("signed out") { app.phase == .signedOut }
        await VMWait.until("recap removed") { harness.scheduler.pending[WeeklyRecapNotifier.identifier] == nil }
        #expect(await !session.synchronizeWeeklyRecap())
        await app.shutdown()
    }

    /// Granted during the session (onboarding, Réglages): scheduled at once.
    @Test func scheduledWhenThePermissionIsGranted() async {
        let harness = VMHarness(authorization: .notDetermined)
        let session = harness.makeSession()
        #expect(await !session.synchronizeWeeklyRecap())
        #expect(harness.scheduler.pending[WeeklyRecapNotifier.identifier] == nil)
        #expect(await session.requestNotificationAuthorizationIfNeeded() == .authorized)
        #expect(harness.scheduler.pending[WeeklyRecapNotifier.identifier] != nil)
    }

    @Test func notificationPromptDeferral() {
        let session = VMHarness().makeSession()
        #expect(!session.isNotificationPromptDeferred)
        session.deferNotificationPrompt()
        #expect(session.isNotificationPromptDeferred)
    }
}
