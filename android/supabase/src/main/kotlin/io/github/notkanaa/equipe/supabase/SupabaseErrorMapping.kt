package io.github.notkanaa.equipe.supabase

import io.github.jan.supabase.auth.exception.AuthRestException
import io.github.jan.supabase.auth.exception.AuthSessionMissingException
import io.github.jan.supabase.auth.exception.AuthWeakPasswordException
import io.github.jan.supabase.auth.exception.SessionRequiredException
import io.github.jan.supabase.exceptions.RestException
import io.github.notkanaa.equipe.core.AppError
import io.github.notkanaa.equipe.core.BackendErrorMapper
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import java.io.IOException
import kotlin.coroutines.cancellation.CancellationException

/**
 * Maps every failure of the Supabase stack to [AppError] (docs/CONTRACTS.md §4.2, §9). Port of
 * SupabaseErrorMapping.swift.
 *
 * [CancellationException] is passed through unchanged: coroutine cancellation must propagate (a cancelled screen must
 * not surface « annulé »). Nothing the server says in English reaches the user: the conditions without an [AppError]
 * case of their own become [AppError.Unknown] with one of the French details below.
 */
internal object SupabaseErrorMapping {
    // region French details of AppError.Unknown

    /** A malformed answer (not JSON, an HTML page of a captive portal, a missing field). */
    const val UNEXPECTED_ANSWER = "réponse inattendue du serveur"

    /**
     * Temporary server-side failure: 5xx, PostgREST `PGRST000`–`PGRST003` (database unreachable, e.g. while a free
     * project resumes from pause), statement timeout, gateway rate limit, Auth `unexpected_failure`/`request_timeout`.
     */
    const val SERVER_UNAVAILABLE = "le serveur est momentanément indisponible, réessayez dans un instant"

    /** Supabase Auth request rate limit (a window of minutes, unlike the one-hour limit of `join_group_by_code`). */
    const val AUTH_RATE_LIMITED = "trop de tentatives, réessayez dans quelques minutes"

    /**
     * `email_address_not_authorized`: the project's built-in SMTP only delivers to its team members until a custom
     * SMTP server is configured.
     */
    const val EMAIL_DELIVERY_UNAVAILABLE = "l’envoi d’e-mails vers cette adresse n’est pas encore possible"
    const val SIGNUP_DISABLED = "les inscriptions sont fermées pour le moment"
    const val EMAIL_PROVIDER_DISABLED = "la connexion par e-mail est désactivée pour le moment"
    const val USER_BANNED = "ce compte est suspendu"
    const val REAUTHENTICATION_NEEDED = "reconnectez-vous, puis réessayez"
    const val CAPTCHA_FAILED = "la vérification de sécurité a échoué"

    /** Every French detail above (wording checks). */
    val details: List<String> = listOf(
        UNEXPECTED_ANSWER, SERVER_UNAVAILABLE, AUTH_RATE_LIMITED, EMAIL_DELIVERY_UNAVAILABLE, SIGNUP_DISABLED,
        EMAIL_PROVIDER_DISABLED, USER_BANNED, REAUTHENTICATION_NEEDED, CAPTCHA_FAILED,
    )

    // endregion

    // region PostgREST

    /** PostgREST codes of a database it cannot reach (connection, schema cache, pool timeout) and statement timeouts. */
    val temporaryPostgrestCodes: Set<String> = setOf("PGRST000", "PGRST001", "PGRST002", "PGRST003", "57014")

    /**
     * A non-2xx PostgREST answer → [BackendErrorMapper] (message first, then SQLSTATE, then HTTP status). The body is
     * PostgREST's JSON error: `{"code": "P0001", "message": "last_admin", "details": …, "hint": …}`.
     */
    fun postgrest(status: Int, body: ByteArray): AppError {
        val error = postgrestErrorBody(body)
        val mapped = BackendErrorMapper.map(error?.code, error?.message, status)
        if (mapped !is AppError.Unknown) return mapped
        val isTemporaryCode = error?.code?.let { it in temporaryPostgrestCodes } ?: false
        if (status >= 500 || status == 429 || isTemporaryCode) {
            return AppError.Unknown(SERVER_UNAVAILABLE)
        }
        // No usable body: at least name the HTTP status.
        return if (mapped.detail.isEmpty()) AppError.Unknown("HTTP $status") else mapped
    }

    private class PostgrestErrorBody(val code: String?, val message: String?)

    /** `code` and `message` of a JSON object body; null when the body is not such an object (like Swift's decoder). */
    private fun postgrestErrorBody(body: ByteArray): PostgrestErrorBody? {
        val json = try {
            Json.parseToJsonElement(body.decodeToString())
        } catch (error: IllegalArgumentException) { // SerializationException included
            return null
        } as? JsonObject ?: return null
        fun field(name: String): Pair<Boolean, String?> = when (val value = json[name]) {
            null, JsonNull -> true to null
            is JsonPrimitive -> if (value.isString) true to value.content else false to null
            else -> false to null
        }
        val (codeValid, code) = field("code")
        val (messageValid, message) = field("message")
        if (!codeValid || !messageValid) return null
        return PostgrestErrorBody(code, message)
    }

    // endregion

    // region Transport

    /**
     * Network-level failures: any [IOException] (no connection, DNS, TLS, timeouts, supabase-kt's
     * `HttpRequestException`) → [AppError.Network]; anything else (e.g. an undecodable answer) →
     * `Unknown(`[UNEXPECTED_ANSWER]`)`. Cancellation and [AppError]s pass through.
     */
    fun transport(error: Throwable): Throwable = when (error) {
        is CancellationException, is AppError -> error
        is IOException -> AppError.Network
        else -> AppError.Unknown(UNEXPECTED_ANSWER)
    }

    // endregion

    // region Auth

    /** Where an Auth error happened: a few codes mean something specific to one call. */
    enum class AuthContext {
        GENERAL,
        SIGN_IN,
        VERIFY_OTP,
    }

    /** Maps an error thrown by supabase-kt's Auth plugin (Supabase Auth / GoTrue). */
    fun auth(error: Throwable, context: AuthContext = AuthContext.GENERAL): Throwable = when (error) {
        is CancellationException, is AppError -> error
        is AuthWeakPasswordException -> AppError.WeakPassword
        is AuthSessionMissingException -> AppError.NotAuthenticated
        is AuthRestException -> auth(error.error, error.errorDescription, error.statusCode, context)
        // An answer without `error_code` (older servers): only the HTTP status and the message are known.
        is RestException -> auth(UNKNOWN_CODE, error.description ?: error.error, error.statusCode, context)
        is SessionRequiredException -> AppError.NotAuthenticated
        else -> transport(error)
    }

    /** `error_code` of an Auth answer that has none (supabase-swift's `ErrorCode.unknown`). */
    const val UNKNOWN_CODE = "unknown"

    /** Supabase Auth error codes (`error_code`) → [AppError]. */
    fun auth(code: String, message: String, httpStatus: Int, context: AuthContext = AuthContext.GENERAL): AppError {
        when {
            context == AuthContext.SIGN_IN && code == "validation_failed" -> return AppError.InvalidCredentials
            context == AuthContext.VERIFY_OTP && code in setOf("validation_failed", "otp_disabled", "invalid_credentials") ->
                return AppError.OtpInvalid
        }
        when (code) {
            "invalid_credentials" -> return AppError.InvalidCredentials
            "user_already_exists", "email_exists" -> return AppError.EmailAlreadyUsed
            "weak_password" -> return AppError.WeakPassword
            "email_address_invalid" -> return AppError.InvalidEmail
            "email_not_confirmed" -> return AppError.EmailNotConfirmed
            "otp_expired" -> return AppError.OtpInvalid
            "over_email_send_rate_limit" -> return AppError.EmailRateLimited
            "over_request_rate_limit" -> return AppError.Unknown(AUTH_RATE_LIMITED)
            "session_not_found", "session_expired", "refresh_token_not_found", "refresh_token_already_used",
            "bad_jwt", "no_authorization", "user_not_found",
            -> return AppError.NotAuthenticated
            "validation_failed" -> return AppError.InvalidInput
            "email_address_not_authorized" -> return AppError.Unknown(EMAIL_DELIVERY_UNAVAILABLE)
            "signup_disabled" -> return AppError.Unknown(SIGNUP_DISABLED)
            "email_provider_disabled" -> return AppError.Unknown(EMAIL_PROVIDER_DISABLED)
            "user_banned" -> return AppError.Unknown(USER_BANNED)
            "reauthentication_needed", "reauthentication_not_valid" -> return AppError.Unknown(REAUTHENTICATION_NEEDED)
            "captcha_failed" -> return AppError.Unknown(CAPTCHA_FAILED)
            "unexpected_failure", "request_timeout" -> return AppError.Unknown(SERVER_UNAVAILABLE)
        }
        // Servers older than the `error_code` field: match the historical messages.
        when (message) {
            "Invalid login credentials" -> return AppError.InvalidCredentials
            "User already registered" -> return AppError.EmailAlreadyUsed
        }
        return when {
            httpStatus == 401 -> AppError.NotAuthenticated
            httpStatus == 429 -> AppError.Unknown(AUTH_RATE_LIMITED)
            httpStatus >= 500 -> AppError.Unknown(SERVER_UNAVAILABLE)
            // The server's message is English: only the code is shown (for support).
            else -> AppError.Unknown(if (code == UNKNOWN_CODE) UNEXPECTED_ANSWER else code)
        }
    }

    // endregion
}
