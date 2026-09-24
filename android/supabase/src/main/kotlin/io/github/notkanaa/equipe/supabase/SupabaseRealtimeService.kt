package io.github.notkanaa.equipe.supabase

import io.github.jan.supabase.annotations.SupabaseInternal
import io.github.jan.supabase.auth.status.SessionStatus
import io.github.jan.supabase.realtime.HasRecord
import io.github.jan.supabase.realtime.PostgresJoinConfig
import io.github.jan.supabase.realtime.Realtime
import io.github.jan.supabase.realtime.RealtimeCallbackId
import io.github.jan.supabase.realtime.RealtimeChannel
import io.github.jan.supabase.realtime.RealtimeSystemPayload
import io.github.jan.supabase.realtime.channel
import io.github.notkanaa.equipe.core.RealtimeEvent
import io.github.notkanaa.equipe.core.RealtimeService
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.channels.ProducerScope
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.buffer
import kotlinx.coroutines.flow.channelFlow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull
import kotlinx.serialization.json.JsonObject
import java.util.UUID
import java.util.concurrent.atomic.AtomicBoolean
import kotlin.coroutines.cancellation.CancellationException
import kotlin.math.min
import kotlin.math.pow
import kotlin.time.Duration
import kotlin.time.Duration.Companion.seconds

/**
 * [RealtimeService] on supabase-kt Realtime (docs/CONTRACTS.md §6). Port of SupabaseRealtimeService.swift.
 *
 * Every [events] collection opens its own channel with the three bindings of §6 and emits [RealtimeEvent.Connected] on
 * the `system` message that confirms the Postgres subscription (not on the join reply). Socket losses are handled by
 * supabase-kt, which reconnects and re-joins the channel (→ a new `system` ok → `Connected`). A channel that stays
 * unsubscribed (closed by the server, rejoin attempts exhausted, network down) is dropped and a new one is subscribed
 * after a backoff, which emits `Connected` again. Refreshed access tokens are passed to the Realtime client (`setAuth`)
 * so the channel survives the JWT expiry. Nothing is subscribed while signed out. The flow neither ends nor fails by
 * itself; the channel is removed when the collector is cancelled.
 *
 * Unlike supabase-swift, supabase-kt handles a `system` error itself (it re-joins the channel, up to 5 attempts): the
 * adapter only sees the channel status, and replaces a channel left unsubscribed.
 */
internal class SupabaseRealtimeService(private val context: SupabaseContext) : RealtimeService {
    override fun events(userId: UUID, groupIds: List<UUID>): Flow<RealtimeEvent> {
        val bindings = RealtimeBindings(userId, groupIds)
        return channelFlow { RealtimeChannelRunner(context, bindings, this).run() }.buffer(Channel.UNLIMITED)
    }
}

/** The three bindings of docs/CONTRACTS.md §6 for one user. */
internal class RealtimeBindings(userId: UUID, groupIds: List<UUID>) {
    /** At most [MAX_GROUP_IDS] distinct ids (the first ones given), lower case. */
    val groupIds: List<String> = groupIds.take(MAX_GROUP_IDS).distinct().map(RestQuery::uuid)

    val me: String = RestQuery.uuid(userId)

    /** UPDATE `public.groups`, `id=in.(…)` (`in.()` when empty). */
    val groupsFilter: String get() = "id=in.(" + groupIds.joinToString(",") + ")"

    /** UPDATE `public.profiles`, `id=eq.<me>`. */
    val profilesFilter: String get() = "id=eq.$me"

    /** INSERT `public.task_assignees`, `user_id=eq.<me>`. */
    val assigneesFilter: String get() = "user_id=eq.$me"

    /** What a `system` message means for the Postgres subscription. */
    enum class SystemStatus {
        /** "Subscribed to PostgreSQL": the bindings are active → `Connected`. */
        SUBSCRIBED,

        /** The subscription failed (or the channel is being shut down by the server). */
        FAILED,

        /** Unrelated to the Postgres subscription. */
        OTHER,
    }

    companion object {
        /** The server fails the whole channel at ~70 ids in one `in` filter. */
        const val MAX_GROUP_IDS = 60

        /** `groups` UPDATE record → `GroupActivity`. */
        fun groupActivity(record: JsonObject): RealtimeEvent? =
            uuid(record, "id")?.let { RealtimeEvent.GroupActivity(it) }

        /** `task_assignees` INSERT record → `Assigned` (`assigned_by` may be NULL). */
        fun assigned(record: JsonObject): RealtimeEvent? {
            val taskId = uuid(record, "task_id") ?: return null
            val groupId = uuid(record, "group_id") ?: return null
            return RealtimeEvent.Assigned(taskId, groupId, uuid(record, "assigned_by"))
        }

        private fun uuid(record: JsonObject, key: String): UUID? = record[key].stringValue()?.let(::parseUuidOrNull)

        fun systemStatus(status: String?, extension: String?): SystemStatus = when (status) {
            "ok" -> if (extension == null || extension == "postgres_changes") SystemStatus.SUBSCRIBED else SystemStatus.OTHER
            "error" -> SystemStatus.FAILED
            else -> SystemStatus.OTHER
        }
    }
}

/** One [SupabaseRealtimeService.events] collection: subscribes, watches the channel, re-subscribes after failures. */
@OptIn(SupabaseInternal::class)
private class RealtimeChannelRunner(
    private val context: SupabaseContext,
    private val bindings: RealtimeBindings,
    private val output: ProducerScope<RealtimeEvent>,
) {
    suspend fun run(): Unit = coroutineScope {
        launch { propagateTokens() }
        var failures = 0
        while (true) {
            // A signed-out client receives nothing: wait for a session instead of joining as anon.
            context.auth.sessionStatus.first { it is SessionStatus.Authenticated }
            val reachedConnected = subscribeOnce()
            failures = if (reachedConnected) 1 else failures + 1
            delay(backoff(failures))
        }
    }

    /**
     * Token propagation (§6: `setAuth` on refresh). supabase-kt does the same for connected sockets; done here too
     * because the channel depends on it. A token already sent is not sent again.
     */
    private suspend fun propagateTokens() {
        var last: String? = null
        context.auth.sessionStatus.collect { status ->
            val token = (status as? SessionStatus.Authenticated)?.session?.accessToken ?: return@collect
            if (token == last) return@collect
            last = token
            try {
                context.realtime.setAuth(token)
            } catch (error: CancellationException) {
                throw error
            } catch (error: Exception) {
                // A token supabase-kt cannot read: the next join resolves the session token itself.
            }
        }
    }

    /**
     * Subscribes one channel and returns when it failed (or the collector was cancelled). True if it reached
     * `Connected` at least once.
     */
    private suspend fun subscribeOnce(): Boolean {
        val realtime = context.realtime
        // Connect before registering the channel: a socket reconnection re-joins every registered channel, and a
        // channel registered while the client waits for its socket would then be joined twice (the server closes the
        // first join, which supabase-kt applies to the channel).
        if (realtime.status.value != Realtime.Status.CONNECTED) {
            realtime.connect()
            realtime.status.first { it == Realtime.Status.CONNECTED }
        }
        val channel = realtime.channel("equipe:${bindings.me}:${UUID.randomUUID()}")
        val connected = AtomicBoolean(false)
        val failed = CompletableDeferred<Unit>()
        val manager = channel.callbackManager

        val groups = PostgresJoinConfig(schema = "public", table = "groups", filter = bindings.groupsFilter, event = "UPDATE")
        val profiles = PostgresJoinConfig(schema = "public", table = "profiles", filter = bindings.profilesFilter, event = "UPDATE")
        val assignees = PostgresJoinConfig(
            schema = "public", table = "task_assignees", filter = bindings.assigneesFilter, event = "INSERT",
        )
        val configs = listOf(groups, profiles, assignees)
        // Callbacks run synchronously in message order on one coroutine of the Realtime client, into one unlimited
        // buffer: events keep the commit order, and `Connected` precedes the changes it enables.
        val callbacks: List<RealtimeCallbackId> = listOf(
            manager.addPostgresCallback(groups) { action ->
                (action as? HasRecord)?.let { RealtimeBindings.groupActivity(it.record) }?.let(::emit)
            },
            manager.addPostgresCallback(profiles) { emit(RealtimeEvent.MembershipsChanged) },
            manager.addPostgresCallback(assignees) { action ->
                (action as? HasRecord)?.let { RealtimeBindings.assigned(it.record) }?.let(::emit)
            },
            manager.addSystemCallback { payload: RealtimeSystemPayload ->
                when (RealtimeBindings.systemStatus(payload.status, payload.extension)) {
                    RealtimeBindings.SystemStatus.SUBSCRIBED -> {
                        connected.set(true)
                        emit(RealtimeEvent.Connected)
                    }
                    RealtimeBindings.SystemStatus.FAILED -> failed.complete(Unit)
                    RealtimeBindings.SystemStatus.OTHER -> Unit
                }
            },
        )
        for (config in configs) {
            with(channel) { addPostgresChange(config) }
        }

        try {
            coroutineScope {
                // Suspends while the client has no socket (offline): the channel is only watched once it is joining.
                channel.subscribe(blockUntilSubscribed = false)
                val watcher = launch {
                    waitUntilLost(channel)
                    failed.complete(Unit)
                }
                failed.await()
                watcher.cancel()
            }
        } catch (error: CancellationException) {
            throw error
        } catch (error: Exception) {
            // The client failed to subscribe (e.g. its socket was closed at that moment): retried after the backoff.
            // The flow itself never fails.
        } finally {
            for (id in callbacks) manager.removeCallbackById(id)
            for (config in configs) {
                with(channel) { removePostgresChange(config) }
            }
            withContext(NonCancellable) {
                withTimeoutOrNull(REMOVE_TIMEOUT) { remove(channel) }
            }
        }
        return connected.get()
    }

    /**
     * Leaves and forgets [channel]; never throws. supabase-kt's `removeChannel` only leaves a subscribed channel, and
     * fails when the client has no socket at that moment (signed out, disconnected): the channel is then forgotten
     * locally, so that a later reconnection does not re-join it.
     */
    private suspend fun remove(channel: RealtimeChannel) {
        val realtime = context.realtime
        try {
            if (channel.status.value == RealtimeChannel.Status.SUBSCRIBING) channel.unsubscribe()
            realtime.removeChannel(channel)
        } catch (error: CancellationException) {
            throw error
        } catch (error: Exception) {
            channel.updateStatus(RealtimeChannel.Status.UNSUBSCRIBED)
            try {
                realtime.removeChannel(channel)
            } catch (error: CancellationException) {
                throw error
            } catch (error: Exception) {
                // Nothing else to release.
            }
        }
    }

    private fun emit(event: RealtimeEvent) {
        output.trySend(event)
    }

    /**
     * Returns once the channel has been unsubscribed for [UNSUBSCRIBED_GRACE] in a row: closed by the server, rejoin
     * attempts exhausted, or a socket that supabase-kt could not reconnect meanwhile.
     */
    private suspend fun waitUntilLost(channel: RealtimeChannel) {
        while (true) {
            channel.status.first { it.isDown }
            delay(UNSUBSCRIBED_GRACE)
            if (channel.status.value.isDown) return
        }
    }

    private val RealtimeChannel.Status.isDown: Boolean
        get() = this == RealtimeChannel.Status.UNSUBSCRIBED || this == RealtimeChannel.Status.UNSUBSCRIBING

    private companion object {
        /**
         * A channel left unsubscribed this long (not re-joined by supabase-kt) is replaced. supabase-kt reconnects a
         * lost socket after 7 s, then re-joins: the grace leaves it time to do so.
         */
        val UNSUBSCRIBED_GRACE: Duration = 15.seconds

        val REMOVE_TIMEOUT: Duration = 5.seconds

        /** 1 s after a channel that worked, then doubling up to 30 s while subscriptions keep failing. */
        fun backoff(failures: Int): Duration = min(30.0, 2.0.pow((failures - 1).toDouble())).seconds
    }
}
