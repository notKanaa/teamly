package io.github.notkanaa.equipe.supabase

import io.github.notkanaa.equipe.core.AppError
import io.github.notkanaa.equipe.core.InviteCode
import io.github.notkanaa.equipe.core.JoinResult
import io.github.notkanaa.equipe.core.MemberRole
import io.github.notkanaa.equipe.core.TaskDraft
import io.github.notkanaa.equipe.core.TaskPriority
import io.github.notkanaa.equipe.core.TaskStatus
import io.github.notkanaa.equipe.core.UserProfile
import io.github.notkanaa.equipe.supabase.FakeServer.Companion.failure
import io.github.notkanaa.equipe.supabase.FakeServer.Companion.fixture
import io.github.notkanaa.equipe.supabase.FakeServer.Companion.json
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.time.Instant

/** The services against a fake PostgREST: requests sent, validation before any call, results and errors. */
class ServiceUnitTest {
    // region Groups

    @Test
    fun myGroupsAreSortedByActivityThenName() = runBlocking {
        // Both seed groups have the same last_activity_at: NameOrder decides (Coloc' < Projet).
        val server = FakeServer(listOf(fixture(200, "my_groups")))
        val groups = UnitBackend.services(server).groups.myGroups()
        assertEquals(listOf(Seed.lilas, Seed.sport), groups.map { it.id })
        assertEquals(listOf(MemberRole.ADMIN, MemberRole.MEMBER), groups.map { it.myRole })
        val sent = server.sent.first()
        assertEquals("GET", sent.method)
        assertEquals("group_members?select=role,group:groups(*)&user_id=eq.11111111-1111-4111-8111-111111111111", sent.target)
        assertEquals("sb_publishable_test", sent.headers["apikey"])
        assertEquals("Bearer jeton-de-test", sent.headers["authorization"])
        assertEquals("application/json", sent.headers["accept"])
    }

    @Test
    fun membersAreSortedAdminsFirstThenName() = runBlocking {
        val json = """
            [{"user_id":"33333333-3333-4333-8333-333333333333","role":"member","joined_at":"2026-09-15T23:52:26+00:00","profile":{"id":"33333333-3333-4333-8333-333333333333","display_name":"inès Dubois"}},
             {"user_id":"22222222-2222-4222-8222-222222222222","role":"member","joined_at":"2026-09-14T23:52:26+00:00","profile":{"id":"22222222-2222-4222-8222-222222222222","display_name":"Ines Dubois"}},
             {"user_id":"11111111-1111-4111-8111-111111111111","role":"admin","joined_at":"2026-09-13T23:52:26+00:00","profile":{"id":"11111111-1111-4111-8111-111111111111","display_name":"Zoé"}}]
        """.trimIndent()
        val members = UnitBackend.services(FakeServer(listOf(json(200, json)))).groups.members(Seed.lilas)
        // Admin first; "Ines" and "inès" fold to the same key: exact order decides ("I" < "i").
        assertEquals(listOf(Seed.camille, Seed.lucas, Seed.ines), members.map { it.user.id })
    }

    @Test
    fun createGroupValidatesThenCallsTheRPC() = runBlocking {
        val server = FakeServer(listOf(fixture(200, "create_group")))
        val groups = UnitBackend.services(server).groups
        assertThrows(AppError.InvalidName) { groups.createGroup("   ") }
        assertThrows(AppError.InvalidName) { groups.createGroup("x".repeat(61)) }
        assertThrows(AppError.InvalidName) { groups.createGroup("a\u0000b") }
        assertTrue("invalid names never reach the server", server.sent.isEmpty())

        val summary = groups.createGroup("  Groupe fixture　")
        assertEquals(MemberRole.ADMIN, summary.myRole)
        assertEquals("Groupe fixture", summary.group.name)
        val sent = server.sent.first()
        assertEquals("POST", sent.method)
        assertEquals("rpc/create_group", sent.target)
        assertEquals("""{"p_name":"Groupe fixture"}""", sent.body)
        assertEquals("application/json", sent.headers["content-type"])
    }

    @Test
    fun joinSendsTheNormalizedCode() = runBlocking {
        val server = FakeServer(
            listOf(
                fixture(200, "join_joined"), fixture(200, "join_already_member"), fixture(200, "join_invalid_code"),
                json(400, """{"code":"P0001","details":null,"hint":null,"message":"rate_limited"}"""),
            ),
        )
        val groups = UnitBackend.services(server).groups
        val code = InviteCode.parse(" sprt-5678 ")!!
        assertEquals(JoinResult(Seed.sport, "Projet Asso Sport", alreadyMember = false), groups.join(code))
        assertEquals("""{"p_code":"SPRT5678"}""", server.sent.first().body)
        assertTrue(groups.join(code).alreadyMember)
        assertThrows(AppError.InvalidCode) { groups.join(code) }
        assertThrows(AppError.RateLimited) { groups.join(code) }
    }

    @Test
    fun inviteCodeIsForbiddenWithoutRows() = runBlocking {
        val server = FakeServer(listOf(json(200, "[]"), fixture(200, "invite_code"), fixture(200, "regenerate")))
        val groups = UnitBackend.services(server).groups
        assertThrows(AppError.Forbidden) { groups.inviteCode(Seed.sport) }
        assertEquals("LYLAS234", groups.inviteCode(Seed.lilas).value)
        assertEquals("NYCXWUA4", groups.regenerateInviteCode(Seed.lilas).value)
        assertEquals("""{"p_group_id":"a0000000-0000-4000-8000-000000000001"}""", server.sent.last().body)
    }

    @Test
    fun unexpectedInviteCodesAreRefused() = runBlocking {
        val server = FakeServer(listOf(json(200, """[{"code":"lylas234"}]"""), json(200, "\"TOO-SHORT\"")))
        val groups = UnitBackend.services(server).groups
        assertThrows(AppError.Unknown("code d’invitation inattendu")) { groups.inviteCode(Seed.lilas) }
        assertThrows(AppError.Unknown("code d’invitation inattendu")) { groups.regenerateInviteCode(Seed.lilas) }
    }

    @Test
    fun memberRPCsUseNamedParameters() = runBlocking {
        val server = FakeServer(listOf(json(204, ""), json(204, ""), json(204, ""), json(200, "null")))
        val groups = UnitBackend.services(server).groups
        groups.setRole(Seed.lilas, Seed.lucas, MemberRole.ADMIN)
        groups.removeMember(Seed.lilas, Seed.ines)
        groups.leave(Seed.sport)
        groups.deleteGroup(Seed.sport)
        assertEquals(listOf("rpc/set_member_role", "rpc/remove_member", "rpc/leave_group", "rpc/delete_group"), server.sent.map { it.target })
        assertEquals(
            """{"p_group_id":"a0000000-0000-4000-8000-000000000001","p_role":"admin","p_user_id":"22222222-2222-4222-8222-222222222222"}""",
            server.sent[0].body,
        )
        assertEquals(
            """{"p_group_id":"a0000000-0000-4000-8000-000000000001","p_user_id":"33333333-3333-4333-8333-333333333333"}""",
            server.sent[1].body,
        )
    }

    @Test
    fun serverErrorsAreMapped() = runBlocking {
        val server = FakeServer(
            listOf(
                json(400, """{"code":"P0001","details":null,"hint":null,"message":"last_admin"}"""),
                json(403, """{"code":"42501","details":null,"hint":null,"message":"forbidden"}"""),
                json(401, """{"code":"42501","details":null,"hint":null,"message":"permission denied for function leave_group"}"""),
                json(400, """{"code":"P0001","details":null,"hint":null,"message":"group_not_found"}"""),
                failure(),
            ),
        )
        val groups = UnitBackend.services(server).groups
        assertThrows(AppError.LastAdmin) { groups.leave(Seed.lilas) }
        assertThrows(AppError.Forbidden) { groups.leave(Seed.lilas) }
        assertThrows(AppError.NotAuthenticated) { groups.leave(Seed.lilas) }
        assertThrows(AppError.NotFound) { groups.rename(Seed.lilas, "Nom") }
        assertThrows(AppError.Network) { groups.myGroups() }
    }

    // endregion

    // region Tasks

    @Test
    fun createTaskValidatesInServerOrderBeforeAnyCall() {
        val server = FakeServer()
        val tasks = UnitBackend.services(server).tasks
        assertThrows(AppError.InvalidTitle) { tasks.create(Seed.lilas, TaskDraft(title = "a\u0000", details = "x".repeat(5001))) }
        assertThrows(AppError.InvalidDetails) { tasks.create(Seed.lilas, TaskDraft(title = "Titre", details = "d\u0000")) }
        assertThrows(AppError.InvalidInput) { tasks.create(Seed.lilas, TaskDraft(title = "Titre", dueAt = Instant.ofEpochSecond(-1))) }
        assertThrows(AppError.InvalidInput) {
            tasks.update(Seed.courses, TaskDraft(title = "Titre", dueAt = Instant.ofEpochSecond(253_402_300_800)))
        }
        assertTrue(server.sent.isEmpty())
    }

    @Test
    fun createTaskCompletesTheBareRowWithTheDraftAssignees() = runBlocking {
        val server = FakeServer(listOf(fixture(200, "create_task")))
        val draft = TaskDraft(
            title = " Tâche fixture ", details = "", priority = TaskPriority.HIGH, dueAt = Instant.ofEpochSecond(1_924_992_000),
            assigneeIds = setOf(Seed.lucas, Seed.camille),
        )
        val task = UnitBackend.services(server).tasks.create(Seed.lilas, draft)
        assertEquals(listOf(Seed.camille, Seed.lucas), task.assigneeIds)
        assertEquals("Tâche fixture", task.title)
        assertTrue(task.myAssignedAt == null && task.groupName == null)
        val sent = server.sent.first()
        assertEquals("rpc/create_task", sent.target)
        assertEquals(
            """{"p_assignee_ids":["11111111-1111-4111-8111-111111111111","22222222-2222-4222-8222-222222222222"],""" +
                """"p_details":null,"p_due_at":"2031-01-01T00:00:00.000000Z","p_group_id":"a0000000-0000-4000-8000-000000000001",""" +
                """"p_priority":"high","p_title":"Tâche fixture"}""",
            sent.body,
        )
    }

    @Test
    fun updateTaskSendsTheFullDraft() = runBlocking {
        val server = FakeServer(listOf(fixture(200, "create_task")))
        val draft = TaskDraft(title = "Titre", details = " Détails ", priority = TaskPriority.LOW, dueAt = null, assigneeIds = emptySet())
        val task = UnitBackend.services(server).tasks.update(Seed.courses, draft)
        assertTrue(task.assigneeIds.isEmpty())
        assertEquals("rpc/update_task", server.sent.first().target)
        assertEquals(
            """{"p_assignee_ids":[],"p_details":"Détails","p_due_at":null,""" +
                """"p_priority":"low","p_task_id":"b0000000-0000-4000-8000-000000000002","p_title":"Titre"}""",
            server.sent.first().body,
        )
    }

    @Test
    fun setStatusReadsTheAssigneesOfTheTask() = runBlocking {
        val read = """
            [{"id":"94d0d49f-a303-4611-9621-ced98f3d9086","group_id":"e82a930a-a452-4f1c-9884-fbff6d79b8f2","title":"Tâche fixture",
            "details":null,"status":"done","priority":"high","due_at":"2031-01-01T00:00:00+00:00",
            "created_by":"214442fe-11cc-44fe-949d-af4109d9d950","created_at":"2026-09-24T00:24:04.369866+00:00",
            "updated_at":"2026-09-24T00:24:04.385321+00:00","completed_at":"2026-09-24T00:24:04.385321+00:00",
            "assignees":[{"user_id":"33333333-3333-4333-8333-333333333333"},{"user_id":"11111111-1111-4111-8111-111111111111"}]}]
        """.trimIndent()
        val server = FakeServer(listOf(fixture(200, "set_task_status"), json(200, read)))
        val taskId = uuid("94d0d49f-a303-4611-9621-ced98f3d9086")
        val task = UnitBackend.services(server).tasks.setStatus(taskId, TaskStatus.DONE)
        assertEquals(TaskStatus.DONE, task.status)
        assertEquals(listOf(Seed.camille, Seed.ines), task.assigneeIds)
        assertTrue(task.completedAt != null)
        assertEquals(
            listOf("rpc/set_task_status", "tasks?select=*,assignees:task_assignees(user_id)&id=eq.94d0d49f-a303-4611-9621-ced98f3d9086"),
            server.sent.map { it.target },
        )
        assertEquals("""{"p_status":"done","p_task_id":"94d0d49f-a303-4611-9621-ced98f3d9086"}""", server.sent[0].body)
    }

    @Test
    fun setStatusOfATaskDeletedRightAfterHasNoAssignees() = runBlocking {
        val server = FakeServer(listOf(fixture(200, "set_task_status"), json(200, "[]")))
        val task = UnitBackend.services(server).tasks.setStatus(uuid("94d0d49f-a303-4611-9621-ced98f3d9086"), TaskStatus.DONE)
        assertTrue(task.assigneeIds.isEmpty())
    }

    @Test
    fun groupTasksUseTheOldDoneCutoffUnlessIncluded() = runBlocking {
        val server = FakeServer(listOf(fixture(200, "group_tasks"), fixture(200, "group_tasks")))
        val tasks = UnitBackend.services(server).tasks
        val recent = tasks.tasks(Seed.lilas, includeOldDone = false)
        tasks.tasks(Seed.lilas, includeOldDone = true)
        assertEquals(5, recent.size)
        assertTrue(recent.zipWithNext().all { (a, b) -> a.createdAt <= b.createdAt })
        assertTrue(server.sent[0].target.endsWith("&or=(status.neq.done,completed_at.gte.2026-08-25T10:00:00.123456Z)"))
        assertTrue(!server.sent[1].target.contains("or="))
    }

    @Test
    fun oneTaskIsNotFoundWithoutRows() {
        val server = FakeServer(listOf(json(200, "[]")))
        assertThrows(AppError.NotFound) { UnitBackend.services(server).tasks.task(Seed.courses) }
    }

    @Test
    fun assignmentsSendSinceWithMicroseconds() = runBlocking {
        val server = FakeServer(listOf(fixture(200, "assignments")))
        val since = PostgresTimestamp.instant(1_789_343_546_878_215L)
        val events = UnitBackend.services(server).tasks.assignments(since)
        assertEquals(3, events.size)
        assertTrue(server.sent.first().target.contains("&assigned_at=gt.2026-09-13T23:52:26.878215Z&"))
    }

    @Test
    fun myTasksFilterDoneTasks() = runBlocking {
        val server = FakeServer(listOf(fixture(200, "my_tasks")))
        val tasks = UnitBackend.services(server).tasks.myTasks(includeDone = false)
        assertTrue(tasks.all { it.groupName != null && it.myAssignedAt != null })
        assertTrue(server.sent.first().target.endsWith("&status=neq.done"))
    }

    // endregion

    // region Profile & push

    @Test
    fun updateDisplayNameIsAPatch() = runBlocking {
        val server = FakeServer(
            listOf(json(200, """[{"id":"11111111-1111-4111-8111-111111111111","display_name":"Camille M."}]"""), json(200, "[]")),
        )
        val profiles = UnitBackend.services(server).profiles
        assertThrows(AppError.InvalidDisplayName) { profiles.updateDisplayName(" ​ ") }
        assertEquals(UserProfile(Seed.camille, "Camille M."), profiles.updateDisplayName("  Camille M.  "))
        val sent = server.sent.first()
        assertEquals("PATCH", sent.method)
        assertEquals("profiles?select=id,display_name&id=eq.11111111-1111-4111-8111-111111111111", sent.target)
        assertEquals("return=representation", sent.headers["prefer"])
        assertEquals("""{"display_name":"Camille M."}""", sent.body)
        assertThrows(AppError.Forbidden) { profiles.updateDisplayName("Camille") }
    }

    @Test
    fun myProfileWithoutRowMeansTheAccountIsGone() = runBlocking {
        val server = FakeServer(listOf(fixture(200, "profile"), json(200, "[]")))
        val profiles = UnitBackend.services(server).profiles
        assertEquals(UserProfile(Seed.camille, "Camille Martin"), profiles.myProfile())
        assertThrows(AppError.NotAuthenticated) { profiles.myProfile() }
    }

    @Test
    fun pushTopic() = runBlocking {
        val server = FakeServer(listOf(json(200, "[]"), json(200, "\"equipe-abcdefghijklmnopqrstuvwx\""), json(204, "")))
        val push = UnitBackend.services(server).push
        assertNull(push.currentTopic())
        assertEquals("equipe-abcdefghijklmnopqrstuvwx", push.enable())
        push.disable()
        assertEquals(
            listOf("push_subscriptions?select=topic&user_id=eq.11111111-1111-4111-8111-111111111111", "rpc/enable_push", "rpc/disable_push"),
            server.sent.map { it.target },
        )
    }

    // endregion

    // region Signed out

    /** Without a local session, the adapters answer NotAuthenticated without calling the server. */
    @Test
    fun signedOutCallsNeverReachTheServer() {
        val server = FakeServer()
        val services = UnitBackend.signedOutServices(server)
        assertThrows(AppError.NotAuthenticated) { services.groups.myGroups() }
        assertThrows(AppError.NotAuthenticated) { services.groups.createGroup("Groupe") }
        assertThrows(AppError.NotAuthenticated) { services.profiles.myProfile() }
        assertThrows(AppError.NotAuthenticated) { services.tasks.myTasks(includeDone = true) }
        assertThrows(AppError.NotAuthenticated) { services.push.enable() }
        assertThrows(AppError.NotAuthenticated) { services.auth.deleteAccount() }
        assertTrue(server.sent.isEmpty())
        assertTrue(server.authRequests.isEmpty())
    }

    // endregion
}
