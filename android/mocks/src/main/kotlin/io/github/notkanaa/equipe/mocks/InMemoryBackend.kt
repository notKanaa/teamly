package io.github.notkanaa.equipe.mocks

import io.github.notkanaa.equipe.core.AppCalendar
import io.github.notkanaa.equipe.core.AppError
import io.github.notkanaa.equipe.core.AppServices
import io.github.notkanaa.equipe.core.AuthState
import io.github.notkanaa.equipe.core.AuthUser
import io.github.notkanaa.equipe.core.InputValidation
import io.github.notkanaa.equipe.core.NowProvider
import io.github.notkanaa.equipe.core.RealtimeEvent
import io.github.notkanaa.equipe.core.SignUpOutcome
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.channels.SendChannel
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.emitAll
import kotlinx.coroutines.flow.flow
import java.time.Instant
import java.util.UUID
import kotlin.time.Duration
import kotlin.time.Duration.Companion.hours
import kotlin.time.toKotlinDuration

/**
 * In-memory backend reproducing the SQL backend of docs/CONTRACTS.md: Auth, PostgREST reads, RPCs, the permission
 * matrix, the change signals and Realtime. Used by previews, UI tests and unit tests (port of Swift
 * `InMemoryBackend`).
 *
 * Several "devices" can act on the same backend: [services] returns an [AppServices] bound to its own session.
 * Every access goes through one lock; a write runs on a copy of the data and is committed only if it succeeds (like a
 * Postgres transaction). Realtime events are delivered while the lock is held, so every subscriber receives them in
 * commit order. The flows returned by `events()` and `authStates()` are cold (collecting subscribes and emits the
 * current state / `Connected` at once, cancelling the collector unsubscribes) and never complete by themselves.
 *
 * Every service call first waits for [latency] (zero by default), then runs synchronously: with zero latency, a call
 * never suspends. Coroutine cancellation during the latency propagates as `CancellationException`.
 *
 * @param now the backend's clock (its `now()`), e.g. a [MockClock.provider].
 * @param calendar calendar of the demo dates (Europe/Paris by default).
 * @param latency artificial latency of every service call (previews). Zero by default.
 */
class InMemoryBackend(
    now: NowProvider = { Instant.now() },
    val calendar: AppCalendar = DemoData.calendar,
    val latency: Duration = Duration.ZERO,
) {
    private val nowProvider: NowProvider = now
    private val lock = Any()

    // Guarded by `lock`.
    private var data = BackendData()
    private val sessions = HashMap<UUID, SessionRecord>()
    private val subscribers = HashMap<UUID, RealtimeSubscriber>()

    private class SessionRecord(var userId: UUID?) {
        val authSubscribers = LinkedHashMap<UUID, SendChannel<AuthState>>()
    }

    private class RealtimeSubscriber(
        /** Client whose session authorizes the channel (RLS of the session user, nothing when signed out). */
        val clientId: UUID,
        /** User of the filters (`user_id=eq.<userId>`, `id=eq.<userId>`). */
        val userId: UUID,
        val groupIds: Set<UUID>,
        val channel: SendChannel<RealtimeEvent>,
    )

    /** The backend's current date (its `now()`). */
    fun now(): Instant = nowProvider()

    // region Clients

    /** A new client ("device") with its own session, signed in as [userId] (or signed out when null). */
    fun services(userId: UUID?): AppServices {
        val clientId = UUID.randomUUID()
        withLock { sessions[clientId] = SessionRecord(userId) }
        val session = MockSession(this, clientId)
        return AppServices(
            auth = MockAuthService(session),
            profiles = MockProfileService(session),
            groups = MockGroupService(session),
            tasks = MockTaskService(session),
            realtime = MockRealtimeService(session),
            push = MockPushService(session),
        )
    }

    // endregion

    // region Test & demo helpers

    /** Creates an account (and its profile) directly, without opening a session. */
    fun createAccount(email: String, password: String, displayName: String, id: UUID = UUID.randomUUID()): AuthUser {
        val input = InputValidation.signUp(email, password, displayName)
        return withLock {
            if (data.account(input.email) != null || data.accounts[id] != null) throw AppError.EmailAlreadyUsed
            insertAccountLocked(id, input.email, password, input.displayName, nowProvider())
            AuthUser(id = id, email = input.email)
        }
    }

    /** The id of the account registered with [forEmail] (trimmed and lowercased first), if any. */
    fun userId(forEmail: String): UUID? = withLock { data.account(InputRules.normalizedEmail(forEmail))?.id }

    /** The pending recovery code sent to [email] (what the user would read in the e-mail), if any. */
    fun pendingRecoveryCode(email: String): String? = withLock {
        val account = data.account(InputRules.normalizedEmail(email)) ?: return@withLock null
        data.recoveries[account.id]?.code
    }

    /** Number of live Realtime subscriptions (tests). */
    val realtimeSubscriberCount: Int get() = withLock { subscribers.size }

    /** Adds the demo data of docs/CONTRACTS.md §8, with dates relative to the backend's current [now]. */
    fun loadDemoData() {
        val reference = now()
        seed { DemoData.seed(it, reference, calendar) }
    }

    /** Adds [DemoData.newcomer] (an account with no group). */
    fun addNewcomerAccount() {
        val reference = now()
        seed { DemoData.insert(DemoData.newcomer, it, reference) }
    }

    /** Seeds data directly (no signals). Used by [DemoData]. */
    internal fun seed(body: (BackendData) -> Unit) {
        withLock { body(data) }
    }

    // endregion

    // region Latency

    internal suspend fun simulateLatency() {
        if (latency > Duration.ZERO) delay(latency)
    }

    // endregion

    // region Locking primitives

    private inline fun <R> withLock(body: () -> R): R = synchronized(lock) { body() }

    /** Must be called with the lock held. */
    private fun sessionUserLocked(clientId: UUID): UUID {
        val userId = sessions[clientId]?.userId
        if (userId == null || data.accounts[userId] == null) throw AppError.NotAuthenticated
        return userId
    }

    /** Reads as the session user of [clientId]. */
    internal fun <R> read(clientId: UUID, body: (BackendData, UUID) -> R): R = withLock {
        val me = sessionUserLocked(clientId)
        body(data, me)
    }

    /**
     * Runs a write transaction as the session user of [clientId]. Nothing is committed if [body] throws.
     *
     * A session whose account no longer exists (deleted on another device) is ended, like the Supabase adapter does
     * when the server answers `not_authenticated` and the session cannot be refreshed: the client's `authStates()`
     * emit [AuthState.SignedOut], then [AppError.NotAuthenticated] is thrown.
     */
    internal fun <R> write(clientId: UUID, body: (Transaction, UUID) -> R): R = withLock {
        if (endStaleSessionLocked(clientId)) throw AppError.NotAuthenticated
        val me = sessionUserLocked(clientId)
        val transaction = Transaction(data.copy(), nowProvider())
        val result = body(transaction, me)
        commitLocked(transaction)
        result
    }

    private fun commitLocked(transaction: Transaction) {
        transaction.finish()
        data = transaction.data
        deliverLocked(transaction)
    }

    private fun insertAccountLocked(id: UUID, email: String, password: String, displayName: String, now: Instant) {
        data.accounts[id] = AccountRecord(id = id, email = email, password = password, createdAt = now)
        // The `handle_new_user` trigger creates the profile.
        data.profiles[id] = ProfileRecord(
            id = id, displayName = displayName, membershipsChangedAt = now, createdAt = now, updatedAt = now,
        )
    }

    // endregion

    // region Realtime (docs/CONTRACTS.md §6)

    internal fun subscribe(clientId: UUID, userId: UUID, groupIds: List<UUID>): Flow<RealtimeEvent> = flow {
        val channel = Channel<RealtimeEvent>(Channel.UNLIMITED)
        val subscriptionId = UUID.randomUUID()
        withLock {
            subscribers[subscriptionId] = RealtimeSubscriber(
                clientId = clientId,
                userId = userId,
                groupIds = groupIds.take(maxRealtimeGroups).toSet(),
                channel = channel,
            )
            channel.trySend(RealtimeEvent.Connected)
        }
        try {
            emitAll(channel)
        } finally {
            withLock { subscribers.remove(subscriptionId) }
        }
    }

    /**
     * Mirrors the three Realtime bindings: filters use the subscription's `userId`, visibility follows the RLS of
     * the client's current session user (the channel's token), evaluated after the commit. Signed out (anon role,
     * no policy), nothing is delivered.
     */
    private fun deliverLocked(transaction: Transaction) {
        if (subscribers.isEmpty()) return
        val activity = transaction.groupActivity
        val profileUpdates = transaction.profileUpdates
        // A snapshot: an unconfined collector may run inline inside `trySend`.
        for (subscriber in subscribers.values.toList()) {
            val viewer = sessions[subscriber.clientId]?.userId ?: continue
            if (data.accounts[viewer] == null) continue
            // groups SELECT: member of the group.
            for (groupId in activity) {
                if (groupId in subscriber.groupIds && data.isMember(viewer, groupId)) {
                    subscriber.channel.trySend(RealtimeEvent.GroupActivity(groupId))
                }
            }
            // profiles SELECT: self or co-member.
            if (subscriber.userId in profileUpdates && data.canSeeProfile(subscriber.userId, viewer)) {
                subscriber.channel.trySend(RealtimeEvent.MembershipsChanged)
            }
            // task_assignees SELECT: member of the group.
            for (row in transaction.insertedAssignments) {
                if (row.userId == subscriber.userId && data.isMember(viewer, row.groupId)) {
                    subscriber.channel.trySend(RealtimeEvent.Assigned(row.taskId, row.groupId, row.assignedBy))
                }
            }
        }
    }

    // endregion

    // region Auth

    private fun authStateLocked(clientId: UUID): AuthState {
        val userId = sessions[clientId]?.userId ?: return AuthState.SignedOut
        val user = data.authUser(userId) ?: return AuthState.SignedOut
        return AuthState.SignedIn(user)
    }

    /** Ends the session of [clientId] if its account no longer exists (its subscribers last saw SignedIn). */
    private fun endStaleSessionLocked(clientId: UUID): Boolean {
        val session = sessions[clientId] ?: return false
        val userId = session.userId ?: return false
        if (data.accounts[userId] != null) return false
        session.userId = null
        for (channel in session.authSubscribers.values.toList()) channel.trySend(AuthState.SignedOut)
        return true
    }

    /** Changes the session of a client and notifies its `authStates()` subscribers if the state changed. */
    private fun setSessionLocked(clientId: UUID, userId: UUID?) {
        val before = authStateLocked(clientId)
        sessions.getOrPut(clientId) { SessionRecord(null) }.userId = userId
        val after = authStateLocked(clientId)
        if (after == before) return
        for (channel in sessions[clientId]?.authSubscribers?.values?.toList().orEmpty()) channel.trySend(after)
    }

    internal fun authStates(clientId: UUID): Flow<AuthState> = flow {
        val channel = Channel<AuthState>(Channel.UNLIMITED)
        val subscriptionId = UUID.randomUUID()
        withLock {
            sessions.getOrPut(clientId) { SessionRecord(null) }.authSubscribers[subscriptionId] = channel
            channel.trySend(authStateLocked(clientId))
        }
        try {
            emitAll(channel)
        } finally {
            withLock { sessions[clientId]?.authSubscribers?.remove(subscriptionId) }
        }
    }

    internal fun currentUser(clientId: UUID): AuthUser? = withLock { authStateLocked(clientId).user }

    /**
     * Validates like the Supabase adapter does before calling Auth (`InputValidation.signUp`): Supabase Auth alone
     * would accept a blank or too long display name.
     */
    internal fun signUp(clientId: UUID, email: String, password: String, displayName: String): SignUpOutcome {
        val input = InputValidation.signUp(email, password, displayName)
        withLock {
            if (data.account(input.email) != null) throw AppError.EmailAlreadyUsed
            val id = UUID.randomUUID()
            insertAccountLocked(id, input.email, password, input.displayName, nowProvider())
            setSessionLocked(clientId, id)
        }
        return SignUpOutcome.SIGNED_IN
    }

    internal fun signIn(clientId: UUID, email: String, password: String) {
        withLock {
            val account = data.account(InputRules.normalizedEmail(email))
            if (account == null || account.password != password) throw AppError.InvalidCredentials
            setSessionLocked(clientId, account.id)
        }
    }

    internal fun signOut(clientId: UUID) {
        withLock { setSessionLocked(clientId, null) }
    }

    /**
     * Stores the deterministic recovery code for an existing account. Unknown e-mails succeed silently (no account
     * enumeration, like Supabase).
     */
    internal fun sendPasswordReset(email: String) {
        val normalized = InputRules.email(email)
        withLock {
            val account = data.account(normalized) ?: return@withLock
            data.recoveries[account.id] = RecoveryRecord(userId = account.id, code = recoveryCode, createdAt = nowProvider())
        }
    }

    /** A valid, unexpired code signs the client in (recovery session) and is consumed. */
    internal fun verifyRecoveryCode(clientId: UUID, email: String, code: String) {
        withLock {
            val account = data.account(InputRules.normalizedEmail(email)) ?: throw AppError.OtpInvalid
            val recovery = data.recoveries[account.id] ?: throw AppError.OtpInvalid
            if (recovery.code != InputRules.trimmed(code)) throw AppError.OtpInvalid
            if (java.time.Duration.between(recovery.createdAt, nowProvider()).toKotlinDuration() > recoveryCodeLifetime) {
                throw AppError.OtpInvalid
            }
            data.recoveries.remove(account.id)
            setSessionLocked(clientId, account.id)
        }
    }

    internal fun updatePassword(clientId: UUID, newPassword: String) {
        withLock {
            val me = sessionUserLocked(clientId)
            InputRules.password(newPassword)
            val account = data.accounts[me] ?: return@withLock
            data.accounts[me] = account.copy(password = newPassword)
        }
    }

    /**
     * `delete_my_account()`, then local sign-out of this client.
     *
     * When the session's account no longer exists (deleted by an earlier attempt whose answer was lost, or on another
     * device), the requested end state holds: the session is ended and the call succeeds, like the Supabase adapter.
     */
    internal fun deleteAccount(clientId: UUID) {
        withLock {
            if (endStaleSessionLocked(clientId)) return@withLock
            val me = sessionUserLocked(clientId)
            // Sign out first so that subscribers see SignedOut (afterwards the account no longer exists).
            setSessionLocked(clientId, null)
            val transaction = Transaction(data.copy(), nowProvider())
            transaction.deleteAccount(me)
            commitLocked(transaction)
        }
    }

    // endregion

    companion object {
        /** Password-recovery code accepted by `verifyRecoveryCode` after `sendPasswordReset` (deterministic mock). */
        const val recoveryCode: String = "123456"

        /** Lifetime of a recovery code (Supabase `otp_expiry`): a code exactly this old is still accepted. */
        val recoveryCodeLifetime: Duration = 1.hours

        /**
         * `join_group_by_code`: once the caller has this many failed attempts in the last hour, every further attempt
         * (even with a valid code) throws [AppError.RateLimited] and is not logged.
         */
        const val maxFailedJoinsPerHour: Int = 10

        /** Window of [maxFailedJoinsPerHour] (inclusive: a failure exactly this old still counts). */
        val joinRateLimitWindow: Duration = 1.hours

        const val pushTopicPrefix: String = "equipe-"

        /**
         * Group ids watched by one Realtime subscription (the first ones of the list). The real server fails the
         * whole channel from about 70 ids in one `id=in.(…)` filter (index row size limit): adapters must cap too.
         */
        const val maxRealtimeGroups: Int = 60

        /** A backend preloaded with the demo data of docs/CONTRACTS.md §8. */
        fun demo(
            now: NowProvider = { Instant.now() },
            calendar: AppCalendar = DemoData.calendar,
            latency: Duration = Duration.ZERO,
        ): InMemoryBackend {
            val backend = InMemoryBackend(now, calendar, latency)
            backend.loadDemoData()
            return backend
        }
    }
}

/** A client ("device") of the backend: the backend plus the id of its session. */
internal class MockSession(val backend: InMemoryBackend, val clientId: UUID)
