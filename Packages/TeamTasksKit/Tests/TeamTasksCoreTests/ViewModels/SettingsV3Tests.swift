import Foundation
import Testing
@testable import TeamTasksCore
import TeamTasksMocks

// v3 « Réglages »: the figures of the profile card (docs/CONTRACTS-V3.md §8) and the password change while signed in.

@MainActor
@Suite struct SettingsV3Tests {
    typealias F = VMFixtures

    @Test func personalStatsCountTheTasksTheUserCompleted() async throws {
        let harness = VMHarness()
        let session = harness.makeSession()
        let model = PersonalStatsViewModel(session: session)
        #expect(model.stats == nil)
        #expect(model.needsRefresh)

        // « Nettoyer la cuisine » is done, but by nobody known (v1 data): it does not count.
        await model.load()
        #expect(model.stats == PersonalStats(tasksThisMonth: 0, streakWeeks: 0))
        #expect(!model.needsRefresh)
        let now = session.platform.now()
        #expect(harness.faults.recordedDates(.myCompletions) == [PersonalStats.readStart(now: now, calendar: F.calendar)])

        // Camille completes « Sortir les poubelles »: counted once « Mes tâches » changed.
        _ = try await harness.services.tasks.setStatus(taskId: F.Tasks.sortirPoubelles, status: .done)
        await model.load()
        #expect(harness.faults.calls(.myCompletions) == 1)
        session.feed.bumpMyTasks()
        #expect(model.needsRefresh)
        await model.load()
        #expect(model.stats == PersonalStats(tasksThisMonth: 1, streakWeeks: 1))

        // A task completed by Lucas is not Camille's.
        _ = try await harness.device(F.lucas).tasks.setStatus(taskId: F.Tasks.faireCourses, status: .done)
        await model.reload()
        #expect(model.stats == PersonalStats(tasksThisMonth: 1, streakWeeks: 1))
    }

    @Test func aFailedReadKeepsTheFigures() async throws {
        let harness = VMHarness()
        let session = harness.makeSession()
        let model = PersonalStatsViewModel(session: session)
        harness.faults.fail(.myCompletions, with: AppError.network)
        await model.load()
        #expect(model.stats == nil)
        #expect(model.needsRefresh)

        _ = try await harness.services.tasks.setStatus(taskId: F.Tasks.sortirPoubelles, status: .done)
        await model.load()
        #expect(model.stats == PersonalStats(tasksThisMonth: 1, streakWeeks: 1))

        session.feed.bumpMyTasks()
        harness.faults.fail(.myCompletions, with: AppError.network)
        await model.load()
        #expect(model.stats == PersonalStats(tasksThisMonth: 1, streakWeeks: 1))
        #expect(model.needsRefresh)
    }

    @Test func changePasswordChecksTheFieldsThenSaves() async {
        let harness = VMHarness()
        let model = ChangePasswordViewModel(session: harness.makeSession())
        #expect(!model.canSave)

        model.newPassword = "court"
        model.passwordConfirmation = "court"
        #expect(model.canSave)
        #expect(await !model.save())
        #expect(model.errorMessage == AppError.weakPassword.messageFR)
        #expect(harness.faults.calls(.updatePassword) == 0)

        model.newPassword = "nouveaumotdepasse"
        model.passwordConfirmation = "nouveaumotdepass"
        #expect(await !model.save())
        #expect(model.errorMessage == PasswordResetViewModel.mismatchMessage)
        #expect(harness.faults.calls(.updatePassword) == 0)

        // A network error keeps what was typed.
        model.passwordConfirmation = "nouveaumotdepasse"
        harness.faults.fail(.updatePassword, with: AppError.network)
        #expect(await !model.save())
        #expect(model.errorMessage == AppError.network.messageFR)
        #expect(model.newPassword == "nouveaumotdepasse")
        #expect(!model.isDone)

        #expect(await model.save())
        #expect(model.isDone)
        #expect(model.error == nil)
        #expect(model.newPassword.isEmpty && model.passwordConfirmation.isEmpty)
        #expect(!model.canSave)
        #expect(harness.faults.calls(.updatePassword) == 2)
        #expect(ChangePasswordViewModel.doneMessage == "Ton mot de passe a été modifié.")
    }
}
