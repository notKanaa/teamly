package io.github.notkanaa.equipe.supabase

import io.github.jan.supabase.auth.exception.NoSessionFoundException
import io.github.notkanaa.equipe.core.AppError
import io.github.notkanaa.equipe.core.AuthState
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import java.util.Base64

/** Public entry points: configuration, secret-key detection, session storage. */
class SupabaseBackendTest {
    private fun jwtKey(payload: String): String {
        fun encode(json: String) = Base64.getUrlEncoder().withoutPadding().encodeToString(json.toByteArray())
        return encode("""{"alg":"HS256","typ":"JWT"}""") + "." + encode(payload) + ".signature"
    }

    @Test
    fun configurationStoresValues() {
        val configuration = SupabaseConfiguration("http://127.0.0.1:54321", "sb_publishable_test")
        assertEquals("http://127.0.0.1:54321", configuration.url)
        assertEquals("sb_publishable_test", configuration.publishableKey)
        assertEquals(configuration, SupabaseConfiguration("http://127.0.0.1:54321", "sb_publishable_test"))
    }

    @Test
    fun secretKeysAreDetected() {
        // A synthetic secret key, built at run time so that no secret-looking literal is committed.
        assertTrue(SupabaseBackend.isSecretKey("sb_" + "secret_" + "x".repeat(31)))
        assertFalse(SupabaseBackend.isSecretKey("sb_publishable_ACJWlzQHlZjBrEguHvfOxg_3BJgxAaH"))
        // The local stack's legacy keys.
        assertFalse(
            SupabaseBackend.isSecretKey(
                "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZS1kZW1vIiwicm9sZSI6ImFub24iLCJleHAiOjE5ODM4MTI5OTZ9." +
                    "CRXP1A7WOeoJeXxjNni43kdQwgnWNReilDMblYTn_I0",
            ),
        )
        // Shaped like the local stack's legacy service_role key (the real value is not committed: push protection).
        assertTrue(SupabaseBackend.isSecretKey(jwtKey("""{"iss":"supabase-demo","role":"service_role","exp":1983812996}""")))
        assertFalse(SupabaseBackend.isSecretKey(jwtKey("""{"role":"anon"}""")))
        assertTrue(SupabaseBackend.isSecretKey(jwtKey("""{"role":"service_role"}""")))
        assertTrue("a JWT without role is not the anon key", SupabaseBackend.isSecretKey(jwtKey("""{"iss":"supabase"}""")))
        assertTrue(SupabaseBackend.isSecretKey(jwtKey("""{"role":42}""")))
        // Not a JWT at all: not a secret key (the server will refuse it).
        assertFalse(SupabaseBackend.isSecretKey("n'importe quoi"))
        assertFalse(SupabaseBackend.isSecretKey("a.b.c"))
        assertFalse(SupabaseBackend.isSecretKey(""))
    }

    @Test
    fun projectUrlMustBeAnHttpUrlWithAHost() {
        assertEquals("https://abcdefgh.supabase.co", SupabaseBackend.projectUrl("https://abcdefgh.supabase.co/"))
        assertEquals("http://127.0.0.1:54321", SupabaseBackend.projectUrl(" http://127.0.0.1:54321 "))
        for (invalid in listOf("", "abcdefgh.supabase.co", "ftp://abcdefgh.supabase.co", "https://", "https://abcdefgh.supabase.co/rest/v1", "https://x.supabase.co?a=b")) {
            try {
                SupabaseBackend.projectUrl(invalid)
                fail("accepted $invalid")
            } catch (error: IllegalArgumentException) {
                // expected
            }
        }
    }

    /** The public entry point builds signed-out services with the default storage, without touching the network. */
    @Test
    fun makeServicesStartsSignedOut() = runBlocking {
        val services = SupabaseBackend.makeServices(SupabaseConfiguration("http://127.0.0.1:9", "sb_publishable_test"))
        assertEquals(AuthState.SignedOut, services.auth.authStates().first { it != AuthState.Unknown })
        assertNull(services.auth.currentUser())
        assertThrows(AppError.NotAuthenticated) { services.groups.myGroups() }
    }

    /** `InMemory` persists nothing: clients never share a session. */
    @Test
    fun inMemoryStorageKeepsNothing() {
        SessionStorage.InMemory.save("session")
        assertNull(SessionStorage.InMemory.load())
        SessionStorage.InMemory.clear()
    }

    @Test
    fun sessionManagerRoundTrip() = runBlocking {
        val storage = RecordingSessionStorage()
        val manager = StorageSessionManager(storage)
        try {
            manager.loadSession()
            fail("no session expected")
        } catch (error: NoSessionFoundException) {
            // expected
        }
        val session = StorageSessionManager.decode(AuthFixtures.storedSession(AuthFixtures.jwt(Seed.camille)))!!
        manager.saveSession(session)
        assertEquals(session, manager.latest)
        assertEquals(session, StorageSessionManager(storage).loadSession())
        assertTrue(storage.value!!.contains("expiresAt"))
        manager.deleteSession()
        assertNull(storage.value)
        assertNull(manager.latest)
    }

    /** A storage that fails never fails the Auth call that saves the session. */
    @Test
    fun storageFailuresAreNotFatal() = runBlocking {
        val failing = object : SessionStorage {
            override fun load(): String = throw IllegalStateException("stockage indisponible")
            override fun save(session: String) = throw IllegalStateException("stockage indisponible")
            override fun clear() = throw IllegalStateException("stockage indisponible")
        }
        val manager = StorageSessionManager(failing)
        val session = StorageSessionManager.decode(AuthFixtures.storedSession(AuthFixtures.jwt(Seed.camille)))!!
        manager.saveSession(session)
        assertEquals(session, manager.latest)
        manager.deleteSession()
        try {
            manager.loadSession()
            fail("no session expected")
        } catch (error: NoSessionFoundException) {
            // expected
        }
    }
}
