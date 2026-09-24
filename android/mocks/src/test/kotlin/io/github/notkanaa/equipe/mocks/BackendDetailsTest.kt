package io.github.notkanaa.equipe.mocks

import io.github.notkanaa.equipe.core.AppError
import io.github.notkanaa.equipe.core.AuthUser
import io.github.notkanaa.equipe.core.MemberRole
import io.github.notkanaa.equipe.core.TaskDraft
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.UUID
import kotlin.time.Duration.Companion.seconds

/** Port of BackendDetailsTests.swift. */
class BackendDetailsTest {
    @Test
    fun inviteCodesUseTheAlphabetAndAreUnique() = runTest {
        val backend = InMemoryBackend()
        val user = backend.createAccount("codes@example.com", "motdepasse123", "Codes")
        val services = backend.services(user.id)
        val codes = HashSet<String>()
        for (index in 0 until 60) {
            val group = services.groups.createGroup("Groupe $index")
            val code = services.groups.inviteCode(group.id).value
            assertEquals(8, code.length)
            assertTrue(code, code.all { it in "ABCDEFGHJKLMNPQRSTUVWXYZ23456789" })
            codes.add(code)
            val regenerated = services.groups.regenerateInviteCode(group.id).value
            assertNotEquals(code, regenerated)
            codes.add(regenerated)
        }
        assertEquals(120, codes.size)
    }

    @Test
    fun pushTopicFormat() = runTest {
        val backend = InMemoryBackend.demo()
        val topics = HashSet<String>()
        for (user in DemoData.users) {
            val topic = backend.services(user.id).push.enable()
            assertTrue(topic, topic.startsWith("equipe-"))
            assertEquals(31, topic.length)
            assertTrue(topic, topic.drop(7).all { it in "abcdefghijklmnopqrstuvwxyz0123456789" })
            topics.add(topic)
        }
        assertEquals(3, topics.size)
    }

    /** Account deletion promotes the oldest other member: `joined_at`, then `user_id` on ties. */
    @Test
    fun promotionTieBreaksOnUserId() = runTest {
        val clock = MockClock(TestDates.start)
        val backend = InMemoryBackend(now = clock.provider)
        val lowId = UUID.fromString("10000000-0000-4000-8000-000000000000")
        val highId = UUID.fromString("F0000000-0000-4000-8000-000000000000")
        val admin = backend.createAccount("admin@example.com", "motdepasse123", "Admin")
        backend.createAccount("haut@example.com", "motdepasse123", "Haut", id = highId)
        backend.createAccount("bas@example.com", "motdepasse123", "Bas", id = lowId)
        val adminServices = backend.services(admin.id)
        val group = adminServices.groups.createGroup("Égalité")
        val code = adminServices.groups.inviteCode(group.id)
        clock.advance(60.seconds)
        // Same joined_at for both (frozen clock); the higher id joins first. (`UUID.compareTo`, which compares signed
        // longs, would put F0000000-… first: the order is the one of `uuidString`, like Postgres.)
        backend.services(highId).groups.join(code)
        backend.services(lowId).groups.join(code)

        adminServices.auth.deleteAccount()
        val members = backend.services(highId).groups.members(group.id)
        assertEquals(listOf(lowId, highId), members.map { it.user.id })
        assertEquals(listOf(MemberRole.ADMIN, MemberRole.MEMBER), members.map { it.role })
    }

    @Test
    fun membersSortIgnoresCaseAndAccents() = runTest {
        val backend = InMemoryBackend()
        val names = listOf("zoé", "Émile", "eric", "Ana", "Éric")
        val users = ArrayList<AuthUser>()
        for ((index, name) in names.withIndex()) {
            users.add(backend.createAccount("u$index@example.com", "motdepasse123", name))
        }
        val owner = backend.services(users[0].id)
        val group = owner.groups.createGroup("Tri")
        val code = owner.groups.inviteCode(group.id)
        for (user in users.drop(1)) {
            backend.services(user.id).groups.join(code)
        }
        val members = owner.groups.members(group.id)
        // Admin first, then "ana" < "emile" < "eric" = "eric" (the exact string breaks the tie: "eric" < "Éric").
        assertEquals(listOf("zoé", "Ana", "Émile", "eric", "Éric"), members.map { it.user.displayName })
    }

    @Test
    fun failedWritesCommitNothing() = runTest {
        val backend = InMemoryBackend.demo()
        val camille = backend.services(DemoData.camille.id)
        val before = camille.groups.myGroups()
        assertThrowsAppError(AppError.AssigneeNotMember) {
            camille.tasks.create(
                DemoData.sportGroupId,
                TaskDraft(title = "Refusée", assigneeIds = setOf(DemoData.camille.id, DemoData.ines.id)),
            )
        }
        val after = camille.groups.myGroups()
        assertEquals(before, after) // no bump either
        val sport = camille.tasks.tasks(DemoData.sportGroupId, includeOldDone = true)
        assertFalse(sport.any { it.title == "Refusée" })
    }

    @Test
    fun servicesOfADeletedOrUnknownUserAreSignedOut() = runTest {
        val backend = InMemoryBackend.demo()
        val ghost = backend.services(UUID.randomUUID())
        assertNull(ghost.auth.currentUser())
        assertThrowsAppError(AppError.NotAuthenticated) { ghost.groups.myGroups() }
    }
}
