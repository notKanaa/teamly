package io.github.notkanaa.equipe.supabase

import io.github.notkanaa.equipe.core.AppError
import io.ktor.client.HttpClient
import io.ktor.client.request.header
import io.ktor.client.request.request
import io.ktor.client.request.setBody
import io.ktor.client.statement.bodyAsBytes
import io.ktor.content.ByteArrayContent
import io.ktor.http.ContentType
import io.ktor.http.HttpHeaders
import io.ktor.http.HttpMethod
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import java.util.UUID
import kotlin.coroutines.cancellation.CancellationException

/** The signed-in user of a client session and a valid access token. */
internal data class Credentials(val userId: UUID, val accessToken: String) {
    override fun toString(): String = "Credentials(userId=$userId, accessToken=…)"
}

/** Provides the credentials of the current session; throws [AppError.NotAuthenticated] when signed out. */
internal interface CredentialsProvider {
    suspend fun credentials(): Credentials

    /**
     * The server refused [rejected] although its local expiry had not passed (signing key rotated, device clock behind,
     * account deleted): refreshes the session and returns the new credentials. When the session cannot be refreshed
     * (revoked, account deleted), the session is removed (the client signs out) and [AppError.NotAuthenticated] is
     * thrown; offline, [AppError.Network].
     */
    suspend fun refreshedCredentials(rejected: Credentials): Credentials
}

/** One PostgREST answer, before error mapping. */
internal class RestResponse(val status: Int, val body: ByteArray) {
    val isSuccess: Boolean get() = status in 200..299

    /** The mapped error of a non-2xx answer, null for a success. */
    val error: AppError? by lazy { if (isSuccess) null else SupabaseErrorMapping.postgrest(status, body) }

    /**
     * The server refused the session of the request: HTTP 401 (token refused by PostgREST) or `not_authenticated`
     * (token accepted, but its account no longer exists). Nothing was written.
     */
    val refusesTheSession: Boolean get() = error == AppError.NotAuthenticated

    /** `not_authenticated` raised by our SQL with an accepted token: the account of the token no longer exists. */
    val accountIsGone: Boolean get() = status != 401 && refusesTheSession

    /** The body of a 2xx answer; the mapped error otherwise. */
    fun data(): ByteArray {
        error?.let { throw it }
        return body
    }
}

/**
 * Minimal PostgREST client (port of RestClient.swift): the adapters build every request themselves ([RestQuery]) so
 * that the query strings are exactly those of docs/CONTRACTS.md §4.3 and the HTTP status of an error reaches
 * [io.github.notkanaa.equipe.core.BackendErrorMapper] (401 vs 403 matters for `42501`).
 *
 * @param projectUrl `<project>` (`/rest/v1` is appended).
 * @param http a Ktor client without default request settings (tests plug a mock engine).
 */
internal class RestClient(
    projectUrl: String,
    private val apiKey: String,
    private val http: HttpClient,
    val session: CredentialsProvider,
) {
    /** `<project>/rest/v1`. */
    val restUrl: String = projectUrl.trimEnd('/') + "/rest/v1"

    /** The current session's credentials ([AppError.NotAuthenticated] when there is none). */
    suspend fun credentials(): Credentials = session.credentials()

    /**
     * Sends the request built for the current session and returns the body of a 2xx answer.
     *
     * When the server refuses the session ([RestResponse.refusesTheSession]), the session is refreshed once and the
     * request sent again with the new token: a token refused before its local expiry (signing key rotated, clock
     * behind) is replaced, and a dead session (revoked, account deleted) fails to refresh, which signs the device out
     * instead of leaving the app « signed in » with every call failing until the token expires.
     */
    suspend fun send(build: (Credentials) -> RestRequest): ByteArray {
        val credentials = credentials()
        val first = response(build(credentials), credentials)
        if (!first.refusesTheSession) return first.data()
        val fresh = session.refreshedCredentials(credentials)
        return response(build(fresh), fresh).data()
    }

    /** Sends [request] once and returns the raw answer; only transport failures throw. */
    suspend fun response(request: RestRequest, credentials: Credentials): RestResponse {
        val url = request.url(restUrl)
        return try {
            val response = http.request(url) {
                method = when (request.method) {
                    RestRequest.Method.GET -> HttpMethod.Get
                    RestRequest.Method.POST -> HttpMethod.Post
                    RestRequest.Method.PATCH -> HttpMethod.Patch
                }
                header("apikey", apiKey)
                header(HttpHeaders.Authorization, "Bearer ${credentials.accessToken}")
                header(HttpHeaders.Accept, "application/json")
                request.prefer?.let { header("Prefer", it) }
                request.encodedBody()?.let {
                    setBody(ByteArrayContent(it.toByteArray(Charsets.UTF_8), ContentType.Application.Json))
                }
            }
            RestResponse(response.status.value, response.bodyAsBytes())
        } catch (error: CancellationException) {
            throw error
        } catch (error: Throwable) {
            currentCoroutineContext().ensureActive()
            throw SupabaseErrorMapping.transport(error)
        }
    }

    /** Sends and decodes the JSON answer with [decode] (any decoding failure is an unexpected answer). */
    suspend fun <T> fetch(decode: (JsonElement) -> T, build: (Credentials) -> RestRequest): T =
        RestDecoding.decode(send(build), decode)

    /** Sends and decodes a JSON array of rows, all of them (an unknown enum value fails the answer). */
    suspend fun <T> fetchAll(decodeRow: (JsonObject) -> T, build: (Credentials) -> RestRequest): List<T> =
        fetch({ element ->
            val array = element as? JsonArray ?: throw MalformedAnswer("expected an array")
            array.map { decodeRow(it.asObject("row")) }
        }, build)

    /**
     * Sends and decodes a JSON array, leaving out the rows with a value this client does not know
     * ([RestDecoding.decodeRows]): a newer server must not make a whole list unreadable.
     */
    suspend fun <T> fetchRows(decodeRow: (JsonObject) -> T, build: (Credentials) -> RestRequest): List<T> =
        RestDecoding.decodeRows(send(build), decodeRow)
}
