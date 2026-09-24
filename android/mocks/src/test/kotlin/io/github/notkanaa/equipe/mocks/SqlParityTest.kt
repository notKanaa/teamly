package io.github.notkanaa.equipe.mocks

import app.cash.turbine.test
import io.github.notkanaa.equipe.core.AppError
import io.github.notkanaa.equipe.core.AppServices
import io.github.notkanaa.equipe.core.MemberRole
import io.github.notkanaa.equipe.core.RealtimeEvent
import io.github.notkanaa.equipe.core.TaskDraft
import io.github.notkanaa.equipe.core.TaskPriority
import io.github.notkanaa.equipe.core.TaskStatus
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test
import java.time.Instant
import java.util.UUID
import kotlin.time.Duration.Companion.seconds

/** Mock behaviours checked against the SQL backend (probes of the local Supabase stack). Port of SQLParityTests.swift. */
class SqlParityTest {
    private val clock = MockClock(TestDates.start)
    private val lilas = DemoData.lilasGroupId

    private suspend fun lastActivity(services: AppServices, groupId: UUID): Instant =
        services.groups.myGroups().first { it.id == groupId }.group.lastActivityAt

    /** SQL `set_member_role` returns before its UPDATE when the role does not change: no bump, no signal. */
    @Test
    fun noOpRoleChangeHasNoSideEffects() = runTest {
        val backend = InMemoryBackend.demo(now = clock.provider)
        val camille = backend.services(DemoData.camille.id)
        val lucas = backend.services(DemoData.lucas.id)
        val ines = backend.services(DemoData.ines.id)
        val before = lastActivity(camille, lilas)
        lucas.realtime.events(DemoData.lucas.id, listOf(lilas)).test {
            assertEquals(RealtimeEvent.Connected, awaitItem())
            clock.advance(60.seconds)

            camille.groups.setRole(lilas, DemoData.lucas.id, MemberRole.MEMBER) // already a member
            camille.groups.setRole(lilas, DemoData.camille.id, MemberRole.ADMIN) // the only admin
            assertEquals(before, lastActivity(camille, lilas))
            assertEquals(
                listOf(MemberRole.ADMIN, MemberRole.MEMBER, MemberRole.MEMBER),
                camille.groups.members(lilas).map { it.role },
            )

            // Sentinel: a new assignment of Lucas; nothing may precede its events.
            clock.advance(60.seconds)
            val sentinel = ines.tasks.create(
                lilas, TaskDraft(title = "Sentinelle", assigneeIds = setOf(DemoData.lucas.id)),
            )
            assertEquals(RealtimeEvent.GroupActivity(lilas), awaitItem())
            assertEquals(RealtimeEvent.Assigned(sentinel.id, lilas, DemoData.ines.id), awaitItem())
            cancelAndIgnoreRemainingEvents()
        }
    }

    /** SQL `tasks_before_update` keeps `updated_at` unless title, details, status, priority or due date change. */
    @Test
    fun updatedAtOnlyMovesWhenAFieldChanges() = runTest {
        val backend = InMemoryBackend.demo(now = clock.provider)
        val camille = backend.services(DemoData.camille.id)
        val created = camille.tasks.create(
            lilas,
            TaskDraft(
                title = "Tâche P2", details = "d", priority = TaskPriority.HIGH,
                dueAt = Instant.ofEpochSecond(1_924_992_000L), assigneeIds = setOf(DemoData.camille.id),
            ),
        )
        clock.advance(60.seconds)
        val reassigned = camille.tasks.update(
            created.id,
            TaskDraft(
                title = "Tâche P2", details = "d", priority = TaskPriority.HIGH, dueAt = created.dueAt,
                assigneeIds = setOf(DemoData.camille.id, DemoData.ines.id),
            ),
        )
        assertEquals(2, reassigned.assigneeIds.size)
        assertEquals("an assignee-only edit keeps updatedAt", created.updatedAt, reassigned.updatedAt)
        clock.advance(60.seconds)
        val padded = TaskDraft(reassigned).copy(title = "  Tâche P2  ", details = " d ")
        val same = camille.tasks.update(created.id, padded)
        assertEquals("an edit with identical (trimmed) fields keeps updatedAt", created.updatedAt, same.updatedAt)
        clock.advance(60.seconds)
        val todoAgain = camille.tasks.setStatus(created.id, TaskStatus.TODO)
        assertEquals("todo → todo keeps updatedAt", created.updatedAt, todoAgain.updatedAt)

        clock.advance(60.seconds)
        val done = camille.tasks.setStatus(created.id, TaskStatus.DONE)
        assertEquals(clock.peek(), done.updatedAt)
        assertEquals(done.updatedAt, done.completedAt)
        clock.advance(60.seconds)
        val doneAgain = camille.tasks.setStatus(created.id, TaskStatus.DONE)
        assertEquals("done → done keeps updatedAt", done.updatedAt, doneAgain.updatedAt)
        assertEquals(done.completedAt, doneAgain.completedAt)
        assertEquals(doneAgain, camille.tasks.task(created.id))

        clock.advance(60.seconds)
        val retitled = TaskDraft(doneAgain).copy(title = "Tâche P3")
        val changed = camille.tasks.update(created.id, retitled)
        assertEquals(clock.peek(), changed.updatedAt)
    }

    /** The UPDATE still happens (and bumps the group) even when `updated_at` is kept. */
    @Test
    fun unchangedUpdatesStillBumpTheGroup() = runTest {
        val backend = InMemoryBackend.demo(now = clock.provider)
        val camille = backend.services(DemoData.camille.id)
        val task = camille.tasks.task(DemoData.TaskIds.sortirPoubelles)
        clock.advance(60.seconds)
        camille.tasks.setStatus(task.id, task.status)
        assertEquals(clock.peek(), lastActivity(camille, lilas))
        clock.advance(60.seconds)
        camille.tasks.update(task.id, TaskDraft(task))
        assertEquals(clock.peek(), lastActivity(camille, lilas))
    }

    /** Deleting an account sets `created_by` to NULL; SQL keeps `updated_at` (nothing editable changed). */
    @Test
    fun accountDeletionKeepsUpdatedAtOfTheirTasks() = runTest {
        val backend = InMemoryBackend.demo(now = clock.provider)
        val camille = backend.services(DemoData.camille.id)
        val before = camille.tasks.task(DemoData.TaskIds.faireCourses) // created by Lucas
        clock.advance(60.seconds)
        backend.services(DemoData.lucas.id).auth.deleteAccount()
        val after = camille.tasks.task(before.id)
        assertNull(after.createdBy)
        assertEquals(before.updatedAt, after.updatedAt)
        assertEquals(clock.peek(), lastActivity(camille, lilas)) // the UPDATE still bumps the group
    }

    /** Postgres `text` cannot hold U+0000 (PostgREST answers 22P05): the field's validation error instead. */
    @Test
    fun nulCharacterIsRejected() = runTest {
        val backend = InMemoryBackend.demo(now = clock.provider)
        val camille = backend.services(DemoData.camille.id)
        assertThrowsAppError(AppError.InvalidTitle) { camille.tasks.create(lilas, TaskDraft(title = "a\u0000b")) }
        assertThrowsAppError(AppError.InvalidDetails) {
            camille.tasks.create(lilas, TaskDraft(title = "Titre", details = "x\u0000"))
        }
        assertThrowsAppError(AppError.InvalidTitle) {
            camille.tasks.update(DemoData.TaskIds.sortirPoubelles, TaskDraft(title = "\u0000"))
        }
        assertThrowsAppError(AppError.InvalidName) { camille.groups.createGroup("x\u0000y") }
        assertThrowsAppError(AppError.InvalidName) { camille.groups.rename(lilas, "x\u0000y") }
        assertThrowsAppError(AppError.InvalidDisplayName) { camille.profiles.updateDisplayName("Ca\u0000mille") }
        assertThrowsAppError(AppError.InvalidDisplayName) {
            backend.services(null).auth.signUp("nul@example.com", "motdepasse123", "N\u0000")
        }
        assertEquals(5, camille.tasks.tasks(lilas, includeOldDone = true).size)
    }
}
