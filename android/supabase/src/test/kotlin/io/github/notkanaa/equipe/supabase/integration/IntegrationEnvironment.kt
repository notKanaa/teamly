package io.github.notkanaa.equipe.supabase.integration

import io.github.notkanaa.equipe.contract.ContractFailure
import io.github.notkanaa.equipe.contract.ContractHarness
import io.github.notkanaa.equipe.contract.ContractUser
import io.github.notkanaa.equipe.core.AppError
import io.github.notkanaa.equipe.core.AppServices
import io.github.notkanaa.equipe.core.SignUpOutcome
import io.github.notkanaa.equipe.supabase.SessionStorage
import io.github.notkanaa.equipe.supabase.SupabaseBackend
import io.github.notkanaa.equipe.supabase.SupabaseConfiguration
import io.github.notkanaa.equipe.supabase.SupabaseContext
import io.ktor.client.engine.HttpClientEngine
import io.ktor.client.engine.okhttp.OkHttp
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.junit.Assert.assertEquals
import org.junit.Assert.fail
import org.junit.Assume
import java.util.UUID
import java.util.concurrent.CopyOnWriteArrayList
import kotlin.time.Duration

/**
 * Settings of the integration tests, from the environment: `SUPABASE_URL`, `SUPABASE_KEY` (publishable key) and
 * `MAILPIT_URL` (password recovery e-mails). Without `SUPABASE_URL`/`SUPABASE_KEY` every integration test is skipped.
 */
internal object IntegrationEnvironment {
    private fun variable(name: String): String? = System.getenv(name)?.trim()?.takeIf { it.isNotEmpty() }

    val configuration: SupabaseConfiguration? = run {
        val url = variable("SUPABASE_URL") ?: return@run null
        val key = variable("SUPABASE_KEY") ?: return@run null
        SupabaseConfiguration(url, key)
    }

    val mailpitUrl: String? = variable("MAILPIT_URL")?.trimEnd('/')

    /** One OkHttp engine for every test device: bounded threads and connections. */
    val engine: HttpClientEngine by lazy { OkHttp.create() }

    const val PASSWORD = "motdepasse-it-2026"

    /** Skips the calling test unless the local stack is configured. */
    fun assumeConfigured() {
        Assume.assumeTrue("SUPABASE_URL / SUPABASE_KEY are not set", configuration != null)
    }

    fun requireConfiguration(): SupabaseConfiguration =
        configuration ?: throw ContractFailure("SUPABASE_URL / SUPABASE_KEY are not set")

    /** A fresh, unique e-mail address (the local stack does not check domains). */
    fun uniqueEmail(prefix: String = "it"): String = "$prefix-${UUID.randomUUID().toString().take(13)}@example.com"

    /** Runs an integration test body with real time, a bound, and the devices it created closed at the end. */
    fun run(timeout: Duration, body: suspend (Devices) -> Unit) {
        assumeConfigured()
        runBlocking {
            val devices = Devices()
            try {
                withTimeout(timeout) { body(devices) }
            } finally {
                devices.closeAll()
            }
        }
    }
}

/** The client sessions (« devices ») of one test, each with its own Auth session and Realtime socket. */
internal class Devices {
    private val contexts = CopyOnWriteArrayList<SupabaseContext>()

    /** A new client session with its own in-memory session. */
    fun newContext(): SupabaseContext = SupabaseContext.create(
        IntegrationEnvironment.requireConfiguration(),
        SessionStorage.InMemory,
        IntegrationEnvironment.engine,
        ownsEngine = false,
    ).also { contexts.add(it) }

    fun newServices(): AppServices = SupabaseBackend.services(newContext())

    suspend fun closeAll() {
        for (context in contexts) {
            try {
                context.close()
            } catch (error: CancellationException) {
                throw error
            } catch (error: Exception) {
                // Best effort.
            }
        }
        contexts.clear()
    }
}

/**
 * Runs the backend-agnostic contract scenarios against the Supabase adapters and a real local stack. `makeUser` signs
 * up a brand-new `it-…@example.com` account through the adapter, on a client session of its own.
 */
internal class SupabaseHarness(private val devices: Devices) : ContractHarness {
    override suspend fun makeUser(displayName: String): ContractUser = signUp(displayName, devices.newServices())

    companion object {
        suspend fun signUp(displayName: String, services: AppServices): ContractUser {
            val email = IntegrationEnvironment.uniqueEmail()
            val password = IntegrationEnvironment.PASSWORD
            val outcome = services.auth.signUp(email, password, displayName)
            val user = services.auth.currentUser()
            if (outcome != SignUpOutcome.SIGNED_IN || user == null) {
                throw ContractFailure("sign-up of $email did not open a session ($outcome)")
            }
            return ContractUser(user, displayName, email, password, services)
        }
    }
}

/** Expects [body] to throw exactly [expected]. */
internal suspend fun expectError(expected: AppError, body: suspend () -> Any?) {
    val result = try {
        body()
    } catch (error: AppError) {
        assertEquals(expected, error)
        return
    }
    fail("expected $expected, got success $result")
}
