package io.github.notkanaa.equipe.supabase

import io.github.notkanaa.equipe.core.AppError
import io.github.notkanaa.equipe.core.AppServices
import io.ktor.client.engine.mock.MockEngine
import io.ktor.client.engine.mock.MockRequestHandleScope
import io.ktor.client.engine.mock.respond
import io.ktor.client.request.HttpRequestData
import io.ktor.client.request.HttpResponseData
import io.ktor.content.ByteArrayContent
import io.ktor.content.TextContent
import io.ktor.http.HttpHeaders
import io.ktor.http.HttpStatusCode
import io.ktor.http.content.OutgoingContent
import io.ktor.http.headersOf
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.fail
import java.io.IOException
import java.time.Instant
import java.util.UUID
import java.util.concurrent.ConcurrentLinkedQueue
import java.util.concurrent.CopyOnWriteArrayList

/** JSON files of `src/test/resources/fixtures` (copied from TeamTasksSupabaseTests/Fixtures). */
internal object Fixture {
    fun text(name: String): String {
        val stream = Fixture::class.java.getResourceAsStream("/fixtures/$name.json")
            ?: throw IllegalStateException("missing fixture $name.json")
        return stream.use { it.readBytes().toString(Charsets.UTF_8) }
    }

    fun bytes(name: String): ByteArray = text(name).toByteArray(Charsets.UTF_8)
}

/** A UUID literal (tests only). */
internal fun uuid(text: String): UUID = parseUuidOrNull(text) ?: throw IllegalArgumentException("invalid UUID literal $text")

/** Ids of `supabase/seed.sql` (docs/CONTRACTS.md §8), as found in the captured fixtures. */
internal object Seed {
    val camille = uuid("11111111-1111-4111-8111-111111111111")
    val lucas = uuid("22222222-2222-4222-8222-222222222222")
    val ines = uuid("33333333-3333-4333-8333-333333333333")
    val lilas = uuid("a0000000-0000-4000-8000-000000000001")
    val sport = uuid("a0000000-0000-4000-8000-000000000002")
    val poubelles = uuid("b0000000-0000-4000-8000-000000000001")
    val courses = uuid("b0000000-0000-4000-8000-000000000002")
    val cuisine = uuid("b0000000-0000-4000-8000-000000000005")
    val gymnase = uuid("b0000000-0000-4000-8000-000000000006")
}

/** `AppError` cases by name, as written in the error fixtures. */
internal object AppErrorName {
    val all: Map<String, AppError> = mapOf(
        "notAuthenticated" to AppError.NotAuthenticated, "invalidCredentials" to AppError.InvalidCredentials,
        "emailAlreadyUsed" to AppError.EmailAlreadyUsed, "weakPassword" to AppError.WeakPassword,
        "invalidEmail" to AppError.InvalidEmail, "otpInvalid" to AppError.OtpInvalid,
        "emailRateLimited" to AppError.EmailRateLimited, "emailNotConfirmed" to AppError.EmailNotConfirmed,
        "invalidInput" to AppError.InvalidInput, "lastAdmin" to AppError.LastAdmin, "forbidden" to AppError.Forbidden,
        "notFound" to AppError.NotFound,
        // Conditions without a case of their own: Unknown with a French detail.
        "emailDeliveryUnavailable" to AppError.Unknown(SupabaseErrorMapping.EMAIL_DELIVERY_UNAVAILABLE),
        "signupDisabled" to AppError.Unknown(SupabaseErrorMapping.SIGNUP_DISABLED),
        "reauthenticationNeeded" to AppError.Unknown(SupabaseErrorMapping.REAUTHENTICATION_NEEDED),
    )
}

/**
 * A fake Supabase server on Ktor's mock engine: answers the PostgREST requests (`/rest/v1/…`) and the Auth requests
 * (`/auth/v1/…`) with queued responses, and records what was sent. A request without a queued response fails like a
 * network error.
 */
internal class FakeServer(rest: List<Response> = emptyList()) {
    /** One recorded request. */
    class Sent(
        val method: String,
        /** Path and query relative to `/rest/v1/` (or `/auth/v1/`), percent-decoded. */
        val target: String,
        /** Path and query as sent (percent-encoded). */
        val encodedTarget: String,
        /** Header names lower-cased. */
        val headers: Map<String, String>,
        val body: String?,
    )

    sealed interface Response {
        data class Json(val status: Int, val body: String) : Response
        data class Fixture(val status: Int, val name: String) : Response
        data class Failure(val error: IOException) : Response
    }

    private val restQueue = ConcurrentLinkedQueue(rest)
    private val authQueue = ConcurrentLinkedQueue<Response>()
    private val restSent = CopyOnWriteArrayList<Sent>()
    private val authSent = CopyOnWriteArrayList<Sent>()

    /** PostgREST requests sent so far. */
    val sent: List<Sent> get() = restSent.toList()

    /** Auth requests sent so far. */
    val authRequests: List<Sent> get() = authSent.toList()

    fun queueRest(vararg responses: Response) {
        restQueue.addAll(responses)
    }

    fun queueAuth(vararg responses: Response) {
        authQueue.addAll(responses)
    }

    val engine: MockEngine = MockEngine { request -> answer(request) }

    private suspend fun MockRequestHandleScope.answer(request: HttpRequestData): HttpResponseData {
        val encoded = request.url.encodedPathAndQuery
        val (queue, sentList, prefix) = when {
            encoded.startsWith("/rest/v1/") -> Triple(restQueue, restSent, "/rest/v1/")
            encoded.startsWith("/auth/v1/") -> Triple(authQueue, authSent, "/auth/v1/")
            else -> throw IOException("unexpected request ${request.url}")
        }
        val relative = encoded.removePrefix(prefix)
        sentList.add(
            Sent(
                method = request.method.value,
                target = percentDecoded(relative),
                encodedTarget = relative,
                headers = request.headers.entries().associate { (name, values) -> name.lowercase() to values.joinToString(",") } +
                    listOfNotNull(request.body.contentType?.let { "content-type" to it.toString() }),
                body = bodyText(request.body),
            ),
        )
        return when (val next = queue.poll()) {
            is Response.Json -> respondJson(next.status, next.body)
            is Response.Fixture -> respondJson(next.status, Fixture.text(next.name))
            is Response.Failure -> throw next.error
            null -> throw IOException("no response queued for ${request.method.value} $relative")
        }
    }

    private fun MockRequestHandleScope.respondJson(status: Int, body: String): HttpResponseData =
        respond(body, HttpStatusCode.fromValue(status), headersOf(HttpHeaders.ContentType, "application/json"))

    private fun bodyText(body: OutgoingContent): String? = when (body) {
        is ByteArrayContent -> body.bytes().toString(Charsets.UTF_8)
        is TextContent -> body.text
        else -> null
    }

    companion object {
        fun json(status: Int, body: String): Response = Response.Json(status, body)

        fun fixture(status: Int, name: String): Response = Response.Fixture(status, name)

        fun failure(error: IOException = java.net.ConnectException("Connection refused")): Response = Response.Failure(error)

        /** Decodes `%XX` sequences only (a `+` stays a `+`). */
        fun percentDecoded(text: String): String {
            val bytes = java.io.ByteArrayOutputStream()
            var index = 0
            while (index < text.length) {
                if (text[index] == '%' && index + 2 < text.length) {
                    bytes.write(text.substring(index + 1, index + 3).toInt(16))
                    index += 3
                } else {
                    val codePoint = text.codePointAt(index)
                    bytes.write(String(Character.toChars(codePoint)).toByteArray(Charsets.UTF_8))
                    index += Character.charCount(codePoint)
                }
            }
            return bytes.toByteArray().toString(Charsets.UTF_8)
        }
    }
}

/** Fixed credentials: no Auth involved. */
internal class FixedCredentials(private val userId: UUID) : CredentialsProvider {
    override suspend fun credentials(): Credentials = Credentials(userId, "jeton-de-test")

    /** Nothing to refresh: a refused session stays refused (the request is not sent again). */
    override suspend fun refreshedCredentials(rejected: Credentials): Credentials = throw AppError.NotAuthenticated
}

/** Credentials whose refresh is scripted: tokens `jeton-1`, `jeton-2`… (tests only). */
internal class ScriptedCredentials(
    private val userId: UUID = Seed.camille,
    /** Thrown by every refresh (a dead session: NotAuthenticated); null: refreshes work. */
    private val refreshError: AppError? = null,
) : CredentialsProvider {
    @Volatile private var token = 1

    @Volatile var refreshCount = 0
        private set

    override suspend fun credentials(): Credentials = Credentials(userId, "jeton-$token")

    override suspend fun refreshedCredentials(rejected: Credentials): Credentials = synchronized(this) {
        refreshCount += 1
        refreshError?.let { throw it }
        token += 1
        Credentials(userId, "jeton-$token")
    }
}

internal object UnitBackend {
    /** Nothing listens on port 9: any unexpected real network use fails fast. */
    val configuration = SupabaseConfiguration(url = "http://127.0.0.1:9", publishableKey = "sb_publishable_test")

    /** 2026-09-24T10:00:00.123456Z */
    val now: Instant = PostgresTimestamp.instant(1_790_244_000_123_456L)

    /** Services whose PostgREST calls go to [server], signed in as [me] (fixed credentials). */
    fun services(
        server: FakeServer,
        me: UUID = Seed.camille,
        now: Instant = UnitBackend.now,
        credentials: CredentialsProvider = FixedCredentials(me),
    ): AppServices = SupabaseBackend.services(context(server, credentials = credentials, now = now))

    /** Services with the real Auth session (restored from [storage]) on [server]. */
    fun context(
        server: FakeServer,
        storage: SessionStorage = SessionStorage.InMemory,
        credentials: CredentialsProvider? = null,
        now: Instant = UnitBackend.now,
    ): SupabaseContext = SupabaseContext.create(
        configuration, storage, server.engine, ownsEngine = false, now = { now }, credentials = credentials,
    )

    /** Services with the real Auth session (none: signed out) and a recording server. */
    fun signedOutServices(server: FakeServer): AppServices = SupabaseBackend.services(context(server))
}

/** Expects [body] to throw exactly [expected]. */
internal fun <T> assertThrows(expected: AppError, body: suspend () -> T) {
    val result = try {
        runBlocking { body() }
    } catch (error: AppError) {
        assertEquals(expected, error)
        return
    }
    fail("expected $expected, got success $result")
}
