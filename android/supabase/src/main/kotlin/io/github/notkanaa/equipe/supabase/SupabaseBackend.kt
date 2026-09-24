package io.github.notkanaa.equipe.supabase

import io.github.jan.supabase.SupabaseClient
import io.github.jan.supabase.auth.Auth
import io.github.jan.supabase.auth.FlowType
import io.github.jan.supabase.auth.MemoryCodeVerifierCache
import io.github.jan.supabase.auth.auth
import io.github.jan.supabase.createSupabaseClient
import io.github.jan.supabase.logging.LogLevel
import io.github.jan.supabase.realtime.Realtime
import io.github.jan.supabase.realtime.realtime
import io.github.notkanaa.equipe.core.AppServices
import io.ktor.client.HttpClient
import io.ktor.client.engine.HttpClientEngine
import io.ktor.client.engine.okhttp.OkHttp
import io.ktor.client.plugins.HttpTimeout
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import java.net.URI
import java.net.URISyntaxException
import java.time.Instant
import java.util.Base64

/** Entry point of the Supabase adapters: builds the Core services for one client session. */
object SupabaseBackend {
    /**
     * The services of the app, backed by the Supabase project of [configuration] (supabase-kt Auth and Realtime on the
     * OkHttp engine; PostgREST requests built by the adapters). The Auth session is restored from [sessionStorage] at
     * creation and saved there on every change (sign-in, refresh, sign-out). Every call builds a new, independent client
     * session (a « device »): call it once per process.
     *
     * @throws IllegalArgumentException when [SupabaseConfiguration.url] is not an `http(s)` URL with a host (and no
     *   path): validate the configuration first.
     */
    fun makeServices(
        configuration: SupabaseConfiguration,
        sessionStorage: SessionStorage = SessionStorage.InMemory,
    ): AppServices = services(SupabaseContext.create(configuration, sessionStorage, OkHttp.create(), ownsEngine = true))

    /**
     * A Supabase key that must never ship in an app: a secret key (`sb_secret_…`), or a legacy JWT key whose `role` is
     * not `anon` (`service_role`). Publishable keys (`sb_publishable_…`) and anon JWT keys are fine. Port of
     * `SupabaseSettings.isSecretKey` (iOS app).
     */
    fun isSecretKey(key: String): Boolean {
        if (key.startsWith("sb_secret_")) return true
        val parts = key.split('.')
        if (parts.size != 3) return false
        val claims = try {
            val payload = Base64.getUrlDecoder().decode(parts[1]).toString(Charsets.UTF_8)
            Json.parseToJsonElement(payload) as? JsonObject
        } catch (error: IllegalArgumentException) { // invalid Base64 or JSON
            null
        } ?: return false
        val role = (claims["role"] as? JsonPrimitive)?.takeIf { it.isString }?.content
        return role != "anon"
    }

    internal fun services(context: SupabaseContext): AppServices = AppServices(
        auth = SupabaseAuthService(context),
        profiles = SupabaseProfileService(context),
        groups = SupabaseGroupService(context),
        tasks = SupabaseTaskService(context),
        realtime = SupabaseRealtimeService(context),
        push = SupabasePushService(context),
    )

    /** `scheme://host[:port]` of an `http(s)` URL without path, query or fragment (trailing slashes ignored). */
    internal fun projectUrl(url: String): String {
        val trimmed = url.trim().trimEnd('/')
        val uri = try {
            URI(trimmed)
        } catch (error: URISyntaxException) {
            null
        }
        require(
            uri != null && (uri.scheme == "https" || uri.scheme == "http") && !uri.host.isNullOrEmpty() &&
                uri.rawPath.isNullOrEmpty() && uri.rawQuery == null && uri.rawFragment == null && uri.rawUserInfo == null,
        ) { "SupabaseConfiguration.url must be an http(s) URL with a host and no path, e.g. https://abcdefgh.supabase.co" }
        return trimmed
    }
}

/**
 * Everything the services of one client session share: the supabase-kt client (Auth, Realtime), the PostgREST client
 * of the adapters, and the session storage.
 */
internal class SupabaseContext(
    val client: SupabaseClient,
    val sessions: StorageSessionManager,
    val rest: RestClient,
    val now: () -> Instant,
    private val restHttp: HttpClient,
    private val engine: HttpClientEngine?,
) {
    val auth: Auth get() = client.auth
    val realtime: Realtime get() = client.realtime

    /** Stops the client (Auth refresh, Realtime socket) and releases its HTTP resources (tests). */
    suspend fun close() {
        client.close()
        restHttp.close()
        engine?.close()
    }

    companion object {
        /** Request timeout of the PostgREST calls (supabase-kt uses 10 s for Auth). */
        private const val REST_TIMEOUT_MS = 30_000L

        /**
         * @param engine HTTP engine of both clients (OkHttp in the app; tests share one or plug a mock engine).
         * @param ownsEngine whether [close] also closes [engine].
         * @param credentials credentials of the PostgREST requests (unit tests); defaults to the Auth session.
         */
        fun create(
            configuration: SupabaseConfiguration,
            sessionStorage: SessionStorage,
            engine: HttpClientEngine,
            ownsEngine: Boolean,
            now: () -> Instant = { Instant.now() },
            credentials: CredentialsProvider? = null,
        ): SupabaseContext {
            val url = SupabaseBackend.projectUrl(configuration.url)
            val sessions = StorageSessionManager(sessionStorage)
            val client = createSupabaseClient(url, configuration.publishableKey) {
                httpEngine = engine
                defaultLogLevel = LogLevel.WARNING
                install(Auth) {
                    sessionManager = sessions
                    codeVerifierCache = MemoryCodeVerifierCache()
                    flowType = FlowType.IMPLICIT
                    alwaysAutoRefresh = true
                    autoLoadFromStorage = true
                    autoSaveToStorage = true
                    // supabase-kt's Android lifecycle hooks drop the session (status Initializing) whenever the app goes
                    // to the background, which would sign background work out: the refresh job simply keeps running.
                    enableLifecycleCallbacks = false
                }
                install(Realtime)
            }
            val restHttp = HttpClient(engine) {
                install(HttpTimeout) {
                    requestTimeoutMillis = REST_TIMEOUT_MS
                }
            }
            val rest = RestClient(
                projectUrl = url,
                apiKey = configuration.publishableKey,
                http = restHttp,
                session = credentials ?: AuthSessionCredentials(client.auth, sessions),
            )
            return SupabaseContext(client, sessions, rest, now, restHttp, if (ownsEngine) engine else null)
        }
    }
}
