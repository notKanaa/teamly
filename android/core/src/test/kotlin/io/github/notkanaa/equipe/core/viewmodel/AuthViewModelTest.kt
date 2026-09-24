package io.github.notkanaa.equipe.core.viewmodel

import io.github.notkanaa.equipe.core.AppError
import io.github.notkanaa.equipe.core.SignUpOutcome
import io.github.notkanaa.equipe.mocks.DemoData
import io.github.notkanaa.equipe.mocks.InMemoryBackend
import io.github.notkanaa.equipe.mocks.MockScenario
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.UnconfinedTestDispatcher
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test
import kotlin.coroutines.cancellation.CancellationException
import io.github.notkanaa.equipe.core.viewmodel.VMFaults.Op
import io.github.notkanaa.equipe.core.viewmodel.VMFixtures as F

/** Port of the LoginViewModelTests suite of ViewModels/AuthViewModelTests.swift. */
class LoginViewModelTest {
    @Test
    fun signsInWithNormalizedEmail() = runTest {
        val harness = VMHarness(backgroundScope, MockScenario.SIGNED_OUT)
        val model = LoginViewModel(harness.services, email = "  Camille@Example.com ")
        assertFalse(model.ui.canSubmit)
        model.password = DemoData.password
        assertTrue(model.ui.canSubmit)

        assertTrue(model.signIn())
        assertTrue(model.password.isEmpty())
        assertNull(model.error)
        assertFalse(model.ui.isSubmitting)
        assertEquals(F.camille.id, harness.services.auth.currentUser()?.id)
    }

    @Test
    fun wrongPasswordShowsInvalidCredentials() = runTest {
        val harness = VMHarness(backgroundScope, MockScenario.SIGNED_OUT)
        val model = LoginViewModel(harness.services, email = F.camille.email)
        model.password = "mauvais-mot-de-passe"
        assertFalse(model.signIn())
        assertEquals("E-mail ou mot de passe incorrect.", model.errorMessage)
        assertEquals("mauvais-mot-de-passe", model.password)
    }

    @Test
    fun invalidInputIsCheckedBeforeCallingTheServer() = runTest {
        val harness = VMHarness(backgroundScope, MockScenario.SIGNED_OUT)
        val model = LoginViewModel(harness.services, email = "camille")
        model.password = DemoData.password
        assertFalse(model.signIn())
        assertEquals(AppError.InvalidEmail.messageFR, model.errorMessage)

        model.email = F.camille.email
        model.password = ""
        assertFalse(model.signIn())
        assertEquals("Saisissez votre mot de passe.", model.errorMessage)
        assertEquals(0, harness.faults.calls(Op.SIGN_IN))
    }

    @Test
    fun networkErrorsAreShownButCancellationIsNot() = runTest {
        val harness = VMHarness(backgroundScope, MockScenario.SIGNED_OUT)
        val model = LoginViewModel(harness.services, email = F.camille.email)
        model.password = DemoData.password
        harness.faults.fail(Op.SIGN_IN, AppError.Network)
        assertFalse(model.signIn())
        assertEquals(AppError.Network.messageFR, model.errorMessage)

        // Kotlin: the cancellation is rethrown (never shown) and the form is usable again.
        harness.faults.fail(Op.SIGN_IN, CancellationException())
        assertCancels { model.signIn() }
        assertNull(model.error)
        assertFalse(model.ui.isSubmitting)
    }
}

/** Port of the SignUpViewModelTests suite of ViewModels/AuthViewModelTests.swift. */
class SignUpViewModelTest {
    @Test
    fun validatesEveryFieldAtOnce() = runTest {
        val harness = VMHarness(backgroundScope, MockScenario.SIGNED_OUT)
        val model = SignUpViewModel(harness.services)
        assertFalse(model.ui.canSubmit)
        model.email = "pas-un-email"
        model.password = "court"
        model.displayName = "   "
        assertFalse(model.ui.canSubmit)
        assertFalse(model.signUp())
        assertEquals("Adresse e-mail invalide.", model.ui.emailError)
        assertEquals("Mot de passe trop faible (8 caractères minimum).", model.ui.passwordError)
        assertEquals("Le nom doit contenir entre 1 et 50 caractères.", model.ui.displayNameError)
        assertEquals(0, harness.faults.calls(Op.SIGN_UP))

        // Messages follow the corrections live once shown.
        model.email = "alex@example.com"
        assertNull(model.ui.emailError)
        model.password = "é".repeat(40) // 80 bytes
        assertEquals(SignUpViewModel.PASSWORD_TOO_LONG_MESSAGE, model.ui.passwordError)
        model.password = "motdepasse-solide"
        assertNull(model.ui.passwordError)
        model.displayName = "a".repeat(51)
        assertTrue(model.ui.displayNameError != null)
        model.displayName = "Alex Moreau"
        assertNull(model.ui.displayNameError)
        assertTrue(model.ui.canSubmit)
    }

    @Test
    fun createsTheAccountAndSignsIn() = runTest {
        val harness = VMHarness(backgroundScope, MockScenario.SIGNED_OUT)
        val model = SignUpViewModel(harness.services)
        model.email = " Nouvelle@Example.com "
        model.password = "motdepasse-solide"
        model.displayName = "  Nina Petit "
        assertTrue(model.signUp())
        assertFalse(model.ui.needsEmailConfirmation)
        assertTrue(model.password.isEmpty())
        val user = harness.services.auth.currentUser()
        assertEquals("nouvelle@example.com", user?.email)
        assertEquals("Nina Petit", harness.services.profiles.myProfile().displayName)
    }

    @Test
    fun existingEmailIsShownOnTheEmailField() = runTest {
        val harness = VMHarness(backgroundScope, MockScenario.SIGNED_OUT)
        val model = SignUpViewModel(harness.services)
        model.email = F.camille.email
        model.password = "motdepasse-solide"
        model.displayName = "Camille"
        assertFalse(model.signUp())
        assertEquals("Un compte existe déjà avec cet e-mail.", model.ui.emailError)
        assertNull(model.error)
    }

    @Test
    fun otherServerErrorsUseTheAlert() = runTest {
        val harness = VMHarness(backgroundScope, MockScenario.SIGNED_OUT)
        val model = SignUpViewModel(harness.services)
        model.email = "nina@example.com"
        model.password = "motdepasse-solide"
        model.displayName = "Nina"
        harness.faults.fail(Op.SIGN_UP, AppError.EmailRateLimited)
        assertFalse(model.signUp())
        assertEquals(AppError.EmailRateLimited.messageFR, model.errorMessage)
        harness.faults.fail(Op.SIGN_UP, AppError.WeakPassword)
        assertFalse(model.signUp())
        assertEquals(AppError.WeakPassword.messageFR, model.ui.passwordError)
    }

    @Test
    fun confirmationRequiredOutcome() = runTest {
        val harness = VMHarness(
            backgroundScope,
            MockScenario.SIGNED_OUT,
            signUpOutcome = SignUpOutcome.CONFIRMATION_REQUIRED,
        )
        val model = SignUpViewModel(harness.services)
        model.email = "nina@example.com"
        model.password = "motdepasse-solide"
        model.displayName = "Nina"
        assertTrue(model.signUp())
        assertTrue(model.ui.needsEmailConfirmation)
        assertTrue(SignUpViewModel.CONFIRMATION_REQUIRED_MESSAGE.contains("Confirmez"))
    }
}

/** Port of the PasswordResetViewModelTests suite of ViewModels/AuthViewModelTests.swift. */
@OptIn(ExperimentalCoroutinesApi::class)
class PasswordResetViewModelTest {
    @Test
    fun codeKeepsSixDigits() = runTest {
        assertEquals("123456", PasswordResetViewModel.sanitizedCode("12 34-56"))
        assertEquals("123456", PasswordResetViewModel.sanitizedCode("1234567"))
        assertEquals("", PasswordResetViewModel.sanitizedCode("abc"))
        assertEquals("", PasswordResetViewModel.sanitizedCode("١٢٣")) // non-ASCII digits are dropped
        val harness = VMHarness(backgroundScope, MockScenario.SIGNED_OUT)
        val model = PasswordResetViewModel(harness.services)
        model.code = "98 76 54 32"
        assertEquals("987654", model.code)
    }

    @Test
    fun fullFlowThroughTheAppModel() = runTest {
        val harness = VMHarness(backgroundScope, MockScenario.SIGNED_OUT)
        val app = harness.makeApp()
        app.start()
        waitUntil("signed out") { app.phase == AppPhase.SignedOut }

        val model = app.startPasswordReset(email = " Camille@Example.com ")
        assertSame(model, app.passwordReset)
        assertEquals(PasswordResetStep.EMAIL, model.ui.step)
        assertEquals("Mot de passe oublié", model.ui.title)
        assertTrue(model.sendCode())
        assertEquals(PasswordResetStep.CODE, model.ui.step)
        assertEquals("camille@example.com", model.email)
        assertTrue(model.ui.infoMessage!!.contains("camille@example.com"))

        assertTrue(model.resendCode())
        assertEquals(PasswordResetViewModel.RESENT_MESSAGE, model.ui.infoMessage)

        model.code = "12345"
        assertFalse(model.ui.canVerifyCode)
        assertFalse(model.verifyCode())
        assertEquals(PasswordResetViewModel.INCOMPLETE_CODE_MESSAGE, model.errorMessage)

        model.code = InMemoryBackend.recoveryCode
        assertTrue(model.verifyCode())
        assertEquals(PasswordResetStep.NEW_PASSWORD, model.ui.step)
        assertEquals("Nouveau mot de passe", model.ui.title)
        // Signed in with a recovery session, but the app stays closed until the password is set.
        waitUntil("recovery phase") { app.phase == AppPhase.PasswordRecovery(model) }
        assertTrue(app.isInPasswordRecovery)
        assertNull(app.session)

        model.newPassword = "court"
        model.passwordConfirmation = "court"
        assertFalse(model.updatePassword())
        assertEquals(AppError.WeakPassword.messageFR, model.errorMessage)

        model.newPassword = "nouveau-secret-2026"
        model.passwordConfirmation = "nouveau-secret-2027"
        assertFalse(model.updatePassword())
        assertEquals(PasswordResetViewModel.MISMATCH_MESSAGE, model.errorMessage)

        model.passwordConfirmation = "nouveau-secret-2026"
        assertTrue(model.updatePassword())
        assertEquals(PasswordResetStep.DONE, model.ui.step)
        waitUntil("signed in") { app.session != null }
        assertFalse(app.isInPasswordRecovery)
        assertNull(app.passwordReset)
        assertEquals(F.camille.id, app.session?.userId)

        // The new password works.
        harness.services.auth.signOut()
        waitUntil("signed out again") { app.phase == AppPhase.SignedOut }
        harness.services.auth.signIn(F.camille.email, "nouveau-secret-2026")
        waitUntil("signed in again") { app.session != null }
        app.shutdown()
    }

    @Test
    fun wrongCodeEndsTheRecoveryAttempt() = runTest {
        val harness = VMHarness(backgroundScope, MockScenario.SIGNED_OUT)
        val app = harness.makeApp()
        app.start()
        waitUntil("signed out") { app.phase == AppPhase.SignedOut }
        val model = app.startPasswordReset(email = F.camille.email)
        assertTrue(model.sendCode())
        model.code = "000000"
        assertFalse(model.verifyCode())
        assertEquals("Code invalide ou expiré.", model.errorMessage)
        assertEquals(PasswordResetStep.CODE, model.ui.step)
        assertFalse(app.isInPasswordRecovery)
        settle()
        assertEquals(AppPhase.SignedOut, app.phase)

        model.goBack()
        assertEquals(PasswordResetStep.EMAIL, model.ui.step)
        assertTrue(model.code.isEmpty())
        app.shutdown()
    }

    @Test
    fun cancellingAtTheNewPasswordStepSignsOut() = runTest {
        val harness = VMHarness(backgroundScope, MockScenario.SIGNED_OUT)
        val app = harness.makeApp()
        app.start()
        waitUntil("signed out") { app.phase == AppPhase.SignedOut }
        val model = app.startPasswordReset(email = F.camille.email)
        assertTrue(model.sendCode())
        model.code = InMemoryBackend.recoveryCode
        assertTrue(model.verifyCode())
        waitUntil("recovery phase") { app.phase == AppPhase.PasswordRecovery(model) }
        // Every phase the app goes through from now on.
        val phases = ArrayList<AppPhase>()
        val recorder = backgroundScope.launch(UnconfinedTestDispatcher(testScheduler)) {
            app.state.collect { phases.add(it.phase) }
        }

        model.cancel()
        waitUntil("signed out") { app.phase == AppPhase.SignedOut }
        assertFalse(app.isInPasswordRecovery)
        assertNull(app.passwordReset)
        assertNull(harness.services.auth.currentUser())
        // Kotlin: the app never opens, even for a moment, on the abandoned recovery session (the sign-out may still be
        // on its way through authStates() when the recovery ends: the stale signed-in state must not be re-applied).
        settle()
        assertEquals(AppPhase.SignedOut, app.phase)
        assertTrue(phases.toString(), phases.none { it is AppPhase.SignedIn })
        recorder.cancel()
        app.shutdown()
    }

    /**
     * The recovery session ends without the user (revoked, refresh refused) at the « Nouveau mot de passe » step: the
     * flow comes back at the e-mail step with an explanation, not on the dead session (review VM-6).
     */
    @Test
    fun recoverySessionEndingByItselfRestartsTheFlow() = runTest {
        val harness = VMHarness(backgroundScope, MockScenario.SIGNED_OUT)
        val app = harness.makeApp()
        app.start()
        waitUntil("signed out") { app.phase == AppPhase.SignedOut }
        val model = app.startPasswordReset(email = F.camille.email)
        assertTrue(model.sendCode())
        model.code = InMemoryBackend.recoveryCode
        assertTrue(model.verifyCode())
        waitUntil("recovery phase") { app.phase == AppPhase.PasswordRecovery(model) }
        model.newPassword = "nouveau-secret"

        harness.services.auth.signOut()
        waitUntil("signed out") { app.phase == AppPhase.SignedOut }
        assertFalse(app.isInPasswordRecovery)
        assertSame(model, app.passwordReset)
        assertEquals(PasswordResetStep.EMAIL, model.ui.step)
        assertEquals(F.camille.email, model.email)
        assertTrue(model.newPassword.isEmpty())
        assertTrue(model.code.isEmpty())
        assertEquals(PasswordResetViewModel.RECOVERY_ENDED_MESSAGE, model.errorMessage)

        // Starting over works.
        assertTrue(model.sendCode())
        model.code = InMemoryBackend.recoveryCode
        assertTrue(model.verifyCode())
        waitUntil("recovery phase again") { app.phase == AppPhase.PasswordRecovery(model) }
        model.newPassword = "nouveau-secret-2026"
        model.passwordConfirmation = "nouveau-secret-2026"
        assertTrue(model.updatePassword())
        waitUntil("signed in") { app.session != null }
        app.shutdown()
    }

    @Test
    fun cancellingEarlyOnlyClosesTheSheet() = runTest {
        val harness = VMHarness(backgroundScope, MockScenario.SIGNED_OUT)
        val app = harness.makeApp()
        val model = app.startPasswordReset()
        model.cancel()
        assertNull(app.passwordReset)
    }

    @Test
    fun invalidEmailStaysOnTheFirstStep() = runTest {
        val harness = VMHarness(backgroundScope, MockScenario.SIGNED_OUT)
        val model = PasswordResetViewModel(harness.services, email = "camille@")
        assertFalse(model.sendCode())
        assertEquals(PasswordResetStep.EMAIL, model.ui.step)
        assertEquals(AppError.InvalidEmail.messageFR, model.errorMessage)
        assertEquals(0, harness.faults.calls(Op.SEND_PASSWORD_RESET))

        model.email = F.camille.email
        harness.faults.fail(Op.SEND_PASSWORD_RESET, AppError.EmailRateLimited)
        assertFalse(model.sendCode())
        assertEquals(AppError.EmailRateLimited.messageFR, model.errorMessage)
        assertEquals(PasswordResetStep.EMAIL, model.ui.step)
    }

    // region Kotlin additions

    @Test
    fun everyFlowIsDistinct() = runTest {
        val harness = VMHarness(backgroundScope, MockScenario.SIGNED_OUT)
        val app = harness.makeApp()
        val first = app.startPasswordReset()
        val second = app.startPasswordReset()
        assertNotEquals(first.id, second.id)
        assertSame(second, app.passwordReset)
        first.cancel() // not the presented one: nothing to close
        assertSame(second, app.passwordReset)
    }

    // endregion
}
