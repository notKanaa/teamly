package io.github.notkanaa.equipe.supabase

import io.github.notkanaa.equipe.core.TaskDraft
import io.github.notkanaa.equipe.core.TaskPriority
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/** The PostgREST requests are those of docs/CONTRACTS.md §4.3, verbatim, with microsecond timestamp filters. */
class RestQueryTest {
    private val me = Seed.camille
    private val group = Seed.lilas
    private val task = Seed.courses
    private val now = UnitBackend.now

    @Test
    fun myGroups() {
        val request = RestQuery.myGroups(me)
        assertEquals(RestRequest.Method.GET, request.method)
        assertEquals("group_members", request.path)
        assertEquals("select=role,group:groups(*)&user_id=eq.11111111-1111-4111-8111-111111111111", request.readableQuery)
    }

    @Test
    fun members() {
        val request = RestQuery.members(group)
        assertEquals("group_members", request.path)
        assertEquals(
            "select=user_id,role,joined_at,profile:profiles(id,display_name)&group_id=eq.a0000000-0000-4000-8000-000000000001",
            request.readableQuery,
        )
    }

    @Test
    fun inviteCode() {
        val request = RestQuery.inviteCode(group)
        assertEquals("group_invites", request.path)
        assertEquals("select=code&group_id=eq.a0000000-0000-4000-8000-000000000001", request.readableQuery)
    }

    @Test
    fun groupTasksHideOldDoneTasksWithAMicrosecondCutoff() {
        val recent = RestQuery.groupTasks(group, includeOldDone = false, now = now)
        assertEquals("tasks", recent.path)
        // now − 30 × 86 400 s, inclusive, 6 fractional digits in UTC.
        assertEquals(
            "select=*,assignees:task_assignees(user_id)&group_id=eq.a0000000-0000-4000-8000-000000000001" +
                "&or=(status.neq.done,completed_at.gte.2026-08-25T10:00:00.123456Z)",
            recent.readableQuery,
        )
        val all = RestQuery.groupTasks(group, includeOldDone = true, now = now)
        assertEquals(
            "select=*,assignees:task_assignees(user_id)&group_id=eq.a0000000-0000-4000-8000-000000000001",
            all.readableQuery,
        )
    }

    @Test
    fun cutoffIsThirtyTimes86400Seconds() {
        // Across the end of daylight saving time in Europe (2026-10-25): still exactly 2 592 000 s.
        val later = PostgresTimestamp.instant(1_793_700_000_000_001L)
        val cutoff = RestQuery.oldDoneCutoff(later)
        assertEquals(1_793_700_000_000_001L - 2_592_000_000_000L, PostgresTimestamp.epochMicroseconds(cutoff))
    }

    @Test
    fun oneTask() {
        assertEquals(
            "select=*,assignees:task_assignees(user_id)&id=eq.b0000000-0000-4000-8000-000000000002",
            RestQuery.task(task).readableQuery,
        )
    }

    @Test
    fun myTasks() {
        val open = RestQuery.myTasks(me, includeDone = false)
        assertEquals("tasks", open.path)
        assertEquals(
            "select=*,assignees:task_assignees(user_id),mine:task_assignees!inner(assigned_at,assigned_by,user_id),group:groups(name)" +
                "&mine.user_id=eq.11111111-1111-4111-8111-111111111111&status=neq.done",
            open.readableQuery,
        )
        val all = RestQuery.myTasks(me, includeDone = true)
        assertEquals(
            "select=*,assignees:task_assignees(user_id),mine:task_assignees!inner(assigned_at,assigned_by,user_id),group:groups(name)" +
                "&mine.user_id=eq.11111111-1111-4111-8111-111111111111",
            all.readableQuery,
        )
    }

    @Test
    fun assignmentsSinceIsExclusiveWithMicroseconds() {
        val request = RestQuery.assignments(me, since = now)
        assertEquals("task_assignees", request.path)
        assertEquals(
            "select=task_id,group_id,assigned_by,assigned_at,task:tasks(title,due_at,group:groups(name))" +
                "&user_id=eq.11111111-1111-4111-8111-111111111111&assigned_at=gt.2026-09-24T10:00:00.123456Z" +
                "&or=(assigned_by.is.null,assigned_by.neq.11111111-1111-4111-8111-111111111111)&order=assigned_at.asc",
            request.readableQuery,
        )
    }

    @Test
    fun profileAndPushTopic() {
        assertEquals("select=id,display_name&id=eq.11111111-1111-4111-8111-111111111111", RestQuery.myProfile(me).readableQuery)
        assertEquals("profiles", RestQuery.myProfile(me).path)
        assertEquals("select=topic&user_id=eq.11111111-1111-4111-8111-111111111111", RestQuery.pushTopic(me).readableQuery)
        assertEquals("push_subscriptions", RestQuery.pushTopic(me).path)
    }

    @Test
    fun updateDisplayNameIsAPatchReturningTheRow() {
        val request = RestQuery.updateDisplayName(me, "Camille M.")
        assertEquals(RestRequest.Method.PATCH, request.method)
        assertEquals("profiles", request.path)
        assertEquals("select=id,display_name&id=eq.11111111-1111-4111-8111-111111111111", request.readableQuery)
        assertEquals("return=representation", request.prefer)
        assertEquals("""{"display_name":"Camille M."}""", request.encodedBody())
    }

    @Test
    fun rpcsArePostsWithNamedParameters() {
        val request = RestQuery.rpc("rename_group", mapOf("p_name" to JsonValues.string("Coloc"), "p_group_id" to JsonValues.uuid(group)))
        assertEquals(RestRequest.Method.POST, request.method)
        assertEquals("rpc/rename_group", request.path)
        assertTrue(request.query.isEmpty())
        assertEquals("""{"p_group_id":"a0000000-0000-4000-8000-000000000001","p_name":"Coloc"}""", request.encodedBody())
        assertEquals("{}", RestQuery.rpc("delete_my_account").encodedBody())
    }

    @Test
    fun taskParametersAreAllExplicit() {
        val draft = TaskDraft(title = "  Titre  ", details = "   ", priority = TaskPriority.HIGH, dueAt = null, assigneeIds = setOf(Seed.lucas, Seed.camille))
        val params = TaskFields(draft).params("p_task_id" to JsonValues.uuid(task))
        assertEquals(
            """{"p_assignee_ids":["11111111-1111-4111-8111-111111111111","22222222-2222-4222-8222-222222222222"],""" +
                """"p_details":null,"p_due_at":null,"p_priority":"high","p_task_id":"b0000000-0000-4000-8000-000000000002",""" +
                """"p_title":"Titre"}""",
            RestQuery.rpc("update_task", params).encodedBody(),
        )
        val dated = TaskFields(TaskDraft(title = "T", details = "D", dueAt = now)).params()
        assertEquals(JsonPrimitive("2026-09-24T10:00:00.123456Z"), dated["p_due_at"])
        assertEquals(JsonPrimitive("D"), dated["p_details"])
        assertEquals(JsonArray(emptyList()), dated["p_assignee_ids"])
    }

    @Test
    fun percentEncodingKeepsPostgrestSyntaxAndEncodesPlusAndSpace() {
        assertEquals("2026-09-24T10:00:00.123456%2B02:00", RestRequest.percentEncoded("2026-09-24T10:00:00.123456+02:00"))
        assertEquals("a%20b%26c%3Dd%23%C3%A9", RestRequest.percentEncoded("a b&c=d#é"))
        assertEquals("*,assignees:task_assignees!inner(user_id)", RestRequest.percentEncoded("*,assignees:task_assignees!inner(user_id)"))
        assertEquals(
            "http://127.0.0.1:54321/rest/v1/tasks?select=*,assignees:task_assignees(user_id)&id=eq.b0000000-0000-4000-8000-000000000002",
            RestQuery.task(task).url("http://127.0.0.1:54321/rest/v1/"),
        )
    }

    /** Ktor sends the encoded query as built (no re-encoding of the PostgREST syntax, `%2B` kept). */
    @Test
    fun theHttpClientSendsTheEncodedQueryUnchanged() = runBlocking {
        val server = FakeServer(listOf(FakeServer.json(200, "[]")))
        val context = UnitBackend.context(server, credentials = FixedCredentials(me))
        val request = RestRequest(
            path = "tasks",
            query = listOf(
                RestRequest.QueryItem("select", RestQuery.TASK_SELECT),
                RestRequest.QueryItem("due_at", "gt.2026-09-24T10:00:00.123456+02:00"),
                RestRequest.QueryItem("title", "eq.a b&c=d#é"),
            ),
        )
        context.rest.response(request, FixedCredentials(me).credentials())
        assertEquals(request.encodedPathAndQuery, server.sent.single().encodedTarget)
        assertEquals(
            "tasks?select=*,assignees:task_assignees(user_id)&due_at=gt.2026-09-24T10:00:00.123456+02:00&title=eq.a b&c=d#é",
            server.sent.single().target,
        )
        context.close()
    }
}
