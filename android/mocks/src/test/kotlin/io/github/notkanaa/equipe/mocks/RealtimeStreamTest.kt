package io.github.notkanaa.equipe.mocks

import app.cash.turbine.test
import app.cash.turbine.turbineScope
import io.github.notkanaa.equipe.core.AppServices
import io.github.notkanaa.equipe.core.InviteCode
import io.github.notkanaa.equipe.core.MemberRole
import io.github.notkanaa.equipe.core.RealtimeEvent
import io.github.notkanaa.equipe.core.TaskDraft
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Test
import java.util.UUID

/**
 * The mock delivers Realtime events synchronously during each write, in commit order, so these tests read the flows
 * directly (Turbine collects them unconfined). Absence is checked by performing a "sentinel" change whose event must
 * come next. Port of RealtimeStreamTests.swift.
 */
class RealtimeStreamTest {
    private val backend = InMemoryBackend.demo()
    private val camille: AppServices get() = backend.services(DemoData.camille.id)
    private val lucas: AppServices get() = backend.services(DemoData.lucas.id)
    private val ines: AppServices get() = backend.services(DemoData.ines.id)

    private val lilas = DemoData.lilasGroupId
    private val sport = DemoData.sportGroupId

    @Test
    fun connectedFirstThenGroupActivityForFilteredGroups() = runTest {
        val camille = camille
        camille.realtime.events(DemoData.camille.id, listOf(lilas)).test {
            assertEquals(RealtimeEvent.Connected, awaitItem())

            // Activity in Sport (not in the filter) is not delivered; the next event is the Lilas one.
            lucas.tasks.create(sport, TaskDraft(title = "Hors filtre"))
            ines.tasks.create(lilas, TaskDraft(title = "Dans le filtre"))
            assertEquals(RealtimeEvent.GroupActivity(lilas), awaitItem())

            camille.groups.rename(lilas, "Coloc' des Lilas")
            assertEquals(RealtimeEvent.GroupActivity(lilas), awaitItem())
            cancelAndIgnoreRemainingEvents()
        }
    }

    @Test
    fun groupActivityRequiresMembership() = runTest {
        // Inès lists Sport in her filter but is not a member (RLS): nothing is delivered for it.
        ines.realtime.events(DemoData.ines.id, listOf(sport, lilas)).test {
            assertEquals(RealtimeEvent.Connected, awaitItem())
            lucas.tasks.create(sport, TaskDraft(title = "Privé"))
            camille.tasks.create(lilas, TaskDraft(title = "Sentinelle"))
            assertEquals(RealtimeEvent.GroupActivity(lilas), awaitItem())
            cancelAndIgnoreRemainingEvents()
        }
    }

    /**
     * The real Realtime server fails the whole channel from about 70 ids in one `id=in.(…)` filter (index row size
     * limit), so only the first `maxRealtimeGroups` (60) ids are watched.
     */
    @Test
    fun onlyTheFirstSixtyGroupIdsAreWatched() = runTest {
        assertEquals(60, InMemoryBackend.maxRealtimeGroups)
        val filter = List(60) { UUID.randomUUID() } + lilas
        turbineScope {
            val events = camille.realtime.events(DemoData.camille.id, filter).testIn(backgroundScope)
            assertEquals(RealtimeEvent.Connected, events.awaitItem())
            ines.tasks.create(lilas, TaskDraft(title = "Ignorée"))
            lucas.groups.setRole(sport, DemoData.camille.id, MemberRole.ADMIN)
            assertEquals(RealtimeEvent.MembershipsChanged, events.awaitItem())

            val sixty = List(59) { UUID.randomUUID() } + lilas
            val watched = camille.realtime.events(DemoData.camille.id, sixty).testIn(backgroundScope)
            assertEquals(RealtimeEvent.Connected, watched.awaitItem())
            ines.tasks.create(lilas, TaskDraft(title = "Suivie"))
            assertEquals(RealtimeEvent.GroupActivity(lilas), watched.awaitItem())
            events.cancelAndIgnoreRemainingEvents()
            watched.cancelAndIgnoreRemainingEvents()
        }
    }

    /**
     * Realtime rows follow the RLS of the SESSION user: a signed-out client (anon role) receives nothing, whatever
     * `userId` it passes. Signing in later makes the channel deliver again (the token is updated).
     */
    @Test
    fun realtimeIsBoundToTheSessionUser() = runTest {
        val device = backend.services(null)
        device.realtime.events(DemoData.camille.id, listOf(sport)).test {
            assertEquals(RealtimeEvent.Connected, awaitItem())
            lucas.tasks.create(sport, TaskDraft(title = "Privée", assigneeIds = setOf(DemoData.camille.id)))
            lucas.groups.rename(sport, "Projet Asso Sport 2026")

            // Sentinel: once signed in as Camille, the next change is delivered; nothing may precede it.
            device.auth.signIn(DemoData.camille.email, DemoData.password)
            lucas.groups.setRole(sport, DemoData.camille.id, MemberRole.ADMIN)
            assertEquals(RealtimeEvent.GroupActivity(sport), awaitItem())
            assertEquals(RealtimeEvent.MembershipsChanged, awaitItem())
            cancelAndIgnoreRemainingEvents()
        }
    }

    /** Filters use the `userId` argument, visibility uses the session user (like RLS on the real server). */
    @Test
    fun filtersUseTheUserIdButVisibilityTheSession() = runTest {
        // Inès's device subscribes with Camille's id: Camille's assignments in Lilas are visible to Inès (member),
        // those in Sport are not.
        ines.realtime.events(DemoData.camille.id, emptyList()).test {
            assertEquals(RealtimeEvent.Connected, awaitItem())
            lucas.tasks.create(sport, TaskDraft(title = "Sport", assigneeIds = setOf(DemoData.camille.id)))
            val lilasTask = lucas.tasks.create(lilas, TaskDraft(title = "Lilas", assigneeIds = setOf(DemoData.camille.id)))
            assertEquals(RealtimeEvent.Assigned(lilasTask.id, lilas, DemoData.lucas.id), awaitItem())
            cancelAndIgnoreRemainingEvents()
        }
    }

    @Test
    fun membershipsChangedForTheUsersOwnMemberships() = runTest {
        val newcomer = backend.createAccount("nouveau@example.com", "motdepasse123", "Nouveau")
        val services = backend.services(newcomer.id)
        services.realtime.events(newcomer.id, emptyList()).test {
            assertEquals(RealtimeEvent.Connected, awaitItem())

            services.groups.join(InviteCode.parse(DemoData.lilasInviteCode)!!)
            assertEquals(RealtimeEvent.MembershipsChanged, awaitItem())
            camille.groups.setRole(lilas, newcomer.id, MemberRole.ADMIN)
            assertEquals(RealtimeEvent.MembershipsChanged, awaitItem())
            // Someone else's membership change is not delivered to this user.
            camille.groups.removeMember(lilas, DemoData.ines.id)
            // The profile row is updated by a display-name change too (same Realtime binding).
            services.profiles.updateDisplayName("Nouveau nom")
            assertEquals(RealtimeEvent.MembershipsChanged, awaitItem())
            services.groups.leave(lilas)
            assertEquals(RealtimeEvent.MembershipsChanged, awaitItem())
            services.groups.createGroup("Le mien")
            assertEquals(RealtimeEvent.MembershipsChanged, awaitItem())
            cancelAndIgnoreRemainingEvents()
        }
    }

    @Test
    fun assignedForEveryNewRowOfTheUser() = runTest {
        camille.realtime.events(DemoData.camille.id, emptyList()).test {
            assertEquals(RealtimeEvent.Connected, awaitItem())

            val byLucas = lucas.tasks.create(
                sport,
                TaskDraft(title = "Pour Camille", assigneeIds = setOf(DemoData.camille.id, DemoData.lucas.id)),
            )
            assertEquals(RealtimeEvent.Assigned(byLucas.id, sport, DemoData.lucas.id), awaitItem())

            val own = camille.tasks.create(lilas, TaskDraft(title = "Pour moi", assigneeIds = setOf(DemoData.camille.id)))
            assertEquals(RealtimeEvent.Assigned(own.id, lilas, DemoData.camille.id), awaitItem())

            // Re-saving the same assignees inserts no row; then a new row for Camille is inserted.
            lucas.tasks.update(byLucas.id, TaskDraft(byLucas))
            val task = lucas.tasks.create(sport, TaskDraft(title = "Plus tard"))
            lucas.tasks.update(task.id, TaskDraft(task).copy(assigneeIds = setOf(DemoData.camille.id)))
            assertEquals(RealtimeEvent.Assigned(task.id, sport, DemoData.lucas.id), awaitItem())
            cancelAndIgnoreRemainingEvents()
        }
    }

    @Test
    fun eventsFollowCommitOrder() = runTest {
        camille.realtime.events(DemoData.camille.id, listOf(lilas, sport)).test {
            assertEquals(RealtimeEvent.Connected, awaitItem())
            val task = lucas.tasks.create(sport, TaskDraft(title = "Ordre", assigneeIds = setOf(DemoData.camille.id)))
            ines.tasks.create(lilas, TaskDraft(title = "Ensuite"))
            assertEquals(RealtimeEvent.GroupActivity(sport), awaitItem())
            assertEquals(RealtimeEvent.Assigned(task.id, sport, DemoData.lucas.id), awaitItem())
            assertEquals(RealtimeEvent.GroupActivity(lilas), awaitItem())
            cancelAndIgnoreRemainingEvents()
        }
    }

    /** Kotlin flows are cold: the subscription exists while the flow is collected (Swift: while the stream lives). */
    @Test
    fun cancellingTheConsumerUnsubscribes() = runTest {
        assertEquals(0, backend.realtimeSubscriberCount)
        val flow = camille.realtime.events(DemoData.camille.id, listOf(lilas))
        assertEquals("not subscribed before collection", 0, backend.realtimeSubscriberCount)
        val received = ArrayList<RealtimeEvent>()
        val consumer = launch(start = CoroutineStart.UNDISPATCHED) { flow.collect { received.add(it) } }
        assertEquals(1, backend.realtimeSubscriberCount)
        assertEquals(listOf<RealtimeEvent>(RealtimeEvent.Connected), received)
        consumer.cancel()
        consumer.join()
        assertEquals(0, backend.realtimeSubscriberCount)
    }
}
