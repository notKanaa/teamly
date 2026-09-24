package io.github.notkanaa.equipe.mocks

import app.cash.turbine.turbineScope
import io.github.notkanaa.equipe.core.AppError
import io.github.notkanaa.equipe.core.AuthState
import io.github.notkanaa.equipe.core.AuthUser
import io.github.notkanaa.equipe.core.SignUpOutcome
import io.github.notkanaa.equipe.core.UserProfile
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import kotlin.time.Duration.Companion.seconds

/** Port of MockAuthTests.swift. */
class MockAuthTest {
    /**
     * Supabase Auth (GoTrue) accepts the HTML5 e-mail syntax: ASCII only, domain labels starting and ending with a
     * letter or digit (probes: `xxxxx@-example.com`, `xxxxx@example..com`, `üxxxxx@example.com` → invalid format).
     */
    @Test
    fun signUpRejectsMalformedEmails() = runTest {
        val emails = listOf(
            "", "   ", "camille", "camille@", "@example.com", "cam ille@example.com", "camille@.fr", "a@b@c.fr",
            "üxxxxx@example.com", "xxxxx@-example.com", "xxxxx@example-.com", "xxxxx@example..com", "xxxxx@example.com.",
            "camille@exämple.com",
        )
        for (email in emails) {
            val services = InMemoryBackend().services(null)
            assertThrowsAppError(AppError.InvalidEmail, "e-mail \"$email\"") {
                services.auth.signUp(email, "motdepasse123", "Nom")
            }
        }
    }

    /** Accepted by GoTrue (probes), so accepted by the mock too. */
    @Test
    fun signUpAcceptsWhatSupabaseAuthAccepts() = runTest {
        val emails = listOf(
            "user@localhost", ".xxxxx@example.com", "a..xxxxx@example.com", "camille@example",
            "o'neil+tag@sub-domain.example.fr",
        )
        for (email in emails) {
            val services = InMemoryBackend().services(null)
            assertEquals(email, SignUpOutcome.SIGNED_IN, services.auth.signUp(email, "motdepasse123", "Nom"))
            assertEquals(email.lowercase(), services.auth.currentUser()?.email)
        }
    }

    /** GoTrue measures passwords in UTF-8 bytes: at least 8 (`minimum_password_length`), at most 72 (bcrypt). */
    @Test
    fun passwordLengthIsCountedInBytes() = runTest {
        val backend = InMemoryBackend()
        val services = backend.services(null)
        assertEquals(SignUpOutcome.SIGNED_IN, services.auth.signUp("octets@example.com", "éééé", "Octets"))
        assertEquals(SignUpOutcome.SIGNED_IN, backend.services(null).auth.signUp("emoji@example.com", "😀😀", "Emoji"))
        assertThrowsAppError(AppError.WeakPassword) {
            backend.services(null).auth.signUp("court@example.com", "ééé1", "Court")
        }
        val longest = "a".repeat(72)
        assertEquals(SignUpOutcome.SIGNED_IN, backend.services(null).auth.signUp("long@example.com", longest, "Long"))
        assertThrowsAppError(AppError.InvalidInput) {
            backend.services(null).auth.signUp("trop@example.com", longest + "a", "Trop")
        }
        assertThrowsAppError(AppError.InvalidInput) { services.auth.updatePassword("é".repeat(37)) }
        services.auth.updatePassword("é".repeat(36))
    }

    @Test
    fun signUpValidation() = runTest {
        val backend = InMemoryBackend.demo()
        val services = backend.services(null)
        assertThrowsAppError(AppError.WeakPassword) {
            services.auth.signUp("nouveau@example.com", "1234567", "Nom")
        }
        assertThrowsAppError(AppError.InvalidDisplayName) {
            services.auth.signUp("nouveau@example.com", "motdepasse123", " \n ")
        }
        assertThrowsAppError(AppError.InvalidDisplayName) {
            services.auth.signUp("nouveau@example.com", "motdepasse123", "é".repeat(51))
        }
        // E-mails are case-insensitive and trimmed.
        assertThrowsAppError(AppError.EmailAlreadyUsed) {
            services.auth.signUp("  CAMILLE@Example.com ", "motdepasse123", "Nom")
        }
        assertNull(services.auth.currentUser())
        assertNull(backend.userId(forEmail = "nouveau@example.com"))
    }

    @Test
    fun signUpNormalizesAndOpensTheSession() = runTest {
        val services = InMemoryBackend().services(null)
        val outcome = services.auth.signUp("  Zoe.Leroy@Example.COM ", "motdepasse123", "  Zoé Leroy  ")
        assertEquals(SignUpOutcome.SIGNED_IN, outcome)
        val user = services.auth.currentUser()!!
        assertEquals("zoe.leroy@example.com", user.email)
        assertEquals(UserProfile(user.id, "Zoé Leroy"), services.profiles.myProfile())
        val fiftyAccents = "é".repeat(50)
        assertEquals(fiftyAccents, services.profiles.updateDisplayName(fiftyAccents).displayName)
    }

    @Test
    fun signInAndSignOut() = runTest {
        val services = InMemoryBackend.demo().services(null)
        assertThrowsAppError(AppError.InvalidCredentials) {
            services.auth.signIn(DemoData.camille.email, "mauvais-mot-de-passe")
        }
        assertThrowsAppError(AppError.InvalidCredentials) {
            services.auth.signIn("personne@example.com", DemoData.password)
        }
        services.auth.signIn(" Camille@Example.com ", DemoData.password)
        assertEquals(DemoData.camille.id, services.auth.currentUser()?.id)
        services.auth.signOut()
        assertNull(services.auth.currentUser())
        services.auth.signOut() // idempotent
        assertThrowsAppError(AppError.NotAuthenticated) { services.profiles.myProfile() }
        assertThrowsAppError(AppError.NotAuthenticated) { services.groups.createGroup("Groupe") }
        assertThrowsAppError(AppError.NotAuthenticated) { services.push.enable() }
        assertThrowsAppError(AppError.NotAuthenticated) { services.auth.updatePassword("nouveau-mdp") }
        assertThrowsAppError(AppError.NotAuthenticated) { services.auth.deleteAccount() }
    }

    @Test
    fun authStatesEmitsTheCurrentStateThenChanges() = runTest {
        val services = InMemoryBackend.demo().services(null)
        turbineScope {
            val first = services.auth.authStates().testIn(backgroundScope)
            assertEquals(AuthState.SignedOut, first.awaitItem())
            services.auth.signIn(DemoData.lucas.email, DemoData.password)
            val lucas = AuthUser(DemoData.lucas.id, DemoData.lucas.email)
            assertEquals(AuthState.SignedIn(lucas), first.awaitItem())

            // A late subscriber starts with the current state.
            val second = services.auth.authStates().testIn(backgroundScope)
            assertEquals(AuthState.SignedIn(lucas), second.awaitItem())

            services.auth.signOut()
            assertEquals(AuthState.SignedOut, first.awaitItem())
            assertEquals(AuthState.SignedOut, second.awaitItem())
            // Signing in again as the same user after sign-out is a change; a repeated sign-out is not.
            services.auth.signOut()
            services.auth.signIn(DemoData.lucas.email, DemoData.password)
            assertEquals(AuthState.SignedIn(lucas), first.awaitItem())
            first.cancelAndIgnoreRemainingEvents()
            second.cancelAndIgnoreRemainingEvents()
        }
    }

    @Test
    fun passwordRecoveryWithTheDeterministicCode() = runTest {
        val clock = MockClock(TestDates.start)
        val backend = InMemoryBackend.demo(now = clock.provider)
        val services = backend.services(null)
        val email = DemoData.ines.email

        assertThrowsAppError(AppError.InvalidEmail) { services.auth.sendPasswordReset("pas-un-email") }
        services.auth.sendPasswordReset("inconnu@example.com") // no account enumeration
        assertNull(backend.pendingRecoveryCode("inconnu@example.com"))
        assertThrowsAppError(AppError.OtpInvalid) {
            services.auth.verifyRecoveryCode(email, InMemoryBackend.recoveryCode)
        }

        services.auth.sendPasswordReset(email)
        assertEquals("123456", backend.pendingRecoveryCode(email))
        assertEquals("123456", InMemoryBackend.recoveryCode)
        assertThrowsAppError(AppError.OtpInvalid) { services.auth.verifyRecoveryCode(email, "654321") }
        assertNull(services.auth.currentUser())

        services.auth.verifyRecoveryCode(email, " 123456 ")
        assertEquals(DemoData.ines.id, services.auth.currentUser()?.id)
        assertNull(backend.pendingRecoveryCode(email)) // consumed
        assertThrowsAppError(AppError.WeakPassword) { services.auth.updatePassword("court") }
        services.auth.updatePassword("nouveau-mot-de-passe")
        services.auth.signOut()

        assertThrowsAppError(AppError.InvalidCredentials) { services.auth.signIn(email, DemoData.password) }
        services.auth.signIn(email, "nouveau-mot-de-passe")
        assertEquals(DemoData.ines.id, services.auth.currentUser()?.id)
    }

    @Test
    fun recoveryCodesExpireAfterAnHour() = runTest {
        val clock = MockClock(TestDates.start)
        val backend = InMemoryBackend.demo(now = clock.provider)
        val services = backend.services(null)
        services.auth.sendPasswordReset(DemoData.lucas.email)
        clock.advance(InMemoryBackend.recoveryCodeLifetime + 1.seconds)
        assertThrowsAppError(AppError.OtpInvalid) {
            services.auth.verifyRecoveryCode(DemoData.lucas.email, InMemoryBackend.recoveryCode)
        }
        services.auth.sendPasswordReset(DemoData.lucas.email)
        clock.advance(InMemoryBackend.recoveryCodeLifetime)
        services.auth.verifyRecoveryCode(DemoData.lucas.email, InMemoryBackend.recoveryCode)
        assertEquals(DemoData.lucas.id, services.auth.currentUser()?.id)
    }

    /**
     * `delete_my_account` on a device whose account is already gone (the answer of an earlier attempt was lost, or the
     * account was deleted on another device): the requested end state holds, the device is signed out.
     */
    @Test
    fun deletingAnAlreadyDeletedAccountSucceedsAndSignsOut() = runTest {
        val backend = InMemoryBackend.demo()
        val phone = backend.services(DemoData.ines.id)
        val tablet = backend.services(DemoData.ines.id)
        turbineScope {
            val states = tablet.auth.authStates().testIn(backgroundScope)
            assertEquals(DemoData.ines.id, states.awaitItem().user?.id)

            phone.auth.deleteAccount()
            tablet.auth.deleteAccount()
            assertEquals(AuthState.SignedOut, states.awaitItem())
            assertNull(tablet.auth.currentUser())
            // Signed out now: a further call is refused.
            assertThrowsAppError(AppError.NotAuthenticated) { tablet.auth.deleteAccount() }
            states.cancelAndIgnoreRemainingEvents()
        }
    }

    /**
     * A write with the session of a deleted account ends that session (like the Supabase adapter, whose refresh then
     * fails): `SignedOut`, then `NotAuthenticated`. Reads only fail.
     */
    @Test
    fun writeWithTheSessionOfADeletedAccountSignsOut() = runTest {
        val backend = InMemoryBackend.demo()
        val phone = backend.services(DemoData.ines.id)
        val tablet = backend.services(DemoData.ines.id)
        turbineScope {
            val states = tablet.auth.authStates().testIn(backgroundScope)
            assertEquals(DemoData.ines.id, states.awaitItem().user?.id)

            phone.auth.deleteAccount()
            assertThrowsAppError(AppError.NotAuthenticated) { tablet.groups.myGroups() }
            states.expectNoEvents() // a read does not end the session
            assertThrowsAppError(AppError.NotAuthenticated) { tablet.groups.createGroup("Encore") }
            assertEquals(AuthState.SignedOut, states.awaitItem())
            assertThrowsAppError(AppError.NotAuthenticated) { tablet.groups.createGroup("Encore") }
            states.cancelAndIgnoreRemainingEvents()
        }
    }

    @Test
    fun deleteAccountSignsOutEveryWhere() = runTest {
        val backend = InMemoryBackend.demo()
        val phone = backend.services(DemoData.ines.id)
        val tablet = backend.services(DemoData.ines.id)
        turbineScope {
            val states = phone.auth.authStates().testIn(backgroundScope)
            assertEquals(DemoData.ines.id, states.awaitItem().user?.id)

            phone.auth.deleteAccount()
            assertEquals(AuthState.SignedOut, states.awaitItem())
            assertNull(phone.auth.currentUser())
            assertNull(tablet.auth.currentUser())
            assertThrowsAppError(AppError.NotAuthenticated) { tablet.groups.myGroups() }
            assertNull(backend.userId(forEmail = DemoData.ines.email))

            // The e-mail can be registered again.
            val outcome = phone.auth.signUp(DemoData.ines.email, DemoData.password, "Inès")
            assertEquals(SignUpOutcome.SIGNED_IN, outcome)
            assertTrue(phone.groups.myGroups().isEmpty())
            states.cancelAndIgnoreRemainingEvents()
        }
    }
}
