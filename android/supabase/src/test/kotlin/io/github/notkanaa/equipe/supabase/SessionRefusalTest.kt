package io.github.notkanaa.equipe.supabase

import io.github.notkanaa.equipe.core.AppError
import io.github.notkanaa.equipe.supabase.FakeServer.Companion.failure
import io.github.notkanaa.equipe.supabase.FakeServer.Companion.fixture
import io.github.notkanaa.equipe.supabase.FakeServer.Companion.json
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * A request whose session the server refuses is sent again once after a refresh; a dead session is not. Account
 * deletion treats « account already gone » as done.
 */
class SessionRefusalTest {
    private val jwtRefused = """{"code":"PGRST301","details":null,"hint":null,"message":"JWT cryptographic operation failed"}"""
    private val accountGone = """{"code":"P0001","details":null,"hint":null,"message":"not_authenticated"}"""

    /** A token refused before its local expiry (signing key rotated, clock behind): refreshed, then sent again. */
    @Test
    fun refusedTokenIsRefreshedAndTheRequestSentAgain() = runBlocking {
        val credentials = ScriptedCredentials()
        val server = FakeServer(listOf(json(401, jwtRefused), fixture(200, "my_groups")))
        val groups = UnitBackend.services(server, credentials = credentials).groups.myGroups()
        assertEquals(listOf(Seed.lilas, Seed.sport), groups.map { it.id })
        assertEquals(1, credentials.refreshCount)
        assertEquals(listOf("Bearer jeton-1", "Bearer jeton-2"), server.sent.map { it.headers["authorization"] })
        assertEquals(server.sent[0].target, server.sent[1].target)
    }

    @Test
    fun rpcIsSentAgainWithTheSameBody() = runBlocking {
        val credentials = ScriptedCredentials()
        val server = FakeServer(listOf(json(401, jwtRefused), json(204, "")))
        UnitBackend.services(server, credentials = credentials).groups.leave(Seed.lilas)
        assertEquals(2, server.sent.size)
        assertEquals(server.sent[0].body, server.sent[1].body)
        assertEquals("Bearer jeton-2", server.sent[1].headers["authorization"])
    }

    /** A dead session (revoked, account deleted): the refresh fails (and signs the device out); no second request. */
    @Test
    fun deadSessionIsNotSentAgain() {
        val credentials = ScriptedCredentials(refreshError = AppError.NotAuthenticated)
        val server = FakeServer(listOf(json(400, accountGone)))
        val groups = UnitBackend.services(server, credentials = credentials).groups
        assertThrows(AppError.NotAuthenticated) { groups.createGroup("Encore") }
        assertEquals(1, credentials.refreshCount)
        assertEquals(1, server.sent.size)
    }

    @Test
    fun offlineRefreshIsANetworkError() {
        val credentials = ScriptedCredentials(refreshError = AppError.Network)
        val server = FakeServer(listOf(json(401, jwtRefused)))
        val groups = UnitBackend.services(server, credentials = credentials).groups
        assertThrows(AppError.Network) { groups.myGroups() }
        assertEquals(1, server.sent.size)
    }

    /** At most one refresh per request. */
    @Test
    fun secondRefusalIsFinal() {
        val credentials = ScriptedCredentials()
        val server = FakeServer(listOf(json(401, jwtRefused), json(401, jwtRefused)))
        val groups = UnitBackend.services(server, credentials = credentials).groups
        assertThrows(AppError.NotAuthenticated) { groups.myGroups() }
        assertEquals(1, credentials.refreshCount)
        assertEquals(2, server.sent.size)
    }

    /** Other errors never refresh. */
    @Test
    fun otherErrorsDoNotRefresh() {
        val credentials = ScriptedCredentials()
        val server = FakeServer(
            listOf(
                json(403, """{"code":"42501","details":null,"hint":null,"message":"forbidden"}"""),
                json(503, """{"code":"PGRST002","message":"Could not query the database for the schema cache. Retrying."}"""),
            ),
        )
        val groups = UnitBackend.services(server, credentials = credentials).groups
        assertThrows(AppError.Forbidden) { groups.leave(Seed.lilas) }
        assertThrows(AppError.Unknown(SupabaseErrorMapping.SERVER_UNAVAILABLE)) { groups.myGroups() }
        assertEquals(0, credentials.refreshCount)
        assertEquals(2, server.sent.size)
    }

    // region Account deletion

    /**
     * « Réessayer » after a lost answer: `delete_my_account` says the token's account no longer exists. That is the
     * requested end state: success, without a refresh.
     */
    @Test
    fun deletingAnAlreadyDeletedAccountSucceeds() = runBlocking {
        val credentials = ScriptedCredentials(refreshError = AppError.NotAuthenticated)
        val server = FakeServer(listOf(json(400, accountGone)))
        UnitBackend.services(server, credentials = credentials).auth.deleteAccount()
        assertEquals(0, credentials.refreshCount)
        assertEquals(listOf("rpc/delete_my_account"), server.sent.map { it.target })
        assertEquals("{}", server.sent.single().body)
    }

    @Test
    fun deletionWithARefusedTokenRefreshesOnce() = runBlocking {
        val credentials = ScriptedCredentials()
        val server = FakeServer(listOf(json(401, jwtRefused), json(204, "")))
        UnitBackend.services(server, credentials = credentials).auth.deleteAccount()
        assertEquals(1, credentials.refreshCount)
        assertEquals(listOf("Bearer jeton-1", "Bearer jeton-2"), server.sent.map { it.headers["authorization"] })
    }

    @Test
    fun deletionWithADeadSessionFails() {
        val credentials = ScriptedCredentials(refreshError = AppError.NotAuthenticated)
        val server = FakeServer(listOf(json(401, jwtRefused)))
        val auth = UnitBackend.services(server, credentials = credentials).auth
        assertThrows(AppError.NotAuthenticated) { auth.deleteAccount() }
        assertEquals(1, server.sent.size)
    }

    @Test
    fun deletionErrorsAreStillReported() {
        val server = FakeServer(listOf(failure()))
        val auth = UnitBackend.services(server, credentials = ScriptedCredentials()).auth
        assertThrows(AppError.Network) { auth.deleteAccount() }
    }

    // endregion
}

/** Forward compatibility of list reads: a value added to a server enum by a later migration leaves only its row out. */
class LossyDecodingTest {
    @Test
    fun unknownTaskStatusLeavesOnlyThatTaskOut() = runBlocking {
        val rows = Fixture.text("group_tasks")
        val newer = rows.replace(""""status":"in_progress"""", """"status":"blocked"""")
        assertTrue(newer != rows)
        val tasks = UnitBackend.services(FakeServer(listOf(json(200, newer)))).tasks.tasks(Seed.lilas, includeOldDone = true)
        assertEquals(4, tasks.size)
        assertFalse(tasks.any { it.id == Seed.courses })
        assertTrue(tasks.any { it.id == Seed.poubelles } && tasks.any { it.id == Seed.cuisine })
    }

    @Test
    fun unknownPriorityInMyTasks() = runBlocking {
        val rows = Fixture.text("my_tasks")
        val newer = rows.replace(""""priority":"high"""", """"priority":"urgent"""")
        assertTrue(newer != rows)
        val tasks = UnitBackend.services(FakeServer(listOf(json(200, newer)))).tasks.myTasks(includeDone = true)
        assertEquals(listOf(Seed.cuisine, Seed.courses), tasks.map { it.id })
    }

    @Test
    fun unknownRoleLeavesOnlyThatMembershipOut() = runBlocking {
        val original = Fixture.text("my_groups")
        val newer = original.replace(""""role":"member"""", """"role":"owner"""")
        assertTrue(newer != original)
        val groups = UnitBackend.services(FakeServer(listOf(json(200, newer)))).groups.myGroups()
        assertEquals(listOf(Seed.lilas), groups.map { it.id })

        val members = Fixture.text("members")
        val newerMembers = members.replace(""""role":"admin"""", """"role":"owner"""")
        val listed = UnitBackend.services(FakeServer(listOf(json(200, newerMembers)))).groups.members(Seed.lilas)
        assertEquals(listOf(Seed.ines, Seed.lucas), listed.map { it.user.id })
    }

    /** A single task (a link, an RPC result) with an unknown value is an unexpected answer, not « not found ». */
    @Test
    fun singleTaskWithAnUnknownValueIsAnError() {
        val body = """
            [{"id":"b0000000-0000-4000-8000-000000000002","group_id":"a0000000-0000-4000-8000-000000000001","title":"Faire les courses","details":null,"status":"blocked","priority":"medium","due_at":null,"created_by":null,"created_at":"2026-09-21T23:52:26+00:00","updated_at":"2026-09-21T23:52:26+00:00","completed_at":null,"assignees":[]}]
        """.trimIndent()
        val tasks = UnitBackend.services(FakeServer(listOf(json(200, body)))).tasks
        assertThrows(AppError.Unknown(SupabaseErrorMapping.UNEXPECTED_ANSWER)) { tasks.task(Seed.courses) }
    }

    /** Any other malformed row still fails the whole answer. */
    @Test
    fun otherMalformedRowsStillFail() {
        val rows = Fixture.text("group_tasks")
        val broken = rows.replace(""""title":"Sortir les poubelles"""", """"title":null""")
        assertTrue(broken != rows)
        val tasks = UnitBackend.services(FakeServer(listOf(json(200, broken)))).tasks
        assertThrows(AppError.Unknown(SupabaseErrorMapping.UNEXPECTED_ANSWER)) { tasks.tasks(Seed.lilas, includeOldDone = true) }
    }

    @Test
    fun skippedRowsAreCounted() {
        val json = """[{"role":"owner","group":{}},{"role":"admin","group":{"id":"a0000000-0000-4000-8000-000000000001","name":"G","created_by":null,"created_at":"2026-09-13T23:52:26+00:00","last_activity_at":"2026-09-13T23:52:26+00:00"}},{"role":"chef","group":{}}]"""
        val decoded = RestDecoding.decode(json.toByteArray()) { RestDecoding.lossyRows(it, MyGroupRow::decode) }
        assertEquals(listOf(io.github.notkanaa.equipe.core.MemberRole.ADMIN), decoded.rows.map { it.role })
        assertEquals(2, decoded.skipped)
    }
}
