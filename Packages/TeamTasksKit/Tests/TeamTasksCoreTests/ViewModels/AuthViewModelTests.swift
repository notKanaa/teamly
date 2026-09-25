import Foundation
import Testing
@testable import TeamTasksCore
import TeamTasksMocks

@MainActor
@Suite struct LoginViewModelTests {
    @Test func signsInWithNormalizedEmail() async {
        let harness = VMHarness(.signedOut)
        let model = LoginViewModel(services: harness.services, email: "  Camille@Example.com ")
        #expect(!model.canSubmit)
        model.password = DemoData.password
        #expect(model.canSubmit)

        #expect(await model.signIn())
        #expect(model.password.isEmpty)
        #expect(model.error == nil)
        #expect(!model.isSubmitting)
        #expect(await harness.services.auth.currentUser()?.id == VMFixtures.camille.id)
    }

    @Test func wrongPasswordShowsInvalidCredentials() async {
        let harness = VMHarness(.signedOut)
        let model = LoginViewModel(services: harness.services, email: VMFixtures.camille.email)
        model.password = "mauvais-mot-de-passe"
        #expect(await !model.signIn())
        #expect(model.errorMessage == "E-mail ou mot de passe incorrect.")
        #expect(model.password == "mauvais-mot-de-passe")
    }

    @Test func invalidInputIsCheckedBeforeCallingTheServer() async {
        let harness = VMHarness(.signedOut)
        let model = LoginViewModel(services: harness.services, email: "camille")
        model.password = DemoData.password
        #expect(await !model.signIn())
        #expect(model.errorMessage == AppError.invalidEmail.messageFR)

        model.email = VMFixtures.camille.email
        model.password = ""
        #expect(await !model.signIn())
        #expect(model.errorMessage == "Saisis ton mot de passe.")
        #expect(harness.faults.calls(.signIn) == 0)
    }

    @Test func networkErrorsAreShownButCancellationIsNot() async {
        let harness = VMHarness(.signedOut)
        let model = LoginViewModel(services: harness.services, email: VMFixtures.camille.email)
        model.password = DemoData.password
        harness.faults.fail(.signIn, with: AppError.network)
        #expect(await !model.signIn())
        #expect(model.errorMessage == AppError.network.messageFR)

        harness.faults.fail(.signIn, with: CancellationError())
        #expect(await !model.signIn())
        #expect(model.error == nil)
    }
}

@MainActor
@Suite struct SignUpViewModelTests {
    @Test func validatesEveryFieldAtOnce() async {
        let harness = VMHarness(.signedOut)
        let model = SignUpViewModel(services: harness.services)
        #expect(!model.canSubmit)
        model.email = "pas-un-email"
        model.password = "court"
        model.displayName = "   "
        #expect(!model.canSubmit)
        #expect(await !model.signUp())
        #expect(model.emailError == "Adresse e-mail invalide.")
        #expect(model.passwordError == "Mot de passe trop faible (8 caractères minimum).")
        #expect(model.displayNameError == "Le nom doit contenir entre 1 et 50 caractères.")
        #expect(harness.faults.calls(.signUp) == 0)

        // Messages follow the corrections live once shown.
        model.email = "alex@example.com"
        #expect(model.emailError == nil)
        model.password = String(repeating: "é", count: 40) // 80 bytes
        #expect(model.passwordError == SignUpViewModel.passwordTooLongMessage)
        model.password = "motdepasse-solide"
        #expect(model.passwordError == nil)
        model.displayName = String(repeating: "a", count: 51)
        #expect(model.displayNameError != nil)
        model.displayName = "Alex Moreau"
        #expect(model.displayNameError == nil)
        #expect(model.canSubmit)
    }

    @Test func createsTheAccountAndSignsIn() async throws {
        let harness = VMHarness(.signedOut)
        let model = SignUpViewModel(services: harness.services)
        model.email = " Nouvelle@Example.com "
        model.password = "motdepasse-solide"
        model.displayName = "  Nina Petit "
        #expect(await model.signUp())
        #expect(!model.needsEmailConfirmation)
        #expect(model.password.isEmpty)
        let user = await harness.services.auth.currentUser()
        #expect(user?.email == "nouvelle@example.com")
        #expect(try await harness.services.profiles.myProfile().displayName == "Nina Petit")
    }

    @Test func existingEmailIsShownOnTheEmailField() async {
        let harness = VMHarness(.signedOut)
        let model = SignUpViewModel(services: harness.services)
        model.email = VMFixtures.camille.email
        model.password = "motdepasse-solide"
        model.displayName = "Camille"
        #expect(await !model.signUp())
        #expect(model.emailError == "Un compte existe déjà avec cet e-mail.")
        #expect(model.error == nil)
    }

    @Test func otherServerErrorsUseTheAlert() async {
        let harness = VMHarness(.signedOut)
        let model = SignUpViewModel(services: harness.services)
        model.email = "nina@example.com"
        model.password = "motdepasse-solide"
        model.displayName = "Nina"
        harness.faults.fail(.signUp, with: AppError.emailRateLimited)
        #expect(await !model.signUp())
        #expect(model.errorMessage == AppError.emailRateLimited.messageFR)
        harness.faults.fail(.signUp, with: AppError.weakPassword)
        #expect(await !model.signUp())
        #expect(model.passwordError == AppError.weakPassword.messageFR)
    }

    @Test func confirmationRequiredOutcome() async {
        let harness = VMHarness(.signedOut, signUpOutcome: .confirmationRequired)
        let model = SignUpViewModel(services: harness.services)
        model.email = "nina@example.com"
        model.password = "motdepasse-solide"
        model.displayName = "Nina"
        #expect(await model.signUp())
        #expect(model.needsEmailConfirmation)
        #expect(SignUpViewModel.confirmationRequiredMessage.contains("Confirme ton adresse e-mail"))
    }
}

@MainActor
@Suite struct PasswordResetViewModelTests {
    @Test func codeKeepsSixDigits() {
        #expect(PasswordResetViewModel.sanitizedCode("12 34-56") == "123456")
        #expect(PasswordResetViewModel.sanitizedCode("1234567") == "123456")
        #expect(PasswordResetViewModel.sanitizedCode("abc") == "")
        #expect(PasswordResetViewModel.sanitizedCode("١٢٣") == "") // non-ASCII digits are dropped
        let harness = VMHarness(.signedOut)
        let model = PasswordResetViewModel(services: harness.services)
        model.code = "98 76 54 32"
        #expect(model.code == "987654")
    }

    @Test func fullFlowThroughTheAppModel() async throws {
        let harness = VMHarness(.signedOut)
        let app = harness.makeApp()
        app.start()
        await VMWait.until("signed out") { app.phase == .signedOut }

        let model = app.startPasswordReset(email: " Camille@Example.com ")
        #expect(app.passwordReset === model)
        #expect(model.step == .email)
        #expect(model.title == "Mot de passe oublié")
        #expect(await model.sendCode())
        #expect(model.step == .code)
        #expect(model.email == "camille@example.com")
        #expect(model.infoMessage?.contains("camille@example.com") == true)

        #expect(await model.resendCode())
        #expect(model.infoMessage == PasswordResetViewModel.resentMessage)

        model.code = "12345"
        #expect(!model.canVerifyCode)
        #expect(await !model.verifyCode())
        #expect(model.errorMessage == PasswordResetViewModel.incompleteCodeMessage)

        model.code = InMemoryBackend.recoveryCode
        #expect(await model.verifyCode())
        #expect(model.step == .newPassword)
        #expect(model.title == "Nouveau mot de passe")
        // Signed in with a recovery session, but the app stays closed until the password is set.
        await VMWait.until("recovery phase") { app.phase == .passwordRecovery(model) }
        #expect(app.isInPasswordRecovery)
        #expect(app.session == nil)

        model.newPassword = "court"
        model.passwordConfirmation = "court"
        #expect(await !model.updatePassword())
        #expect(model.errorMessage == AppError.weakPassword.messageFR)

        model.newPassword = "nouveau-secret-2026"
        model.passwordConfirmation = "nouveau-secret-2027"
        #expect(await !model.updatePassword())
        #expect(model.errorMessage == PasswordResetViewModel.mismatchMessage)

        model.passwordConfirmation = "nouveau-secret-2026"
        #expect(await model.updatePassword())
        #expect(model.step == .done)
        await VMWait.until("signed in") { app.session != nil }
        #expect(!app.isInPasswordRecovery)
        #expect(app.passwordReset == nil)
        #expect(app.session?.userId == VMFixtures.camille.id)

        // The new password works.
        try await harness.services.auth.signOut()
        await VMWait.until("signed out again") { app.phase == .signedOut }
        try await harness.services.auth.signIn(email: VMFixtures.camille.email, password: "nouveau-secret-2026")
        await VMWait.until("signed in again") { app.session != nil }
        await app.shutdown()
    }

    @Test func wrongCodeEndsTheRecoveryAttempt() async {
        let harness = VMHarness(.signedOut)
        let app = harness.makeApp()
        app.start()
        await VMWait.until("signed out") { app.phase == .signedOut }
        let model = app.startPasswordReset(email: VMFixtures.camille.email)
        #expect(await model.sendCode())
        model.code = "000000"
        #expect(await !model.verifyCode())
        #expect(model.errorMessage == "Code invalide ou expiré.")
        #expect(model.step == .code)
        #expect(!app.isInPasswordRecovery)
        #expect(app.phase == .signedOut)

        model.goBack()
        #expect(model.step == .email)
        #expect(model.code.isEmpty)
        await app.shutdown()
    }

    @Test func cancellingAtTheNewPasswordStepSignsOut() async {
        let harness = VMHarness(.signedOut)
        let app = harness.makeApp()
        app.start()
        await VMWait.until("signed out") { app.phase == .signedOut }
        let model = app.startPasswordReset(email: VMFixtures.camille.email)
        #expect(await model.sendCode())
        model.code = InMemoryBackend.recoveryCode
        #expect(await model.verifyCode())
        await VMWait.until("recovery phase") { app.phase == .passwordRecovery(model) }

        await model.cancel()
        await VMWait.until("signed out") { app.phase == .signedOut }
        #expect(!app.isInPasswordRecovery)
        #expect(app.passwordReset == nil)
        #expect(await harness.services.auth.currentUser() == nil)
        await app.shutdown()
    }

    /// The recovery session ends without the user (revoked, refresh refused) at the « Nouveau mot de passe » step:
    /// the flow comes back at the e-mail step with an explanation, not on the dead session (review VM-6).
    @Test func recoverySessionEndingByItselfRestartsTheFlow() async throws {
        let harness = VMHarness(.signedOut)
        let app = harness.makeApp()
        app.start()
        await VMWait.until("signed out") { app.phase == .signedOut }
        let model = app.startPasswordReset(email: VMFixtures.camille.email)
        #expect(await model.sendCode())
        model.code = InMemoryBackend.recoveryCode
        #expect(await model.verifyCode())
        await VMWait.until("recovery phase") { app.phase == .passwordRecovery(model) }
        model.newPassword = "nouveau-secret"

        try await harness.services.auth.signOut()
        await VMWait.until("signed out") { app.phase == .signedOut }
        #expect(!app.isInPasswordRecovery)
        #expect(app.passwordReset === model)
        #expect(model.step == .email)
        #expect(model.email == VMFixtures.camille.email)
        #expect(model.newPassword.isEmpty)
        #expect(model.code.isEmpty)
        #expect(model.errorMessage == PasswordResetViewModel.recoveryEndedMessage)

        // Starting over works.
        #expect(await model.sendCode())
        model.code = InMemoryBackend.recoveryCode
        #expect(await model.verifyCode())
        await VMWait.until("recovery phase again") { app.phase == .passwordRecovery(model) }
        model.newPassword = "nouveau-secret-2026"
        model.passwordConfirmation = "nouveau-secret-2026"
        #expect(await model.updatePassword())
        await VMWait.until("signed in") { app.session != nil }
        await app.shutdown()
    }

    @Test func cancellingEarlyOnlyClosesTheSheet() async {
        let harness = VMHarness(.signedOut)
        let app = harness.makeApp()
        let model = app.startPasswordReset()
        await model.cancel()
        #expect(app.passwordReset == nil)
    }

    @Test func invalidEmailStaysOnTheFirstStep() async {
        let harness = VMHarness(.signedOut)
        let model = PasswordResetViewModel(services: harness.services, email: "camille@")
        #expect(await !model.sendCode())
        #expect(model.step == .email)
        #expect(model.errorMessage == AppError.invalidEmail.messageFR)
        #expect(harness.faults.calls(.sendPasswordReset) == 0)

        model.email = VMFixtures.camille.email
        harness.faults.fail(.sendPasswordReset, with: AppError.emailRateLimited)
        #expect(await !model.sendCode())
        #expect(model.errorMessage == AppError.emailRateLimited.messageFR)
        #expect(model.step == .email)
    }
}
