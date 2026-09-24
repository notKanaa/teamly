package io.github.notkanaa.equipe.contract

import io.github.notkanaa.equipe.core.AppServices
import io.github.notkanaa.equipe.core.AuthService
import io.github.notkanaa.equipe.core.AuthUser
import io.github.notkanaa.equipe.core.GroupService
import io.github.notkanaa.equipe.core.ProfileService
import io.github.notkanaa.equipe.core.PushService
import io.github.notkanaa.equipe.core.RealtimeService
import io.github.notkanaa.equipe.core.TaskService
import java.util.UUID

/**
 * A backend under test (in-memory mocks, or the Supabase adapters against a real server). Port of Swift
 * `ContractHarness`.
 *
 * Scenarios only use [makeUser] plus the public service API, so they run unchanged against any backend: they create
 * their own fresh users and groups, never rely on seed data and never travel in time.
 *
 * Implementing a harness:
 * - [makeUser] signs up a brand-new account (unique e-mail, e-mail confirmation disabled) on a new client session
 *   ("device") of its own, and returns it signed in. The display name must be stored as given.
 * - Timestamps must come from the backend: scenarios compare server timestamps with each other only (e.g.
 *   `assignments(since = previousEvent.assignedAt)` must exclude that event, so adapters must send `since` with full
 *   precision).
 * - Realtime scenarios subscribe through `ContractUser.subscribe`: it waits for `Connected`, then flushes the stream
 *   through a barrier group (changes committed before the subscription can arrive after `Connected` on a real
 *   server). Expected events are then awaited with a bounded wait ([StreamProbe], 10 s by default); absence is
 *   checked between a mark and a later flush. Rate limiting and password recovery are backend-specific tests.
 * - Errors are exact, including the precedences decided by the lead (unknown group → `NotFound` for rename/delete,
 *   `Forbidden` for the other admin RPCs; non-members read empty lists).
 * - Adapters validate input with `InputValidation` before calling the server (sign-up e-mail, password and display
 *   name; U+0000 in text fields), as the mocks do.
 *
 * Scenarios are plain suspend functions with no test-framework dependency. Run them with real time (e.g.
 * `runBlocking`): [StreamProbe] waits on the wall clock.
 */
interface ContractHarness {
    /** Creates a brand-new account (unique e-mail) with this display name and returns it signed in. */
    suspend fun makeUser(displayName: String): ContractUser
}

/** A signed-in user and the services of its own client session ("device"). */
class ContractUser(
    val authUser: AuthUser,
    /** The display name given at sign-up. */
    val displayName: String,
    /** E-mail and password of the account (auth scenarios sign out and back in). */
    val email: String,
    val password: String,
    val services: AppServices,
) {
    val id: UUID get() = authUser.id
    val auth: AuthService get() = services.auth
    val profiles: ProfileService get() = services.profiles
    val groups: GroupService get() = services.groups
    val tasks: TaskService get() = services.tasks
    val realtime: RealtimeService get() = services.realtime
    val push: PushService get() = services.push

    override fun toString(): String = "ContractUser($displayName, $id)"
}

/** One backend-agnostic behaviour check derived from docs/CONTRACTS.md. */
class ContractScenario(
    val name: String,
    private val body: suspend (ContractHarness) -> Unit,
) {
    /** Runs the scenario; a failed expectation throws [ContractFailure]. */
    suspend fun run(harness: ContractHarness) {
        body(harness)
    }

    override fun toString(): String = name
}

/** Every contract scenario. Run each one with a fresh harness (or at least fresh users, which they create). */
object ContractScenarios {
    val all: List<ContractScenario> by lazy {
        authScenarios +
            profileScenarios +
            groupScenarios +
            memberScenarios +
            matrixScenarios +
            taskScenarios +
            readScenarios +
            realtimeScenarios +
            pushScenarios +
            accountScenarios
    }

    /** The scenario called [name], or null. */
    fun named(name: String): ContractScenario? = all.firstOrNull { it.name == name }
}
