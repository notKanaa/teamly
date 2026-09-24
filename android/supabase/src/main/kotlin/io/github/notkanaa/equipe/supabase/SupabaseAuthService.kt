package io.github.notkanaa.equipe.supabase

import io.github.jan.supabase.auth.OtpType
import io.github.jan.supabase.auth.OtpVerifyResult
import io.github.jan.supabase.auth.SignOutScope
import io.github.jan.supabase.auth.exception.AuthRestException
import io.github.jan.supabase.auth.providers.builtin.Email
import io.github.jan.supabase.auth.status.SessionStatus
import io.github.notkanaa.equipe.core.AppError
import io.github.notkanaa.equipe.core.AuthService
import io.github.notkanaa.equipe.core.AuthState
import io.github.notkanaa.equipe.core.AuthUser
import io.github.notkanaa.equipe.core.InputValidation
import io.github.notkanaa.equipe.core.SignUpOutcome
import io.github.notkanaa.equipe.supabase.SupabaseErrorMapping.AuthContext
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import kotlin.coroutines.cancellation.CancellationException

/**
 * [AuthService] on Supabase Auth through supabase-kt (docs/CONTRACTS.md §1, §9). Port of SupabaseAuthService.swift.
 *
 * Every call that reads or changes the session first waits for supabase-kt to restore the stored session: a sign-out
 * made meanwhile would otherwise be undone by the end of that restoration.
 */
internal class SupabaseAuthService(private val context: SupabaseContext) : AuthService {
    private val auth get() = context.auth

    /**
     * The current state first ([AuthState.Unknown] while the stored session is being restored), then every change;
     * consecutive duplicates (e.g. a token refresh) are dropped.
     */
    override fun authStates(): Flow<AuthState> =
        auth.sessionStatus.map { SessionMapping.state(it, context.sessions) }.distinctUntilChanged()

    override suspend fun currentUser(): AuthUser? {
        auth.awaitInitialization()
        return SessionMapping.knownSession(auth.sessionStatus.value, context.sessions)?.let(SessionMapping::user)
    }

    /** Validates with `InputValidation.signUp` first: Supabase Auth alone accepts a blank or too long name. */
    override suspend fun signUp(email: String, password: String, displayName: String): SignUpOutcome {
        val input = InputValidation.signUp(email, password, displayName)
        auth.awaitInitialization()
        val before = auth.currentSessionOrNull()?.accessToken
        val created = try {
            auth.signUpWith(Email, redirectUrl = null) {
                this.email = input.email
                this.password = password
                data = buildJsonObject { put("display_name", input.displayName) }
            }
        } catch (error: Throwable) {
            throw mapped(error)
        }
        // With e-mail confirmation disabled, the answer holds a session, which supabase-kt imports.
        val session = auth.currentSessionOrNull()
        val opened = if (created != null) {
            session?.user?.id == created.id
        } else {
            session != null && session.accessToken != before
        }
        return if (opened) SignUpOutcome.SIGNED_IN else SignUpOutcome.CONFIRMATION_REQUIRED
    }

    /**
     * No account can have a malformed e-mail or an out-of-range password: such input is refused locally with
     * [AppError.InvalidCredentials], like the mocks.
     */
    override suspend fun signIn(email: String, password: String) {
        val normalized = InputValidation.normalizedEmail(email)
        try {
            InputValidation.email(normalized)
            InputValidation.password(password)
        } catch (error: AppError) {
            throw AppError.InvalidCredentials
        }
        auth.awaitInitialization()
        try {
            auth.signInWith(Email, redirectUrl = null) {
                this.email = normalized
                this.password = password
            }
        } catch (error: Throwable) {
            throw mapped(error, AuthContext.SIGN_IN)
        }
    }

    /**
     * Local scope: only this device's session ends (its refresh token is revoked on the server). The local session
     * ends whatever happens: a failure of the server call (network) does not keep the user signed in and is not
     * reported.
     */
    override suspend fun signOut() {
        auth.awaitInitialization()
        try {
            auth.signOut(SignOutScope.LOCAL)
        } catch (error: CancellationException) {
            withContext(NonCancellable) { clearLocalSession() }
            throw error
        } catch (error: Throwable) {
            clearLocalSession()
        }
    }

    /** Unknown e-mails succeed silently (Supabase Auth does not reveal whether an account exists). */
    override suspend fun sendPasswordReset(email: String) {
        val normalized = InputValidation.email(email)
        try {
            auth.resetPasswordForEmail(normalized, redirectUrl = null)
        } catch (error: Throwable) {
            throw mapped(error)
        }
    }

    /** A valid code opens a recovery session (the user is signed in). */
    override suspend fun verifyRecoveryCode(email: String, code: String) {
        val normalized = InputValidation.normalizedEmail(email)
        val token = InputValidation.trimmed(code)
        if (normalized.isEmpty() || token.isEmpty()) throw AppError.OtpInvalid
        auth.awaitInitialization()
        val result = try {
            auth.verifyEmailOtp(OtpType.Email.RECOVERY, email = normalized, token = token)
        } catch (error: Throwable) {
            throw mapped(error, AuthContext.VERIFY_OTP)
        }
        if (result !is OtpVerifyResult.Authenticated) throw RestDecoding.unexpectedAnswer()
    }

    /** `422 same_password` (the new password is the current one) is a success: the requested end state holds. */
    override suspend fun updatePassword(newPassword: String) {
        auth.awaitInitialization()
        if (SessionMapping.knownSession(auth.sessionStatus.value, context.sessions) == null) throw AppError.NotAuthenticated
        InputValidation.password(newPassword)
        try {
            auth.updateUser(redirectUrl = null) { password = newPassword }
        } catch (error: AuthRestException) {
            if (error.error == "same_password") return
            throw mapped(error)
        } catch (error: Throwable) {
            throw mapped(error)
        }
    }

    /**
     * RPC `delete_my_account`, then local sign-out.
     *
     * `not_authenticated` with an accepted token means the account no longer exists: deleted by an earlier attempt
     * whose answer was lost (« Réessayer »), or on another device. The requested end state holds, so this is a success.
     * A token refused by PostgREST (401) is refreshed once first, as for every request.
     */
    override suspend fun deleteAccount() {
        val rest = context.rest
        val request = RestQuery.rpc("delete_my_account")
        val credentials = rest.credentials()
        var answer = rest.response(request, credentials)
        if (answer.refusesTheSession && !answer.accountIsGone) {
            val fresh = rest.session.refreshedCredentials(credentials)
            answer = rest.response(request, fresh)
        }
        if (!answer.accountIsGone) {
            answer.data()
        }
        // The account and its server-side sessions are gone: only the local session is left to remove.
        withContext(NonCancellable) { clearLocalSession() }
    }

    private suspend fun clearLocalSession() {
        if (auth.sessionStatus.value !is SessionStatus.NotAuthenticated) {
            auth.clearSession()
        }
    }

    /** The mapped error; cancellation (also when the coroutine was cancelled during the call) propagates. */
    private suspend fun mapped(error: Throwable, context: AuthContext = AuthContext.GENERAL): Throwable {
        if (error is CancellationException) return error
        currentCoroutineContext().ensureActive()
        return SupabaseErrorMapping.auth(error, context)
    }
}
