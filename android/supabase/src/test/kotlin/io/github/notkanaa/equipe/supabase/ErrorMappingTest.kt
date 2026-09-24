package io.github.notkanaa.equipe.supabase

import io.github.jan.supabase.auth.exception.AuthRestException
import io.github.jan.supabase.auth.exception.AuthSessionMissingException
import io.github.jan.supabase.auth.exception.AuthWeakPasswordException
import io.github.jan.supabase.exceptions.BadRequestRestException
import io.github.jan.supabase.exceptions.HttpRequestException
import io.github.jan.supabase.exceptions.UnknownRestException
import io.github.notkanaa.equipe.core.AppError
import io.github.notkanaa.equipe.supabase.SupabaseErrorMapping.AuthContext
import io.ktor.client.HttpClient
import io.ktor.client.engine.mock.MockEngine
import io.ktor.client.engine.mock.respond
import io.ktor.client.plugins.HttpRequestTimeoutException
import io.ktor.client.request.HttpRequestBuilder
import io.ktor.client.request.get
import io.ktor.client.statement.HttpResponse
import io.ktor.http.HttpStatusCode
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.SerializationException
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.int
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test
import java.net.ConnectException
import java.net.UnknownHostException

/** §4.2 error mapping: PostgREST bodies + HTTP status, Supabase Auth codes, transport errors. */
class ErrorMappingTest {
    private fun postgrest(status: Int, json: String): AppError = SupabaseErrorMapping.postgrest(status, json.toByteArray())

    private fun auth(code: String, status: Int = 400, context: AuthContext = AuthContext.GENERAL): AppError =
        SupabaseErrorMapping.auth(code, "message", status, context)

    /** Captured error bodies, mapped with their real HTTP status. */
    @Test
    fun capturedPostgrestErrors() {
        val cases = Json.parseToJsonElement(Fixture.text("postgrest_errors")).jsonArray.map { it.jsonObject }
        assertEquals(7, cases.size)
        for (example in cases) {
            val expected = AppErrorName.all.getValue(example.getValue("expected").jsonPrimitive.content)
            val body = example.getValue("body").toString()
            val status = example.getValue("status").jsonPrimitive.int
            assertEquals(example.getValue("name").jsonPrimitive.content, expected, postgrest(status, body))
        }
    }

    @Test
    fun messageFirstThenSQLStateThenStatus() {
        assertEquals(AppError.ForbiddenFields, postgrest(403, """{"code":"42501","message":"forbidden_fields"}"""))
        assertEquals(AppError.RateLimited, postgrest(400, """{"code":"P0001","message":"rate_limited"}"""))
        assertEquals(AppError.NotFound, postgrest(400, """{"code":"P0001","message":"group_not_found"}"""))
        assertEquals(AppError.TooManyAssignees, postgrest(400, """{"code":"P0001","message":"too_many_assignees"}"""))
        assertEquals(AppError.AssigneeNotMember, postgrest(400, """{"code":"P0001","message":"assignee_not_member"}"""))
        assertEquals(AppError.NotAuthenticated, postgrest(400, """{"code":"P0001","message":"not_authenticated"}"""))
        assertEquals(AppError.Forbidden, postgrest(403, """{"code":"42501","message":"immutable_field"}"""))
        // PostgREST's own 42501: 401 without a session, 403 for a missing privilege.
        assertEquals(AppError.NotAuthenticated, postgrest(401, """{"code":"42501","message":"permission denied for table tasks"}"""))
        assertEquals(AppError.Forbidden, postgrest(403, """{"code":"42501","message":"permission denied for table tasks"}"""))
        assertEquals(AppError.NotAuthenticated, postgrest(401, """{"code":"PGRST303","message":"JWT expired"}"""))
        assertEquals(AppError.Conflict, postgrest(409, """{"code":"23505","message":"duplicate key value"}"""))
        assertEquals(AppError.Unknown("HTTP 400"), postgrest(400, ""))
        assertEquals(AppError.Unknown("PGRST100 failed to parse filter"), postgrest(400, """{"code":"PGRST100","message":"failed to parse filter"}"""))
    }

    /** Temporary failures of the hosted project are a retryable French message, never the English internals. */
    @Test
    fun temporaryServerFailuresAreRetryableAndFrench() {
        val unavailable = AppError.Unknown(SupabaseErrorMapping.SERVER_UNAVAILABLE)
        assertEquals(unavailable, postgrest(503, """{"code":"PGRST002","message":"Could not query the database for the schema cache. Retrying.","details":null,"hint":null}"""))
        assertEquals(unavailable, postgrest(503, """{"code":"PGRST001","message":"Database client error. Retrying the connection.","details":null,"hint":null}"""))
        assertEquals(unavailable, postgrest(504, """{"code":"PGRST003","message":"Timed out acquiring connection from connection pool.","details":null,"hint":null}"""))
        assertEquals(unavailable, postgrest(500, """{"code":"57014","message":"canceling statement due to statement timeout","details":null,"hint":null}"""))
        assertEquals(unavailable, postgrest(400, """{"code":"PGRST000","message":"Could not connect with the database"}"""))
        assertEquals(unavailable, postgrest(429, """{"message":"Too many requests"}"""))
        assertEquals(unavailable, postgrest(502, "<html>Bad gateway</html>"))
        assertEquals(unavailable, postgrest(503, ""))
        // A business error keeps its meaning whatever the status.
        assertEquals(AppError.LastAdmin, postgrest(500, """{"code":"P0001","message":"last_admin"}"""))
        assertEquals(
            "Une erreur est survenue. (le serveur est momentanément indisponible, réessayez dans un instant)",
            unavailable.messageFR,
        )
    }

    @Test
    fun capturedAuthErrors() {
        val cases = Json.parseToJsonElement(Fixture.text("auth_errors")).jsonArray.map { it.jsonObject }
        assertEquals(6, cases.size)
        for (example in cases) {
            val expected = AppErrorName.all.getValue(example.getValue("expected").jsonPrimitive.content)
            val body = example.getValue("body") as JsonObject
            val mapped = SupabaseErrorMapping.auth(
                body.getValue("error_code").jsonPrimitive.content,
                body.getValue("msg").jsonPrimitive.content,
                body.getValue("code").jsonPrimitive.int,
            )
            assertEquals(example.getValue("name").jsonPrimitive.content, expected, mapped)
        }
    }

    @Test
    fun authErrorCodes() {
        assertEquals(AppError.InvalidCredentials, auth("invalid_credentials"))
        assertEquals(AppError.EmailAlreadyUsed, auth("user_already_exists", 422))
        assertEquals(AppError.EmailAlreadyUsed, auth("email_exists", 422))
        assertEquals(AppError.WeakPassword, auth("weak_password", 422))
        assertEquals(AppError.InvalidEmail, auth("email_address_invalid"))
        assertEquals(AppError.OtpInvalid, auth("otp_expired", 403))
        assertEquals(AppError.EmailRateLimited, auth("over_email_send_rate_limit", 429))
        assertEquals(AppError.EmailNotConfirmed, auth("email_not_confirmed"))
        assertEquals(AppError.NotAuthenticated, auth("session_not_found", 403))
        assertEquals(AppError.NotAuthenticated, auth("refresh_token_not_found"))
        assertEquals(AppError.InvalidInput, auth("validation_failed"))
        assertEquals(AppError.InvalidCredentials, auth("validation_failed", 400, AuthContext.SIGN_IN))
        assertEquals(AppError.OtpInvalid, auth("validation_failed", 400, AuthContext.VERIFY_OTP))
        assertEquals(AppError.OtpInvalid, auth("invalid_credentials", 400, AuthContext.VERIFY_OTP))
        assertEquals(AppError.NotAuthenticated, auth("something_new", 401))
        assertEquals(AppError.Unknown(SupabaseErrorMapping.AUTH_RATE_LIMITED), auth("something_new", 429))
        assertEquals(AppError.Unknown(SupabaseErrorMapping.SERVER_UNAVAILABLE), auth("something_new", 500))
        assertEquals("the English message is not shown", AppError.Unknown("something_new"), auth("something_new", 400))
        assertEquals(
            AppError.Unknown(SupabaseErrorMapping.UNEXPECTED_ANSWER),
            SupabaseErrorMapping.auth("unknown", "Something odd", 400),
        )
        // Servers without `error_code`.
        assertEquals(AppError.InvalidCredentials, SupabaseErrorMapping.auth("unknown", "Invalid login credentials", 400))
        assertEquals(AppError.EmailAlreadyUsed, SupabaseErrorMapping.auth("unknown", "User already registered", 422))
    }

    /** Codes of a hosted project: French messages, never the English internals. */
    @Test
    fun hostedAuthCodes() {
        fun map(code: String, status: Int) = SupabaseErrorMapping.auth(code, "English message", status)
        assertEquals(AppError.Unknown(SupabaseErrorMapping.EMAIL_DELIVERY_UNAVAILABLE), map("email_address_not_authorized", 400))
        assertEquals(AppError.Unknown(SupabaseErrorMapping.AUTH_RATE_LIMITED), map("over_request_rate_limit", 429))
        assertEquals(AppError.EmailRateLimited, map("over_email_send_rate_limit", 429))
        assertEquals(AppError.Unknown(SupabaseErrorMapping.SIGNUP_DISABLED), map("signup_disabled", 422))
        assertEquals(AppError.Unknown(SupabaseErrorMapping.EMAIL_PROVIDER_DISABLED), map("email_provider_disabled", 422))
        assertEquals(AppError.Unknown(SupabaseErrorMapping.USER_BANNED), map("user_banned", 400))
        assertEquals(AppError.Unknown(SupabaseErrorMapping.REAUTHENTICATION_NEEDED), map("reauthentication_needed", 400))
        assertEquals(AppError.Unknown(SupabaseErrorMapping.CAPTCHA_FAILED), map("captcha_failed", 400))
        assertEquals(AppError.Unknown(SupabaseErrorMapping.SERVER_UNAVAILABLE), map("unexpected_failure", 500))
        assertEquals(AppError.Unknown(SupabaseErrorMapping.SERVER_UNAVAILABLE), map("request_timeout", 504))
        assertTrue(SupabaseErrorMapping.details.none { it.contains('\'') })
        assertEquals(9, SupabaseErrorMapping.details.size)
        assertEquals(
            "Une erreur est survenue. (l’envoi d’e-mails vers cette adresse n’est pas encore possible)",
            AppError.Unknown(SupabaseErrorMapping.EMAIL_DELIVERY_UNAVAILABLE).messageFR,
        )
    }

    /** supabase-kt's exceptions (built on real responses of a mock engine). */
    @Test
    fun authClientErrors() = runBlocking {
        val badRequest = response(400)
        assertEquals(
            AppError.InvalidCredentials,
            SupabaseErrorMapping.auth(AuthRestException("invalid_credentials", "Invalid login credentials", badRequest)),
        )
        assertEquals(AppError.NotAuthenticated, SupabaseErrorMapping.auth(AuthSessionMissingException(response(403))))
        assertEquals(AppError.WeakPassword, SupabaseErrorMapping.auth(AuthWeakPasswordException("weak", response(422), listOf("length"))))
        assertEquals(
            AppError.InvalidCredentials,
            SupabaseErrorMapping.auth(BadRequestRestException("Bad Request", badRequest, "Invalid login credentials")),
        )
        assertEquals(
            AppError.Unknown(SupabaseErrorMapping.SERVER_UNAVAILABLE),
            SupabaseErrorMapping.auth(AuthRestException("unexpected_failure", "Unexpected error", response(500))),
        )
        assertEquals(
            AppError.Unknown(SupabaseErrorMapping.SERVER_UNAVAILABLE),
            SupabaseErrorMapping.auth(UnknownRestException("Unknown Error", response(502))),
        )
        assertEquals(AppError.Network, SupabaseErrorMapping.auth(HttpRequestException("timeout", HttpRequestBuilder())))
        assertEquals(AppError.Network, SupabaseErrorMapping.auth(HttpRequestTimeoutException("http://127.0.0.1:9", 10_000L, null)))
        // An HTML page instead of JSON (captive portal), another error: no English internals.
        assertEquals(
            AppError.Unknown(SupabaseErrorMapping.UNEXPECTED_ANSWER),
            SupabaseErrorMapping.auth(SerializationException("Unexpected JSON token")),
        )
        assertEquals(
            AppError.Unknown(SupabaseErrorMapping.UNEXPECTED_ANSWER),
            SupabaseErrorMapping.auth(IllegalStateException("No refresh token found in current session")),
        )
    }

    @Test
    fun transportErrors() {
        assertEquals(AppError.Network, SupabaseErrorMapping.transport(UnknownHostException("127.0.0.1")))
        assertEquals(AppError.Network, SupabaseErrorMapping.transport(ConnectException("Connection refused")))
        val cancellation = CancellationException("annulé")
        assertSame(cancellation, SupabaseErrorMapping.transport(cancellation))
        assertSame(cancellation, SupabaseErrorMapping.auth(cancellation))
        assertEquals(AppError.Forbidden, SupabaseErrorMapping.transport(AppError.Forbidden))
        assertEquals(AppError.Unknown(SupabaseErrorMapping.UNEXPECTED_ANSWER), SupabaseErrorMapping.transport(IllegalArgumentException("odd")))
        assertFalse(SupabaseErrorMapping.transport(RuntimeException()) is CancellationException)
    }

    private suspend fun response(status: Int): HttpResponse {
        val client = HttpClient(MockEngine { respond("{}", HttpStatusCode.fromValue(status)) })
        return client.get("http://127.0.0.1:9/auth/v1/token")
    }
}
