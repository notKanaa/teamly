package io.github.notkanaa.equipe.supabase

import io.github.notkanaa.equipe.core.AppError
import io.github.notkanaa.equipe.core.JoinResult
import io.github.notkanaa.equipe.core.MemberRole
import io.github.notkanaa.equipe.core.TaskPriority
import io.github.notkanaa.equipe.core.TaskStatus
import io.github.notkanaa.equipe.core.UserProfile
import kotlinx.serialization.json.JsonObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import java.time.Instant

/** Decoding of real PostgREST answers (captured fixtures): embedded aliases, nulls, enums, timestamps. */
class DecodingTest {
    private fun <T> rows(name: String, decode: (JsonObject) -> T): List<T> =
        RestDecoding.decode(Fixture.bytes(name)) { element -> RestDecoding.lossyRows(element, decode).rows }

    private fun <T> row(name: String, decode: (JsonObject) -> T): T =
        RestDecoding.decode(Fixture.bytes(name)) { decode(it.asObject("row")) }

    @Test
    fun myGroupsEmbedsTheGroup() {
        val rows = rows("my_groups", MyGroupRow::decode)
        assertEquals(listOf(MemberRole.ADMIN, MemberRole.MEMBER), rows.map { it.role })
        val lilas = rows[0].summary
        assertEquals(Seed.lilas, lilas.id)
        assertEquals(MemberRole.ADMIN, lilas.myRole)
        assertEquals("Coloc' rue des Lilas", lilas.group.name)
        assertEquals(Seed.camille, lilas.group.createdBy)
        assertEquals("2026-09-13T23:52:26.878215Z", PostgresTimestamp.format(lilas.group.createdAt))
        assertEquals("2026-09-23T23:52:26.878215Z", PostgresTimestamp.format(lilas.group.lastActivityAt))
    }

    @Test
    fun membersEmbedTheProfile() {
        val members = rows("members", MemberRow::decode).map { it.membership(Seed.lilas) }
        assertEquals(listOf(Seed.camille, Seed.lucas, Seed.ines), members.map { it.user.id })
        assertEquals(listOf("Camille Martin", "Lucas Bernard", "Inès Dubois"), members.map { it.user.displayName })
        assertEquals(listOf(MemberRole.ADMIN, MemberRole.MEMBER, MemberRole.MEMBER), members.map { it.role })
        assertTrue(members.all { it.groupId == Seed.lilas })
        assertEquals("2026-09-14T23:52:26.878215Z", PostgresTimestamp.format(members[1].joinedAt))
    }

    @Test
    fun groupTasksHaveSortedAssigneesAndNoPersonalFields() {
        val tasks = rows("group_tasks", TaskRow::decode).map { it.item() }
        assertEquals(5, tasks.size)
        val courses = tasks.first { it.id == Seed.courses }
        // The server lists Lucas then Camille: the adapter sorts by uuidString.
        assertEquals(listOf(Seed.camille, Seed.lucas), courses.assigneeIds)
        assertEquals(TaskStatus.IN_PROGRESS, courses.status)
        assertEquals(TaskPriority.MEDIUM, courses.priority)
        assertEquals("Lait, pâtes, lessive et papier toilette.", courses.details)
        assertEquals(Seed.lucas, courses.createdBy)
        assertTrue(tasks.all { it.myAssignedAt == null && it.myAssignedBy == null && it.groupName == null })
        val cuisine = tasks.first { it.id == Seed.cuisine }
        assertEquals(TaskStatus.DONE, cuisine.status)
        assertNull(cuisine.details)
        assertNull(cuisine.dueAt)
        assertEquals("2026-09-22T23:52:26.878215Z", cuisine.completedAt?.let(PostgresTimestamp::format))
        val unassigned = tasks.first { it.title == "Réparer la fuite du lavabo" }
        assertTrue(unassigned.assigneeIds.isEmpty())
    }

    @Test
    fun myTasksFillMyAssignedAtAndGroupName() {
        val rows = rows("my_tasks", TaskRow::decode)
        val tasks = rows.map { it.myTaskItem }
        val courses = tasks.first { it.id == Seed.courses }
        assertEquals("Coloc' rue des Lilas", courses.groupName)
        assertEquals("2026-09-21T23:52:26.878215Z", courses.myAssignedAt?.let(PostgresTimestamp::format))
        assertEquals(Seed.lucas, courses.myAssignedBy)
        assertEquals("every assignee, not only me", listOf(Seed.camille, Seed.lucas), courses.assigneeIds)
        assertEquals("Projet Asso Sport", tasks.first { it.id == Seed.gymnase }.groupName)
        assertEquals("self-assignment", Seed.camille, tasks.first { it.id == Seed.poubelles }.myAssignedBy)
        // Without the personal fields, a myTasks item is the plain task.
        val plain = courses.copy(myAssignedAt = null, myAssignedBy = null, groupName = null)
        assertEquals(rows.first { it.id == Seed.courses }.item(), plain)
    }

    @Test
    fun assignmentsEmbedTaskAndGroup() {
        val events = RestDecoding.decode(Fixture.bytes("assignments")) { element ->
            RestDecoding.lossyRows(element, AssignmentRow::decode).rows
        }.mapNotNull { it.event }
        assertEquals(listOf(Seed.gymnase, Seed.cuisine, Seed.courses), events.map { it.taskId })
        assertEquals("Réserver le gymnase", events[0].taskTitle)
        assertEquals("Projet Asso Sport", events[0].groupName)
        assertEquals(Seed.sport, events[0].groupId)
        assertEquals(Seed.lucas, events[0].assignedBy)
        assertEquals("2026-09-27T16:00:00.000000Z", events[0].dueAt?.let(PostgresTimestamp::format))
        assertNull(events[1].dueAt)
        assertTrue(events.zipWithNext().all { (a, b) -> a.assignedAt < b.assignedAt })
    }

    @Test
    fun assignmentWithADeletedAssignerKeepsANullAssignedBy() {
        val json = """
            [{"task_id":"b0000000-0000-4000-8000-000000000001","group_id":"a0000000-0000-4000-8000-000000000001",
            "assigned_by":null,"assigned_at":"2026-09-20T23:52:26.8+00:00",
            "task":{"group": {"name": "Coloc' rue des Lilas"}, "title": "Sortir les poubelles", "due_at": null}}]
        """.trimIndent()
        val event = RestDecoding.decode(json.toByteArray()) { RestDecoding.lossyRows(it, AssignmentRow::decode).rows }.single().event!!
        assertNull(event.assignedBy)
        assertEquals("2026-09-20T23:52:26.800000Z", PostgresTimestamp.format(event.assignedAt))
    }

    @Test
    fun profileAndInviteAndTopic() {
        assertEquals(listOf(UserProfile(Seed.camille, "Camille Martin")), rows("profile", ProfileRow::decode).map { it.profile })
        assertEquals(listOf("LYLAS234"), rows("invite_code", InviteRow::decode).map { it.code })
        assertEquals("NYCXWUA4", RestDecoding.decode(Fixture.bytes("regenerate")) { it.stringValue() })
    }

    @Test
    fun rpcRowsAreBareRows() {
        val group = row("create_group", GroupRow::decode)
        assertEquals("Groupe fixture", group.name)
        assertEquals(group.createdAt, group.lastActivityAt)
        val created = row("create_task", TaskRow::decode)
        assertNull(created.assignees)
        assertTrue(created.item().assigneeIds.isEmpty())
        assertEquals(listOf(Seed.camille, Seed.lucas), created.item(assigneeIds = listOf(Seed.lucas, Seed.camille, Seed.lucas)).assigneeIds)
        assertEquals(Instant.ofEpochSecond(1_924_992_000), created.dueAt)
        val done = row("set_task_status", TaskRow::decode)
        assertEquals(TaskStatus.DONE, done.status)
        assertEquals(done.updatedAt, done.completedAt)
    }

    @Test
    fun joinResults() {
        assertEquals(JoinResult(Seed.sport, "Projet Asso Sport", alreadyMember = false), row("join_joined", JoinRow::decode).result())
        assertEquals(JoinResult(Seed.lilas, "Coloc' rue des Lilas", alreadyMember = true), row("join_already_member", JoinRow::decode).result())
        val invalid = row("join_invalid_code", JoinRow::decode)
        try {
            invalid.result()
            fail("expected InvalidCode")
        } catch (error: AppError) {
            assertEquals(AppError.InvalidCode, error)
        }
    }

    @Test
    fun unexpectedJSONIsAnUnknownError() {
        for (body in listOf("""{"message":"oops"}""", "<html>Portail captif</html>", "")) {
            try {
                RestDecoding.decodeRows(body.toByteArray(), TaskRow::decode)
                fail("expected an error for $body")
            } catch (error: AppError) {
                assertEquals(AppError.Unknown("réponse inattendue du serveur"), error)
            }
        }
    }

    @Test
    fun uuidsMustBeCanonical() {
        assertEquals(Seed.camille, parseUuidOrNull("11111111-1111-4111-8111-111111111111"))
        assertEquals(Seed.camille, parseUuidOrNull("11111111-1111-4111-8111-111111111111".uppercase()))
        assertNull(parseUuidOrNull("1-1-1-1-1"))
        assertNull(parseUuidOrNull("11111111111141118111111111111111"))
        assertNull(parseUuidOrNull(""))
    }
}
