package io.github.notkanaa.equipe.supabase

import io.github.jan.supabase.auth.Auth
import io.github.jan.supabase.auth.status.SessionSource
import io.github.jan.supabase.auth.status.SessionStatus
import io.github.jan.supabase.auth.user.UserSession
import io.github.jan.supabase.exceptions.RestException
import io.github.notkanaa.equipe.core.AppError
import io.github.notkanaa.equipe.core.AuthState
import io.github.notkanaa.equipe.core.AuthUser
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import java.util.Base64
import java.util.UUID
import kotlin.time.Clock
import kotlin.time.Duration.Companion.seconds

/** supabase-kt sessions and statuses → the Core auth model. */
internal object SessionMapping {
    /** A token this close to its expiry is refreshed before use (supabase-swift's `isExpired` margin). */
    val expiryMargin = 30.seconds

    /** The user id of [session] (its user, else the `sub` claim of its access token). */
    fun userId(session: UserSession): UUID? =
        session.user?.id?.let(::parseUuidOrNull) ?: jwtClaims(session.accessToken)?.get("sub").stringValue()?.let(::parseUuidOrNull)

    fun user(session: UserSession): AuthUser? {
        val id = userId(session) ?: return null
        val email = if (session.user != null) session.user?.email else jwtClaims(session.accessToken)?.get("email").stringValue()
        return AuthUser(id, email)
    }

    fun isExpired(session: UserSession): Boolean = session.expiresAt <= Clock.System.now() + expiryMargin

    /**
     * The session this client knows: the current one, or while supabase-kt retries a refresh that failed offline
     * ([SessionStatus.RefreshFailure]: an expired token, no current session), the last one it saved.
     */
    fun knownSession(status: SessionStatus, sessions: StorageSessionManager): UserSession? = when (status) {
        is SessionStatus.Authenticated -> status.session
        is SessionStatus.RefreshFailure -> sessions.latest
        else -> null
    }

    /**
     * The state for a session status: [AuthState.Unknown] while the stored session is being restored, then signed in
     * as long as a session is known (a refresh that failed offline keeps the user signed in, like on iOS).
     */
    fun state(status: SessionStatus, sessions: StorageSessionManager): AuthState = when (status) {
        SessionStatus.Initializing -> AuthState.Unknown
        is SessionStatus.NotAuthenticated -> AuthState.SignedOut
        else -> knownSession(status, sessions)?.let(::user)?.let { AuthState.SignedIn(it) } ?: AuthState.SignedOut
    }

    /** The claims of a JWT (unverified: only used to read the subject of our own session), or null. */
    fun jwtClaims(token: String): JsonObject? {
        val parts = token.split('.')
        if (parts.size != 3) return null
        return try {
            val payload = Base64.getUrlDecoder().decode(parts[1].trimEnd('=')).toString(Charsets.UTF_8)
            Json.parseToJsonElement(payload) as? JsonObject
        } catch (error: IllegalArgumentException) { // invalid Base64 or JSON
            null
        }
    }
}

/**
 * Credentials of the Auth session (port of `AuthSessionCredentials`): [AppError.NotAuthenticated] without a local
 * session; the access token is refreshed when it is about to expire, or when the server refused it
 * ([refreshedCredentials]). Refreshes are serialized: concurrent refused requests share one refresh.
 */
internal class AuthSessionCredentials(
    private val auth: Auth,
    private val sessions: StorageSessionManager,
) : CredentialsProvider {
    private val refreshLock = Mutex()

    override suspend fun credentials(): Credentials {
        auth.awaitInitialization()
        return when (val status = auth.sessionStatus.value) {
            is SessionStatus.Authenticated ->
                if (SessionMapping.isExpired(status.session)) refresh(status.session.accessToken) else credentials(status.session)
            is SessionStatus.RefreshFailure -> refresh(null)
            else -> throw AppError.NotAuthenticated
        }
    }

    /**
     * supabase-kt only clears the session by itself when its background refresh is refused; here a refused refresh
     * (`refresh_token_not_found`, `session_not_found`…: account deleted on another device, session revoked) clears
     * it too, which signs the device out.
     */
    override suspend fun refreshedCredentials(rejected: Credentials): Credentials = refresh(rejected.accessToken)

    private suspend fun refresh(rejectedToken: String?): Credentials = refreshLock.withLock {
        val current = SessionMapping.knownSession(auth.sessionStatus.value, sessions) ?: throw AppError.NotAuthenticated
        if (auth.sessionStatus.value is SessionStatus.Authenticated && current.accessToken != rejectedToken &&
            !SessionMapping.isExpired(current)
        ) {
            // Another request refreshed the session meanwhile.
            return credentials(current)
        }
        // Not abandoned halfway: with refresh token rotation, a new session whose answer is dropped would leave only a
        // used refresh token, and the next refresh would sign the device out.
        val refreshed = withContext(NonCancellable) {
            try {
                val fresh = auth.refreshSession(current.refreshToken)
                auth.importSession(fresh, source = SessionSource.Refresh(current))
                Result.success(fresh)
            } catch (error: Throwable) {
                Result.failure(error)
            }
        }
        currentCoroutineContext().ensureActive()
        val error = refreshed.exceptionOrNull() ?: return credentials(refreshed.getOrThrow())
        if (!isRefused(error)) throw SupabaseErrorMapping.auth(error)
        // supabase-kt's own refresh may have won the race with the same refresh token.
        val latest = auth.currentSessionOrNull()
        if (latest != null && latest.accessToken != current.accessToken && !SessionMapping.isExpired(latest)) {
            return credentials(latest)
        }
        auth.clearSession()
        throw AppError.NotAuthenticated
    }

    private fun credentials(session: UserSession): Credentials =
        Credentials(SessionMapping.userId(session) ?: throw AppError.NotAuthenticated, session.accessToken)

    /** The refresh token was refused (4xx other than a rate limit): the session is dead. */
    private fun isRefused(error: Throwable): Boolean =
        error is RestException && error.statusCode in 400..499 && error.statusCode != 408 && error.statusCode != 429
}
