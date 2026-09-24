package io.github.notkanaa.equipe.supabase.integration

import io.github.jan.supabase.auth.status.SessionSource
import io.github.notkanaa.equipe.contract.StreamProbe
import io.github.notkanaa.equipe.core.AppError
import io.github.notkanaa.equipe.core.AuthState
import io.github.notkanaa.equipe.supabase.SupabaseBackend
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test
import kotlin.time.Duration.Companion.minutes

/**
 * Sessions the server refuses and account deletion on two devices, against the local stack (port of
 * SessionIntegrationTests.swift).
 */
class SessionIntegrationTest {
    /**
     * The account is deleted on device A while B (same account) keeps a valid JWT: B's next write is refused, its
     * refresh fails, and B is signed out instead of failing every call until the token expires.
     */
    @Test
    fun accountDeletedElsewhereSignsThisDeviceOutAtItsNextWrite() = IntegrationEnvironment.run(1.minutes) { devices ->
        val a = SupabaseHarness(devices).makeUser("Supprimé ailleurs")
        val b = devices.newServices()
        b.auth.signIn(a.email, a.password)
        val probe = StreamProbe(b.auth.authStates())
        try {
            probe.waitFor("B signed in") { it.user?.id == a.id }
            a.auth.deleteAccount()
            val mark = probe.mark()
            expectError(AppError.NotAuthenticated) { b.groups.createGroup("Encore") }
            probe.waitFor("SignedOut on B", after = mark) { it == AuthState.SignedOut }
            assertNull(b.auth.currentUser())
        } finally {
            probe.stop()
        }
    }

    /**
     * « Réessayer » of a deletion whose answer was lost: `delete_my_account` finds the account gone, which is the
     * requested end state. Success, and the device is signed out.
     */
    @Test
    fun deletingAnAlreadyDeletedAccountSucceeds() = IntegrationEnvironment.run(1.minutes) { devices ->
        val a = SupabaseHarness(devices).makeUser("Suppression répétée")
        val b = devices.newServices()
        b.auth.signIn(a.email, a.password)
        a.auth.deleteAccount() // the first attempt, whose answer B never received
        b.auth.deleteAccount()
        assertNull(b.auth.currentUser())
    }

    /**
     * PostgREST refuses a token the client still considers valid (signing key rotated on the hosted project, device
     * clock behind): the adapter refreshes once and sends the request again.
     */
    @Test
    fun refusedButUnexpiredTokenIsRefreshedOnce() = IntegrationEnvironment.run(1.minutes) { devices ->
        val context = devices.newContext()
        val services = SupabaseBackend.services(context)
        val user = SupabaseHarness.signUp("Jeton refusé", services)
        services.groups.createGroup("Groupe du jeton")

        val session = context.auth.currentSessionOrNull()!!
        val parts = session.accessToken.split('.')
        assertEquals(3, parts.size)
        // Same claims, signature of another key.
        val tampered = parts[0] + "." + parts[1] + "." + parts[2].reversed()
        context.auth.importSession(session.copy(accessToken = tampered), source = SessionSource.Unknown)

        assertEquals(listOf("Groupe du jeton"), services.groups.myGroups().map { it.group.name })
        services.groups.createGroup("Encore un groupe")
        assertEquals(user.id, services.auth.currentUser()?.id)
        services.auth.deleteAccount()
    }
}
