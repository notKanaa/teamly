package io.github.notkanaa.equipe.supabase

import io.github.jan.supabase.auth.status.SessionSource
import io.github.jan.supabase.auth.status.SessionStatus
import io.github.jan.supabase.auth.user.UserInfo
import io.github.jan.supabase.auth.user.UserSession
import io.github.notkanaa.equipe.core.AppError
import io.github.notkanaa.equipe.core.AuthState
import io.github.notkanaa.equipe.core.AuthUser
import io.github.notkanaa.equipe.core.SignUpOutcome
import io.github.notkanaa.equipe.supabase.FakeServer.Companion.failure
import io.github.notkanaa.equipe.supabase.FakeServer.Companion.fixture
import io.github.notkanaa.equipe.supabase.FakeServer.Companion.json
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.Base64
import java.util.UUID
import kotlin.time.Clock
import kotlin.time.Duration.Companion.hours
import kotlin.time.Duration.Companion.minutes
import kotlin.time.Duration.Companion.seconds

/** A session storage that records what the adapters persist (tests only). */
internal class RecordingSessionStorage(initial: String? = null) : SessionStorage {
    @Volatile var value: String? = initial
        private set

    @Volatile var saves = 0
        private set

    @Volatile var clears = 0
        private set

    override fun load(): String? = value

    override fun save(session: String) {
        saves += 1
        value = session
    }

    override fun clear() {
        clears += 1
        value = null
    }
}

/** Sessions and Auth answers of a fake Supabase Auth (tests only). */
internal object AuthFixtures {
    const val EMAIL = "camille@example.com"

    fun jwt(sub: UUID, email: String? = EMAIL, expiresInSeconds: Long = 3_600): String {
        fun encode(json: String) = Base64.getUrlEncoder().withoutPadding().encodeToString(json.toByteArray())
        val exp = System.currentTimeMillis() / 1_000 + expiresInSeconds
        val emailClaim = email?.let { ""","email":"$it"""" } ?: ""
        return encode("""{"alg":"HS256","typ":"JWT"}""") + "." +
            encode("""{"sub":"$sub"$emailClaim,"role":"authenticated","aud":"authenticated","exp":$exp}""") + ".signature"
    }

    /** A GoTrue session answer (sign-in, sign-up, refresh, verify). */
    fun sessionAnswer(accessToken: String, refreshToken: String = "rafraichir", user: UUID = Seed.camille, email: String = EMAIL) = """
        {"access_token":"$accessToken","token_type":"bearer","expires_in":3600,"expires_at":1790247600,"refresh_token":"$refreshToken",
        "user":{"id":"$user","aud":"authenticated","role":"authenticated","email":"$email","app_metadata":{"provider":"email"},
        "user_metadata":{"display_name":"Camille Martin"},"created_at":"2026-08-24T23:52:26.878215Z","updated_at":"2026-09-24T00:14:27.0787Z",
        "is_anonymous":false}}
    """.trimIndent()

    /** A GoTrue error answer. */
    fun error(status: Int, code: String, message: String) = """{"code":$status,"error_code":"$code","msg":"$message"}"""

    /** A session as [StorageSessionManager] persists it. */
    fun storedSession(accessToken: String, expiresIn: kotlin.time.Duration = 1.hours, user: UUID? = Seed.camille): String {
        val session = UserSession(
            accessToken = accessToken,
            refreshToken = "rafraichir",
            expiresIn = 3_600,
            tokenType = "bearer",
            user = user?.let { UserInfo(aud = "authenticated", id = it.toString(), email = EMAIL) },
            expiresAt = Clock.System.now() + expiresIn,
        )
        return StorageSessionManager.json.encodeToString(UserSession.serializer(), session)
    }
}

/**
 * Auth adapter behaviour: client-side validation (§1), signed-out state, state mapping, and the flows against a fake
 * Supabase Auth (sign-in, sign-up, sign-out, password update, session refresh and refusal, stored sessions).
 */
class AuthUnitTest {
    private val signedOut = UnitBackend.signedOutServices(FakeServer()).auth

    @Test
    fun signUpValidatesEmailThenPasswordThenDisplayName() {
        assertThrows(AppError.InvalidEmail) { signedOut.signUp("adresse-invalide", "court", "") }
        assertThrows(AppError.WeakPassword) { signedOut.signUp("nouveau@example.com", "abc1234", "") }
        assertThrows(AppError.InvalidInput) { signedOut.signUp("nouveau@example.com", "é".repeat(37), "Nom") }
        assertThrows(AppError.InvalidDisplayName) { signedOut.signUp("nouveau@example.com", "motdepasse123", "   ") }
        assertThrows(AppError.InvalidDisplayName) { signedOut.signUp("nouveau@example.com", "motdepasse123", "x".repeat(51)) }
    }

    @Test
    fun impossibleCredentialsAreRefusedLocally() {
        assertThrows(AppError.InvalidCredentials) { signedOut.signIn("pas-une-adresse", "motdepasse123") }
        assertThrows(AppError.InvalidCredentials) { signedOut.signIn("camille@example.com", "") }
    }

    @Test
    fun recoveryInputIsValidatedLocally() {
        assertThrows(AppError.InvalidEmail) { signedOut.sendPasswordReset("  ") }
        assertThrows(AppError.OtpInvalid) { signedOut.verifyRecoveryCode("camille@example.com", "  ") }
    }

    @Test
    fun signedOutState() = runBlocking {
        val server = FakeServer()
        val auth = UnitBackend.signedOutServices(server).auth
        assertNull(auth.currentUser())
        assertThrows(AppError.NotAuthenticated) { auth.updatePassword("motdepasse123") }
        auth.signOut()
        assertEquals(AuthState.SignedOut, auth.authStates().first { it != AuthState.Unknown })
        assertTrue(server.authRequests.isEmpty())
    }

    @Test
    fun sessionStatusesMapToStates() {
        val sessions = StorageSessionManager(SessionStorage.InMemory)
        val stored = StorageSessionManager.decode(AuthFixtures.storedSession(AuthFixtures.jwt(Seed.camille)))!!
        val camille = AuthUser(Seed.camille, AuthFixtures.EMAIL)
        assertEquals(AuthState.Unknown, SessionMapping.state(SessionStatus.Initializing, sessions))
        assertEquals(AuthState.SignedOut, SessionMapping.state(SessionStatus.NotAuthenticated(), sessions))
        assertEquals(AuthState.SignedOut, SessionMapping.state(SessionStatus.NotAuthenticated(isSignOut = true), sessions))
        for (source in listOf(SessionSource.Storage, SessionSource.Unknown, SessionSource.Refresh(stored), SessionSource.UserChanged(stored))) {
            assertEquals(AuthState.SignedIn(camille), SessionMapping.state(SessionStatus.Authenticated(stored, source), sessions))
        }
        // A session without its user: the subject and e-mail of the access token.
        val bare = stored.copy(user = null)
        assertEquals(AuthState.SignedIn(camille), SessionMapping.state(SessionStatus.Authenticated(bare), sessions))
        assertEquals(Seed.camille, SessionMapping.userId(bare))
        assertNull(SessionMapping.userId(bare.copy(accessToken = "pas-un-jeton")))
    }

    @Test
    fun signInOpensTheSessionAndPersistsIt() = runBlocking {
        val server = FakeServer()
        val storage = RecordingSessionStorage()
        val context = UnitBackend.context(server, storage)
        val auth = SupabaseBackend.services(context).auth
        val token = AuthFixtures.jwt(Seed.camille)
        server.queueAuth(json(200, AuthFixtures.sessionAnswer(token)))
        auth.signIn("  Camille@Example.COM ", "motdepasse123")
        val request = server.authRequests.single()
        assertEquals("POST", request.method)
        assertEquals("token?grant_type=password", request.target)
        assertTrue(request.body!!.contains(""""email":"camille@example.com""""))
        assertEquals(AuthUser(Seed.camille, AuthFixtures.EMAIL), auth.currentUser())
        assertEquals(AuthState.SignedIn(AuthUser(Seed.camille, AuthFixtures.EMAIL)), auth.authStates().first())
        assertTrue(storage.saves >= 1)
        assertEquals(token, StorageSessionManager.decode(storage.value!!)!!.accessToken)

        // The PostgREST requests carry the session's token.
        server.queueRest(fixture(200, "profile"))
        SupabaseBackend.services(context).profiles.myProfile()
        assertEquals("Bearer $token", server.sent.single().headers["authorization"])
        assertEquals("profiles?select=id,display_name&id=eq.11111111-1111-4111-8111-111111111111", server.sent.single().target)
        context.close()
    }

    @Test
    fun signInErrorsAreMapped() = runBlocking {
        val server = FakeServer()
        val auth = SupabaseBackend.services(UnitBackend.context(server)).auth
        server.queueAuth(
            json(400, AuthFixtures.error(400, "invalid_credentials", "Invalid login credentials")),
            json(400, AuthFixtures.error(400, "email_not_confirmed", "Email not confirmed")),
            json(429, AuthFixtures.error(429, "over_request_rate_limit", "Request rate limit reached")),
            json(502, "<html>Bad gateway</html>"),
            failure(),
        )
        assertThrows(AppError.InvalidCredentials) { auth.signIn(AuthFixtures.EMAIL, "motdepasse123") }
        assertThrows(AppError.EmailNotConfirmed) { auth.signIn(AuthFixtures.EMAIL, "motdepasse123") }
        assertThrows(AppError.Unknown(SupabaseErrorMapping.AUTH_RATE_LIMITED)) { auth.signIn(AuthFixtures.EMAIL, "motdepasse123") }
        assertThrows(AppError.Unknown(SupabaseErrorMapping.SERVER_UNAVAILABLE)) { auth.signIn(AuthFixtures.EMAIL, "motdepasse123") }
        assertThrows(AppError.Network) { auth.signIn(AuthFixtures.EMAIL, "motdepasse123") }
        assertNull(auth.currentUser())
    }

    @Test
    fun signUpOpensASessionOrAsksForConfirmation() = runBlocking {
        val server = FakeServer()
        val auth = SupabaseBackend.services(UnitBackend.context(server)).auth
        val other = uuid("44444444-4444-4444-8444-444444444444")
        server.queueAuth(
            // E-mail confirmation required: the user only.
            json(
                200,
                """{"id":"$other","aud":"authenticated","role":"","email":"nouveau@example.com","confirmation_sent_at":"2026-09-24T00:14:27Z"}""",
            ),
            json(200, AuthFixtures.sessionAnswer(AuthFixtures.jwt(Seed.camille))),
            json(422, AuthFixtures.error(422, "user_already_exists", "User already registered")),
            json(422, """{"code":422,"error_code":"weak_password","msg":"Password is known to be weak","weak_password":{"reasons":["pwned"]}}"""),
        )
        assertEquals(SignUpOutcome.CONFIRMATION_REQUIRED, auth.signUp(" Nouveau@Example.com ", "motdepasse123", "  Nouveau  "))
        val body = server.authRequests.single().body!!
        assertTrue(body, body.contains(""""email":"nouveau@example.com"""") && body.contains(""""display_name":"Nouveau""""))
        assertNull(auth.currentUser())
        assertEquals(SignUpOutcome.SIGNED_IN, auth.signUp(AuthFixtures.EMAIL, "motdepasse123", "Camille Martin"))
        assertEquals(Seed.camille, auth.currentUser()?.id)
        assertThrows(AppError.EmailAlreadyUsed) { auth.signUp(AuthFixtures.EMAIL, "motdepasse123", "Camille") }
        assertThrows(AppError.WeakPassword) { auth.signUp(AuthFixtures.EMAIL, "motdepasse123", "Camille") }
    }

    /** `422 same_password` is a success; other errors are mapped; signed out → NotAuthenticated first. */
    @Test
    fun updatePassword() = runBlocking {
        val server = FakeServer()
        val storage = RecordingSessionStorage(AuthFixtures.storedSession(AuthFixtures.jwt(Seed.camille)))
        val auth = SupabaseBackend.services(UnitBackend.context(server, storage)).auth
        server.queueAuth(
            json(200, """{"id":"${Seed.camille}","aud":"authenticated","email":"${AuthFixtures.EMAIL}"}"""),
            json(422, AuthFixtures.error(422, "same_password", "New password should be different from the old password.")),
            json(400, AuthFixtures.error(400, "reauthentication_needed", "Password update requires reauthentication")),
        )
        assertThrows(AppError.WeakPassword) { auth.updatePassword("court") }
        assertTrue(server.authRequests.isEmpty())
        auth.updatePassword("nouveau-motdepasse")
        auth.updatePassword("nouveau-motdepasse")
        assertThrows(AppError.Unknown(SupabaseErrorMapping.REAUTHENTICATION_NEEDED)) { auth.updatePassword("nouveau-motdepasse") }
        assertEquals(listOf("PUT"), server.authRequests.map { it.method }.distinct())
        assertTrue(server.authRequests.first().body!!.contains(""""password":"nouveau-motdepasse""""))
    }

    /** Local scope; offline, the local session ends anyway and nothing is reported. */
    @Test
    fun signOutAlwaysEndsTheLocalSession() = runBlocking {
        val server = FakeServer()
        val storage = RecordingSessionStorage(AuthFixtures.storedSession(AuthFixtures.jwt(Seed.camille)))
        val auth = SupabaseBackend.services(UnitBackend.context(server, storage)).auth
        assertEquals(Seed.camille, auth.currentUser()?.id)
        server.queueAuth(failure())
        auth.signOut()
        assertEquals("logout?scope=local", server.authRequests.single().target)
        assertNull(auth.currentUser())
        assertNull(storage.value)
        assertEquals(AuthState.SignedOut, auth.authStates().first())

        val online = RecordingSessionStorage(AuthFixtures.storedSession(AuthFixtures.jwt(Seed.camille)))
        val onlineServer = FakeServer()
        val onlineAuth = SupabaseBackend.services(UnitBackend.context(onlineServer, online)).auth
        onlineServer.queueAuth(json(204, ""))
        onlineAuth.signOut()
        assertNull(onlineAuth.currentUser())
        assertNull(online.value)
    }

    /** The stored session is restored at launch; `Unknown` may come first, never `SignedOut`. */
    @Test
    fun storedSessionIsRestored() = runBlocking {
        val storage = RecordingSessionStorage(AuthFixtures.storedSession(AuthFixtures.jwt(Seed.camille)))
        val auth = SupabaseBackend.services(UnitBackend.context(FakeServer(), storage)).auth
        val first = auth.authStates().first()
        assertTrue("$first", first == AuthState.Unknown || first == AuthState.SignedIn(AuthUser(Seed.camille, AuthFixtures.EMAIL)))
        assertEquals(AuthUser(Seed.camille, AuthFixtures.EMAIL), auth.currentUser())
        assertEquals(AuthState.SignedIn(AuthUser(Seed.camille, AuthFixtures.EMAIL)), auth.authStates().first { it != AuthState.Unknown })
        // An unreadable stored session counts as signed out (and is removed).
        val broken = RecordingSessionStorage("{pas du json")
        val brokenAuth = SupabaseBackend.services(UnitBackend.context(FakeServer(), broken)).auth
        assertNull(brokenAuth.currentUser())
        assertNull(broken.value)
    }

    /**
     * Launched offline with an expired stored token: the user stays signed in (like iOS), and requests fail with
     * Network rather than NotAuthenticated.
     */
    @Test
    fun expiredSessionOfflineStaysSignedIn() = runBlocking {
        val server = FakeServer()
        val storage = RecordingSessionStorage(AuthFixtures.storedSession(AuthFixtures.jwt(Seed.camille, expiresInSeconds = -60), expiresIn = (-1).minutes))
        val context = UnitBackend.context(server, storage)
        val services = SupabaseBackend.services(context)
        assertEquals(Seed.camille, services.auth.currentUser()?.id)
        assertEquals(AuthState.SignedIn(AuthUser(Seed.camille, AuthFixtures.EMAIL)), services.auth.authStates().first { it != AuthState.Unknown })
        assertThrows(AppError.Network) { services.groups.myGroups() }
        assertTrue(server.sent.isEmpty())
        assertNotNull(storage.value)
        context.close()
    }

    /**
     * A token refused by PostgREST is refreshed once (real Auth session) and the request sent again with the new token.
     */
    @Test
    fun refusedTokenIsRefreshedThroughAuth() = runBlocking {
        val server = FakeServer()
        val old = AuthFixtures.jwt(Seed.camille)
        val storage = RecordingSessionStorage(AuthFixtures.storedSession(old))
        val context = UnitBackend.context(server, storage)
        val groups = SupabaseBackend.services(context).groups
        val fresh = AuthFixtures.jwt(Seed.camille, expiresInSeconds = 3_601)
        server.queueRest(json(401, """{"code":"PGRST301","message":"JWT cryptographic operation failed"}"""), fixture(200, "my_groups"))
        server.queueAuth(json(200, AuthFixtures.sessionAnswer(fresh, refreshToken = "rafraichir-2")))
        assertEquals(listOf(Seed.lilas, Seed.sport), groups.myGroups().map { it.id })
        assertEquals(listOf("Bearer $old", "Bearer $fresh"), server.sent.map { it.headers["authorization"] })
        assertEquals("token?grant_type=refresh_token", server.authRequests.single().target)
        assertTrue(server.authRequests.single().body!!.contains(""""refresh_token":"rafraichir""""))
        assertEquals(fresh, StorageSessionManager.decode(storage.value!!)!!.accessToken)
        context.close()
    }

    /** A dead session (the account was deleted elsewhere): the refresh is refused, the device signs out. */
    @Test
    fun refusedRefreshSignsTheDeviceOut() = runBlocking {
        val server = FakeServer()
        val storage = RecordingSessionStorage(AuthFixtures.storedSession(AuthFixtures.jwt(Seed.camille)))
        val context = UnitBackend.context(server, storage)
        val services = SupabaseBackend.services(context)
        server.queueRest(json(400, """{"code":"P0001","message":"not_authenticated"}"""))
        server.queueAuth(json(400, AuthFixtures.error(400, "refresh_token_not_found", "Invalid Refresh Token: Refresh Token Not Found")))
        assertThrows(AppError.NotAuthenticated) { services.groups.createGroup("Encore") }
        assertEquals(1, server.sent.size)
        withTimeout(5.seconds) { services.auth.authStates().first { it == AuthState.SignedOut } }
        assertNull(services.auth.currentUser())
        assertNull(storage.value)
        context.close()
    }

    /** With the real Auth session: the account already gone → success and local sign-out. */
    @Test
    fun deletingAnAlreadyDeletedAccountSignsOutLocally() = runBlocking {
        val server = FakeServer()
        val token = AuthFixtures.jwt(Seed.camille)
        val storage = RecordingSessionStorage(AuthFixtures.storedSession(token))
        val context = UnitBackend.context(server, storage)
        val auth = SupabaseBackend.services(context).auth
        server.queueRest(json(400, """{"code":"P0001","details":null,"hint":null,"message":"not_authenticated"}"""))
        assertEquals(Seed.camille, auth.currentUser()?.id)
        auth.deleteAccount()
        assertNull(auth.currentUser())
        assertNull(storage.value)
        assertEquals(listOf("Bearer $token"), server.sent.map { it.headers["authorization"] })
        assertTrue("no server sign-out after the deletion", server.authRequests.isEmpty())
        context.close()
    }

    @Test
    fun passwordRecovery() = runBlocking {
        val server = FakeServer()
        val auth = SupabaseBackend.services(UnitBackend.context(server)).auth
        server.queueAuth(
            json(200, "{}"),
            json(403, AuthFixtures.error(403, "otp_expired", "Token has expired or is invalid")),
            json(200, AuthFixtures.sessionAnswer(AuthFixtures.jwt(Seed.camille))),
        )
        auth.sendPasswordReset("  Camille@Example.com ")
        assertEquals("recover", server.authRequests[0].target)
        assertTrue(server.authRequests[0].body!!.contains(""""email":"camille@example.com""""))
        assertThrows(AppError.OtpInvalid) { auth.verifyRecoveryCode(AuthFixtures.EMAIL, "000000") }
        assertNull(auth.currentUser())
        auth.verifyRecoveryCode(" CAMILLE@example.com ", " 123456 ")
        val verify = server.authRequests[2]
        assertEquals("verify", verify.target)
        val body = verify.body.orEmpty()
        assertTrue(body, body.contains(""""type":"recovery"""") && body.contains(""""token":"123456""""))
        assertEquals(Seed.camille, auth.currentUser()?.id)
    }
}
