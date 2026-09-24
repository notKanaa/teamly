package io.github.notkanaa.equipe.supabase.integration

import io.github.notkanaa.equipe.core.AppError
import io.github.notkanaa.equipe.core.AuthUser
import io.github.notkanaa.equipe.core.MemberRole
import io.github.notkanaa.equipe.core.UserProfile
import io.github.notkanaa.equipe.mocks.DemoData
import io.github.notkanaa.equipe.supabase.SupabaseBackend
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assume
import org.junit.Test
import kotlin.time.Duration.Companion.minutes

/**
 * Backend-specific Auth checks against the local stack (port of AuthIntegrationTests.swift): password recovery by
 * e-mail code (read from Mailpit) and the seed accounts of docs/CONTRACTS.md §8.
 */
class AuthIntegrationTest {
    @Test
    fun passwordRecoveryWithTheEmailedCode() {
        IntegrationEnvironment.assumeConfigured()
        Assume.assumeTrue("MAILPIT_URL is not set", IntegrationEnvironment.mailpitUrl != null)
        IntegrationEnvironment.run(2.minutes) { devices ->
            val user = SupabaseHarness(devices).makeUser("Récupération")
            user.auth.signOut()
            val device = devices.newServices()

            expectError(AppError.InvalidEmail) { device.auth.sendPasswordReset("pas-une-adresse") }
            // No account enumeration: an unknown e-mail succeeds silently.
            device.auth.sendPasswordReset(IntegrationEnvironment.uniqueEmail("inconnu"))

            // The e-mail is normalized (trimmed, lower-cased) before reaching Auth.
            device.auth.sendPasswordReset("  ${user.email.uppercase()}  ")
            val code = Mailpit.recoveryCode(user.email)
            assertEquals(6, code.length)

            val wrong = if (code == "000000") "111111" else "000000"
            expectError(AppError.OtpInvalid) { device.auth.verifyRecoveryCode(user.email, wrong) }
            assertNull(device.auth.currentUser())

            device.auth.verifyRecoveryCode(" ${user.email.uppercase()} ", " $code ")
            assertEquals("a valid code opens a recovery session", user.id, device.auth.currentUser()?.id)

            expectError(AppError.WeakPassword) { device.auth.updatePassword("court") }
            val newPassword = "nouveau-motdepasse-2026"
            device.auth.updatePassword(newPassword)
            // `422 same_password` is a success: the requested end state holds.
            device.auth.updatePassword(newPassword)

            device.auth.signOut()
            expectError(AppError.NotAuthenticated) { device.auth.updatePassword(newPassword) }
            expectError(AppError.InvalidCredentials) { device.auth.signIn(user.email, user.password) }
            device.auth.signIn(user.email, newPassword)
            assertEquals(user.id, device.auth.currentUser()?.id)
            assertEquals("Récupération", device.profiles.myProfile().displayName)

            // A code works once.
            device.auth.signOut()
            expectError(AppError.OtpInvalid) { device.auth.verifyRecoveryCode(user.email, code) }

            // Clean up.
            device.auth.signIn(user.email, newPassword)
            device.auth.deleteAccount()
            assertNull(device.auth.currentUser())
        }
    }

    /**
     * The accounts of `supabase/seed.sql` sign in with the demo password (read-only checks: other tests may have added
     * data, never removed any). The first device goes through the public entry point.
     */
    @Test
    fun seedUsersCanSignIn() = IntegrationEnvironment.run(1.minutes) { devices ->
        for ((index, demo) in DemoData.users.withIndex()) {
            val device = if (index == 0) {
                SupabaseBackend.makeServices(IntegrationEnvironment.requireConfiguration())
            } else {
                devices.newServices()
            }
            device.auth.signIn(" ${demo.email.uppercase()} ", DemoData.password)
            assertEquals(AuthUser(demo.id, demo.email), device.auth.currentUser())
            assertEquals(UserProfile(demo.id, demo.displayName), device.profiles.myProfile())
            expectError(AppError.InvalidCredentials) { devices.newServices().auth.signIn(demo.email, "mauvais-mot-de-passe") }
            device.auth.signOut()
            assertNull(device.auth.currentUser())
        }

        val camille = devices.newServices()
        camille.auth.signIn(DemoData.camille.email, DemoData.password)
        val groups = camille.groups.myGroups()
        val lilas = groups.first { it.id == DemoData.lilasGroupId }
        assertEquals(DemoData.lilasGroupName, lilas.group.name)
        assertEquals(MemberRole.ADMIN, lilas.myRole)
        val sport = groups.first { it.id == DemoData.sportGroupId }
        assertEquals(DemoData.sportGroupName, sport.group.name)
        assertEquals(MemberRole.MEMBER, sport.myRole)

        val tasks = camille.tasks.tasks(DemoData.lilasGroupId, includeOldDone = true)
        val seeded = setOf(
            DemoData.TaskIds.sortirPoubelles, DemoData.TaskIds.faireCourses, DemoData.TaskIds.payerLoyer,
            DemoData.TaskIds.reparerFuite, DemoData.TaskIds.nettoyerCuisine,
        )
        assertTrue(tasks.map { it.id }.toSet().containsAll(seeded))
        val members = camille.groups.members(DemoData.lilasGroupId)
        assertEquals("the admin comes first", DemoData.camille.id, members.first().user.id)
        camille.auth.signOut()
    }
}
