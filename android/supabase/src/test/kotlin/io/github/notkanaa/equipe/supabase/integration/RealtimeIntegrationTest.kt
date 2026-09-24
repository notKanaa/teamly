package io.github.notkanaa.equipe.supabase.integration

import io.github.jan.supabase.annotations.SupabaseInternal
import io.github.notkanaa.equipe.contract.ContractUser
import io.github.notkanaa.equipe.contract.StreamProbe
import io.github.notkanaa.equipe.core.GroupSummary
import io.github.notkanaa.equipe.core.RealtimeEvent
import io.github.notkanaa.equipe.supabase.SupabaseBackend
import io.github.notkanaa.equipe.supabase.SupabaseContext
import kotlinx.coroutines.delay
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Test
import java.util.UUID
import kotlin.time.Duration.Companion.milliseconds
import kotlin.time.Duration.Companion.minutes
import kotlin.time.Duration.Companion.seconds
import kotlin.time.TimeSource

/**
 * Realtime resilience (docs/CONTRACTS.md §6) against the local stack (port of RealtimeIntegrationTests.swift):
 * `Connected` again after the channel or the socket is lost, events keep flowing after a token refresh.
 */
class RealtimeIntegrationTest {
    private class Subscriber(
        val context: SupabaseContext,
        val user: ContractUser,
        val group: GroupSummary,
        val probe: StreamProbe<RealtimeEvent>,
    )

    private suspend fun subscribe(devices: Devices): Subscriber {
        val context = devices.newContext()
        val user = SupabaseHarness.signUp("Temps réel", SupabaseBackend.services(context))
        val group = user.groups.createGroup("Groupe temps réel")
        val probe = StreamProbe(user.realtime.events(user.id, listOf(group.id)))
        probe.waitFor("first Connected") { it == RealtimeEvent.Connected }
        return Subscriber(context, user, group, probe)
    }

    /** A change of the subscriber's group reaches the stream. */
    private suspend fun expectActivity(subscriber: Subscriber, label: String) {
        val mark = subscriber.probe.mark()
        subscriber.user.groups.rename(subscriber.group.id, "Groupe ${UUID.randomUUID().toString().take(6)}")
        subscriber.probe.waitFor("groupActivity $label", after = mark) { it == RealtimeEvent.GroupActivity(subscriber.group.id) }
    }

    private fun Subscriber.equipeChannels() =
        context.realtime.subscriptions.values.filter { it.topic.startsWith("realtime:equipe:") }

    /**
     * A channel that is closed and not re-joined (as when the server shuts it down) is replaced by a new subscription,
     * which emits `Connected` again.
     */
    @Test
    fun resubscribesWhenTheChannelIsClosed() = IntegrationEnvironment.run(1.minutes) { devices ->
        val subscriber = subscribe(devices)
        try {
            val channels = subscriber.equipeChannels()
            assertEquals(1, channels.size)
            val channel = channels.single()

            val mark = subscriber.probe.mark()
            channel.unsubscribe()
            subscriber.probe.waitFor("Connected after the channel was closed", after = mark, timeout = 30.seconds) {
                it == RealtimeEvent.Connected
            }
            val current = subscriber.equipeChannels()
            assertEquals(1, current.size)
            assertNotEquals("a new channel replaced the closed one", channel.topic, current.single().topic)
            expectActivity(subscriber, "on the new channel")
        } finally {
            subscriber.probe.stop()
        }
    }

    /** A refreshed access token is passed to the Realtime client (`setAuth`), and the channel keeps working. */
    @Test
    fun passesRefreshedTokensToRealtime() = IntegrationEnvironment.run(1.minutes) { devices ->
        val subscriber = subscribe(devices)
        try {
            val auth = subscriber.context.auth
            val before = auth.currentAccessTokenOrNull()
            auth.refreshCurrentSession()
            val refreshed = auth.currentAccessTokenOrNull()
            assertNotEquals(before, refreshed)
            // White box: supabase-kt's RealtimeImpl.accessToken (internal class, public getter).
            val getter = subscriber.context.realtime.javaClass.getMethod("getAccessToken")
            val deadline = TimeSource.Monotonic.markNow() + 10.seconds
            while (getter.invoke(subscriber.context.realtime) != refreshed && deadline.hasNotPassedNow()) {
                delay(50.milliseconds)
            }
            assertEquals(refreshed, getter.invoke(subscriber.context.realtime))
            expectActivity(subscriber, "after a token refresh")
        } finally {
            subscriber.probe.stop()
        }
    }

    /**
     * The socket is lost (as on a network change): supabase-kt reconnects and re-joins the channel, which emits
     * `Connected` again, and events keep flowing.
     */
    @OptIn(SupabaseInternal::class)
    @Test
    fun reconnectsAfterTheSocketIsLost() = IntegrationEnvironment.run(2.minutes) { devices ->
        val subscriber = subscribe(devices)
        try {
            val mark = subscriber.probe.mark()
            subscriber.context.realtime.websocket.disconnect()
            subscriber.probe.waitFor("Connected after the socket was lost", after = mark, timeout = 45.seconds) {
                it == RealtimeEvent.Connected
            }
            expectActivity(subscriber, "after the reconnection")
        } finally {
            subscriber.probe.stop()
        }
    }

    /** `id=in.()` (no group yet) is accepted: the channel connects and delivers the user's own signals. */
    @Test
    fun subscribesWithoutAnyGroup() = IntegrationEnvironment.run(1.minutes) { devices ->
        val user = SupabaseHarness(devices).makeUser("Sans groupe")
        val probe = StreamProbe(user.realtime.events(user.id, emptyList()))
        try {
            probe.waitFor("first Connected") { it == RealtimeEvent.Connected }
            val mark = probe.mark()
            user.profiles.updateDisplayName("Sans groupe renommé")
            probe.waitFor("membershipsChanged after a rename", after = mark) { it == RealtimeEvent.MembershipsChanged }
        } finally {
            probe.stop()
        }
    }

    /** More ids than the server accepts in one filter (it fails the channel at ~70): only the first 60 are sent. */
    @Test
    fun groupIdsAreCappedSoTheChannelStillWorks() = IntegrationEnvironment.run(1.minutes) { devices ->
        val user = SupabaseHarness(devices).makeUser("Beaucoup de groupes")
        val group = user.groups.createGroup("Groupe parmi d’autres")
        val ids = listOf(group.id) + List(79) { UUID.randomUUID() }
        val probe = StreamProbe(user.realtime.events(user.id, ids))
        try {
            probe.waitFor("first Connected") { it == RealtimeEvent.Connected }
            val mark = probe.mark()
            user.groups.rename(group.id, "Groupe renommé")
            probe.waitFor("groupActivity of the first group", after = mark) { it == RealtimeEvent.GroupActivity(group.id) }
        } finally {
            probe.stop()
        }
    }

    /** The client closed the socket itself (e.g. after the last channel): a new subscription opens a new one. */
    @Test
    fun resubscribesAfterTheClientDisconnected() = IntegrationEnvironment.run(1.minutes) { devices ->
        val subscriber = subscribe(devices)
        try {
            val mark = subscriber.probe.mark()
            subscriber.context.realtime.disconnect()
            subscriber.probe.waitFor("Connected after the disconnection", after = mark, timeout = 30.seconds) {
                it == RealtimeEvent.Connected
            }
            expectActivity(subscriber, "after the disconnection")
        } finally {
            subscriber.probe.stop()
        }
    }
}
