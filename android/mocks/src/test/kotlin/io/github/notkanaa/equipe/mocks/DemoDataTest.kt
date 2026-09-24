package io.github.notkanaa.equipe.mocks

import io.github.notkanaa.equipe.core.AppError
import io.github.notkanaa.equipe.core.AppServices
import io.github.notkanaa.equipe.core.AuthUser
import io.github.notkanaa.equipe.core.MemberRole
import io.github.notkanaa.equipe.core.TaskDraft
import io.github.notkanaa.equipe.core.TaskItem
import io.github.notkanaa.equipe.core.TaskPriority
import io.github.notkanaa.equipe.core.TaskStatus
import io.github.notkanaa.equipe.core.UserProfile
import io.github.notkanaa.equipe.core.uuidString
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.time.Duration
import java.time.Instant
import java.time.LocalTime
import java.util.UUID

/** The demo data must match docs/CONTRACTS.md §8 and `supabase/seed.sql` (canonical) exactly. Port of DemoDataTests.swift. */
class DemoDataTest {
    private val calendar = DemoData.calendar

    /** Wednesday 2026-09-23 10:00 in Paris. */
    private val now: Instant = TestDates.parisDate(2026, 9, 23, 10)

    /** `now() - interval 'N days'` of the seed (run in a UTC session: exactly N × 24 hours). */
    private fun ago(days: Long): Instant = now.minusSeconds(days * 86_400L)

    private fun camille(): AppServices {
        val now = now
        return InMemoryBackend.demo(now = { now }).services(DemoData.camille.id)
    }

    private fun byTitle(tasks: List<TaskItem>): Map<String, TaskItem> = tasks.associateBy { it.title }

    @Test
    fun usersIdsEmailsAndDisplayNames() = runTest {
        assertEquals("motdepasse123", DemoData.password)
        assertEquals(
            listOf(
                UUID.fromString("11111111-1111-4111-8111-111111111111"),
                UUID.fromString("22222222-2222-4222-8222-222222222222"),
                UUID.fromString("33333333-3333-4333-8333-333333333333"),
            ),
            DemoData.users.map { it.id },
        )
        assertEquals(
            listOf("camille@example.com", "lucas@example.com", "ines@example.com"),
            DemoData.users.map { it.email },
        )
        assertEquals(listOf("Camille Martin", "Lucas Bernard", "Inès Dubois"), DemoData.users.map { it.displayName })
        val backend = InMemoryBackend.demo()
        for (user in DemoData.users) {
            val services = backend.services(null)
            services.auth.signIn(user.email, DemoData.password)
            assertEquals(AuthUser(user.id, user.email), services.auth.currentUser())
            assertEquals(UserProfile(user.id, user.displayName), services.profiles.myProfile())
        }
        assertNull(backend.userId(forEmail = DemoData.newcomer.email))
        assertEquals(DemoUser(UUID.fromString("c0000000-0000-4000-8000-000000000004"), "alex@example.com", "Alex Moreau"), DemoData.newcomer)
    }

    @Test
    fun groupsRolesAndInviteCodes() = runTest {
        val backend = InMemoryBackend.demo()
        val camille = backend.services(DemoData.camille.id)
        val lucas = backend.services(DemoData.lucas.id)
        val ines = backend.services(DemoData.ines.id)

        assertEquals(UUID.fromString("a0000000-0000-4000-8000-000000000001"), DemoData.lilasGroupId)
        assertEquals(UUID.fromString("a0000000-0000-4000-8000-000000000002"), DemoData.sportGroupId)
        val groups = camille.groups.myGroups()
        assertEquals(listOf("Coloc' rue des Lilas", "Projet Asso Sport"), groups.map { it.group.name })
        assertEquals(listOf(MemberRole.ADMIN, MemberRole.MEMBER), groups.map { it.myRole })
        assertEquals(listOf(DemoData.lilasGroupId, DemoData.sportGroupId), groups.map { it.id })
        assertEquals(listOf(DemoData.camille.id, DemoData.lucas.id), groups.map { it.group.createdBy })
        assertEquals(listOf(DemoData.lilasGroupId), ines.groups.myGroups().map { it.id })

        val lilas = camille.groups.members(DemoData.lilasGroupId)
        assertEquals(listOf("Camille Martin", "Inès Dubois", "Lucas Bernard"), lilas.map { it.user.displayName })
        assertEquals(listOf(MemberRole.ADMIN, MemberRole.MEMBER, MemberRole.MEMBER), lilas.map { it.role })
        val sport = camille.groups.members(DemoData.sportGroupId)
        assertEquals(listOf("Lucas Bernard", "Camille Martin"), sport.map { it.user.displayName })
        assertEquals(listOf(MemberRole.ADMIN, MemberRole.MEMBER), sport.map { it.role })

        assertEquals("LYLAS234", camille.groups.inviteCode(DemoData.lilasGroupId).value)
        assertEquals("SPRT5678", lucas.groups.inviteCode(DemoData.sportGroupId).value)
        assertThrowsAppError(AppError.Forbidden) { camille.groups.inviteCode(DemoData.sportGroupId) }
        assertThrowsAppError(AppError.Forbidden) { ines.groups.inviteCode(DemoData.lilasGroupId) }
    }

    /**
     * seed.sql: groups created 10 / 20 days ago; `joined_at` per member; the AFTER triggers of the member, task and
     * assignee inserts set `last_activity_at` of both groups to the seed time (an exact tie, broken by name).
     */
    @Test
    fun groupAndMembershipDates() = runTest {
        val services = camille()
        val groups = services.groups.myGroups()
        assertEquals(listOf(ago(10), ago(20)), groups.map { it.group.createdAt })
        assertEquals(listOf(now, now), groups.map { it.group.lastActivityAt })

        val lilas = services.groups.members(DemoData.lilasGroupId)
        assertEquals(listOf(DemoData.camille.id, DemoData.ines.id, DemoData.lucas.id), lilas.map { it.user.id })
        assertEquals(listOf(ago(10), ago(8), ago(9)), lilas.map { it.joinedAt })
        val sport = services.groups.members(DemoData.sportGroupId)
        assertEquals(listOf(DemoData.lucas.id, DemoData.camille.id), sport.map { it.user.id })
        assertEquals(listOf(ago(20), ago(15)), sport.map { it.joinedAt })
    }

    @Test
    fun lilasTasks() = runTest {
        val services = camille()
        val tasks = services.tasks.tasks(DemoData.lilasGroupId, includeOldDone = false)
        val byTitle = byTitle(tasks)
        assertEquals(
            setOf(
                "Sortir les poubelles", "Faire les courses", "Payer le loyer", "Réparer la fuite du lavabo",
                "Nettoyer la cuisine",
            ),
            byTitle.keys,
        )
        val camilleId = DemoData.camille.id
        val lucasId = DemoData.lucas.id
        val inesId = DemoData.ines.id

        val poubelles = byTitle.getValue("Sortir les poubelles")
        assertEquals(DemoData.TaskIds.sortirPoubelles, poubelles.id)
        assertEquals("Poubelle jaune et poubelle verte.", poubelles.details)
        assertEquals(listOf(camilleId), poubelles.assigneeIds)
        assertEquals(TaskPriority.HIGH, poubelles.priority)
        assertEquals(TaskStatus.TODO, poubelles.status)
        assertEquals(TestDates.parisDate(2026, 9, 23, 20), poubelles.dueAt)
        assertEquals(camilleId, poubelles.createdBy)
        assertEquals(ago(3), poubelles.createdAt)

        val courses = byTitle.getValue("Faire les courses")
        assertEquals(DemoData.TaskIds.faireCourses, courses.id)
        assertEquals("Lait, pâtes, lessive et papier toilette.", courses.details)
        assertEquals(listOf(lucasId, camilleId).sortedBy { it.uuidString }, courses.assigneeIds)
        assertEquals(TaskPriority.MEDIUM, courses.priority)
        assertEquals(TaskStatus.IN_PROGRESS, courses.status)
        assertEquals(TestDates.parisDate(2026, 9, 24, 18), courses.dueAt)
        assertEquals(lucasId, courses.createdBy)
        assertEquals(ago(2), courses.createdAt)

        val loyer = byTitle.getValue("Payer le loyer")
        assertEquals(DemoData.TaskIds.payerLoyer, loyer.id)
        assertNull(loyer.details)
        assertEquals(listOf(inesId), loyer.assigneeIds)
        assertEquals(TaskPriority.HIGH, loyer.priority)
        assertEquals(TaskStatus.TODO, loyer.status)
        assertEquals("yesterday 18:00 in Paris", TestDates.parisDate(2026, 9, 22, 18), loyer.dueAt)
        assertEquals(camilleId, loyer.createdBy)
        assertEquals(ago(6), loyer.createdAt)

        val fuite = byTitle.getValue("Réparer la fuite du lavabo")
        assertEquals(DemoData.TaskIds.reparerFuite, fuite.id)
        assertEquals("Le joint sous le lavabo de la salle de bain goutte.", fuite.details)
        assertTrue(fuite.assigneeIds.isEmpty())
        assertEquals(TaskPriority.LOW, fuite.priority)
        assertNull(fuite.dueAt)
        assertEquals(TaskStatus.TODO, fuite.status)
        assertEquals(inesId, fuite.createdBy)
        assertEquals(ago(5), fuite.createdAt)

        val cuisine = byTitle.getValue("Nettoyer la cuisine")
        assertEquals(DemoData.TaskIds.nettoyerCuisine, cuisine.id)
        assertNull(cuisine.details)
        assertEquals(listOf(camilleId), cuisine.assigneeIds)
        assertEquals(TaskPriority.MEDIUM, cuisine.priority)
        assertEquals(TaskStatus.DONE, cuisine.status)
        assertNull(cuisine.dueAt)
        assertEquals(lucasId, cuisine.createdBy)
        assertEquals(ago(4), cuisine.createdAt)
        assertEquals("yesterday 19:00 in Paris", TestDates.parisDate(2026, 9, 22, 19), cuisine.completedAt)

        for (task in tasks) {
            assertEquals(DemoData.lilasGroupId, task.groupId)
            assertEquals(task.createdAt, task.updatedAt)
            assertEquals(task.status == TaskStatus.DONE, task.completedAt != null)
        }
    }

    @Test
    fun sportTasks() = runTest {
        val services = camille()
        val tasks = services.tasks.tasks(DemoData.sportGroupId, includeOldDone = false)
        val byTitle = byTitle(tasks)
        assertEquals(setOf("Réserver le gymnase", "Créer l'affiche du tournoi"), byTitle.keys)

        val gymnase = byTitle.getValue("Réserver le gymnase")
        assertEquals(DemoData.TaskIds.reserverGymnase, gymnase.id)
        assertEquals("Samedi après-midi, pour le tournoi.", gymnase.details)
        assertEquals(listOf(DemoData.camille.id), gymnase.assigneeIds)
        assertEquals(TaskPriority.HIGH, gymnase.priority)
        assertEquals(TaskStatus.TODO, gymnase.status)
        assertEquals(TestDates.parisDate(2026, 9, 26, 18), gymnase.dueAt)
        assertEquals(DemoData.lucas.id, gymnase.createdBy)
        assertEquals(ago(7), gymnase.createdAt)

        val affiche = byTitle.getValue("Créer l'affiche du tournoi")
        assertEquals(DemoData.TaskIds.creerAffiche, affiche.id)
        assertNull(affiche.details)
        assertEquals(listOf(DemoData.lucas.id), affiche.assigneeIds)
        assertEquals(TaskPriority.LOW, affiche.priority)
        assertEquals(TaskStatus.IN_PROGRESS, affiche.status)
        assertEquals(TestDates.parisDate(2026, 9, 30, 12), affiche.dueAt)
        assertEquals(DemoData.lucas.id, affiche.createdBy)
        assertEquals(ago(7), affiche.createdAt)

        for (task in tasks) {
            assertEquals(task.createdAt, task.updatedAt)
        }
    }

    @Test
    fun camillesTasksAndAssignments() = runTest {
        val services = camille()
        val open = services.tasks.myTasks(includeDone = false)
        assertEquals(setOf("Sortir les poubelles", "Faire les courses", "Réserver le gymnase"), open.map { it.title }.toSet())
        val all = services.tasks.myTasks(includeDone = true)
        assertEquals(
            setOf("Sortir les poubelles", "Faire les courses", "Réserver le gymnase", "Nettoyer la cuisine"),
            all.map { it.title }.toSet(),
        )
        for (task in all) {
            // seed.sql: assigned_at = the task's created_at.
            assertEquals(task.createdAt, task.myAssignedAt)
            val groupName = if (task.groupId == DemoData.lilasGroupId) DemoData.lilasGroupName else DemoData.sportGroupName
            assertEquals(groupName, task.groupName)
        }
        // Assigned to Camille by Lucas, oldest first; her self-assignment (poubelles) is excluded.
        val events = services.tasks.assignments(Instant.MIN)
        assertEquals(listOf("Réserver le gymnase", "Nettoyer la cuisine", "Faire les courses"), events.map { it.taskTitle })
        assertEquals(listOf(ago(7), ago(4), ago(2)), events.map { it.assignedAt })
        assertTrue(events.all { it.assignedBy == DemoData.lucas.id })
    }

    /** seed.sql: « Nettoyer la cuisine » was created by Lucas, so he may edit and delete it (plain member of Lilas). */
    @Test
    fun lucasManagesTheTaskHeCreated() = runTest {
        val now = now
        val backend = InMemoryBackend.demo(now = { now })
        val lucas = backend.services(DemoData.lucas.id)
        val edited = lucas.tasks.update(
            DemoData.TaskIds.nettoyerCuisine,
            TaskDraft(title = "Nettoyer la cuisine !", assigneeIds = setOf(DemoData.camille.id)),
        )
        assertEquals("Nettoyer la cuisine !", edited.title)
        lucas.tasks.delete(DemoData.TaskIds.nettoyerCuisine)
        assertThrowsAppError(AppError.Forbidden) {
            lucas.tasks.delete(DemoData.TaskIds.payerLoyer) // created by Camille
        }
    }

    /**
     * "Tomorrow 18:00", the overdue rent ("yesterday 18:00") and the kitchen done "yesterday 19:00" are Paris
     * wall-clock times, also across the October DST change.
     */
    @Test
    fun relativeDatesFollowTheSeed() = runTest {
        val beforeDstChange = TestDates.parisDate(2026, 10, 24, 10)
        val services = InMemoryBackend.demo(now = { beforeDstChange }).services(DemoData.camille.id)
        val courses = services.tasks.task(DemoData.TaskIds.faireCourses)
        assertEquals(TestDates.parisDate(2026, 10, 25, 18), courses.dueAt)
        assertEquals(Duration.ofHours(33), Duration.between(beforeDstChange, courses.dueAt!!))
        val poubelles = services.tasks.task(DemoData.TaskIds.sortirPoubelles)
        assertEquals(TestDates.parisDate(2026, 10, 24, 20), poubelles.dueAt)

        val afterDstChange = TestDates.parisDate(2026, 10, 25, 12)
        val later = InMemoryBackend.demo(now = { afterDstChange }).services(DemoData.camille.id)
        val loyer = later.tasks.task(DemoData.TaskIds.payerLoyer)
        assertEquals(TestDates.parisDate(2026, 10, 24, 18), loyer.dueAt)
        val cuisine = later.tasks.task(DemoData.TaskIds.nettoyerCuisine)
        assertEquals(TestDates.parisDate(2026, 10, 24, 19), cuisine.completedAt)
        val gymnase = later.tasks.task(DemoData.TaskIds.reserverGymnase)
        assertEquals(TestDates.parisDate(2026, 10, 28, 18), gymnase.dueAt)
    }

    /**
     * The screenshots are taken at the CI run time: the overdue rent shows « Hier à 18:00 » and the kitchen
     * « Terminée hier à 19:00 », not the seeding time (review UX-08). (The Swift test formats with `DateText`; here the
     * round wall-clock times themselves are checked.)
     */
    @Test
    fun pastDemoDatesShowRoundTimesWhateverTheSeedTime() = runTest {
        val seedTimes = listOf(
            TestDates.parisDate(2026, 9, 24, 5, 19),
            TestDates.parisDate(2026, 9, 24, 23, 59),
            TestDates.parisDate(2026, 9, 24, 0, 1),
        )
        for (now in seedTimes) {
            val services = InMemoryBackend.demo(now = { now }).services(DemoData.camille.id)
            val yesterday = calendar.localDate(now).minusDays(1)
            val loyer = services.tasks.task(DemoData.TaskIds.payerLoyer)
            val dueAt = loyer.dueAt!!
            assertEquals(yesterday, calendar.localDate(dueAt))
            assertEquals(LocalTime.of(18, 0), calendar.zonedDateTime(dueAt).toLocalTime())
            assertTrue("always overdue", dueAt < now)
            val cuisine = services.tasks.task(DemoData.TaskIds.nettoyerCuisine)
            val completedAt = cuisine.completedAt!!
            assertEquals(yesterday, calendar.localDate(completedAt))
            assertEquals(LocalTime.of(19, 0), calendar.zonedDateTime(completedAt).toLocalTime())
            assertTrue(completedAt < now && completedAt > cuisine.createdAt)
        }
    }

    @Test
    fun demoGroupsTieOnActivityAndAreOrderedByName() = runTest {
        val services = camille()
        val groups = services.groups.myGroups()
        assertEquals(listOf(now, now), groups.map { it.group.lastActivityAt })
        assertEquals(listOf(DemoData.lilasGroupName, DemoData.sportGroupName), groups.map { it.group.name })
    }
}
