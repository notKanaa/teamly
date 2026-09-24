package io.github.notkanaa.equipe.supabase

import io.github.notkanaa.equipe.core.RealtimeEvent
import io.github.notkanaa.equipe.supabase.RealtimeBindings.SystemStatus
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.UUID

/** §6 bindings: ≤ 60 group ids, payload → RealtimeEvent, `system` status → Connected / failure. */
class RealtimeBindingsTest {
    @Test
    fun filtersAreThoseOfTheContract() {
        val bindings = RealtimeBindings(Seed.camille, listOf(Seed.lilas, Seed.sport))
        assertEquals("id=in.(a0000000-0000-4000-8000-000000000001,a0000000-0000-4000-8000-000000000002)", bindings.groupsFilter)
        assertEquals("id=eq.11111111-1111-4111-8111-111111111111", bindings.profilesFilter)
        assertEquals("user_id=eq.11111111-1111-4111-8111-111111111111", bindings.assigneesFilter)
        assertEquals("id=in.()", RealtimeBindings(Seed.camille, emptyList()).groupsFilter)
    }

    @Test
    fun groupIdsAreCappedAtSixtyLowerCaseAndUnique() {
        val ids = List(70) { UUID.randomUUID() }
        val bindings = RealtimeBindings(Seed.camille, listOf(ids[0]) + ids)
        assertEquals("the first 60 given ids, one of them twice", 59, bindings.groupIds.size)
        assertEquals(ids.take(59).map { it.toString().lowercase() }, bindings.groupIds)
        assertEquals("11111111-1111-4111-8111-111111111111", bindings.me)
        assertEquals(60, RealtimeBindings(Seed.camille, ids).groupIds.size)
        assertTrue(RealtimeBindings(Seed.camille, emptyList()).groupIds.isEmpty())
        val upper = RealtimeBindings(Seed.camille, listOf(UUID.fromString("A0000000-0000-4000-8000-00000000000A")))
        assertEquals(listOf("a0000000-0000-4000-8000-00000000000a"), upper.groupIds)
    }

    @Test
    fun groupsUpdateIsGroupActivity() {
        val record = JsonObject(
            mapOf(
                "id" to JsonPrimitive("a0000000-0000-4000-8000-000000000001"),
                "name" to JsonPrimitive("Coloc' rue des Lilas"),
                "last_activity_at" to JsonPrimitive("2026-09-24T00:24:04.385321+00:00"),
            ),
        )
        assertEquals(RealtimeEvent.GroupActivity(Seed.lilas), RealtimeBindings.groupActivity(record))
        assertNull(RealtimeBindings.groupActivity(JsonObject(emptyMap())))
        assertNull(RealtimeBindings.groupActivity(JsonObject(mapOf("id" to JsonPrimitive(42)))))
    }

    @Test
    fun taskAssigneesInsertIsAssigned() {
        val record = mutableMapOf(
            "task_id" to JsonPrimitive("b0000000-0000-4000-8000-000000000002"),
            "group_id" to JsonPrimitive("a0000000-0000-4000-8000-000000000001"),
            "user_id" to JsonPrimitive("11111111-1111-4111-8111-111111111111"),
            "assigned_by" to JsonPrimitive("22222222-2222-4222-8222-222222222222"),
            "assigned_at" to JsonPrimitive("2026-09-21T23:52:26.878215+00:00"),
        )
        assertEquals(RealtimeEvent.Assigned(Seed.courses, Seed.lilas, Seed.lucas), RealtimeBindings.assigned(JsonObject(record)))
        val withoutAssigner = JsonObject(record + ("assigned_by" to JsonNull))
        assertEquals(RealtimeEvent.Assigned(Seed.courses, Seed.lilas, null), RealtimeBindings.assigned(withoutAssigner))
        assertNull(RealtimeBindings.assigned(JsonObject(record - "task_id")))
    }

    /** Only the Postgres subscription confirmation is Connected (not the join reply); errors are failures. */
    @Test
    fun systemMessages() {
        assertEquals(SystemStatus.SUBSCRIBED, RealtimeBindings.systemStatus("ok", "postgres_changes"))
        assertEquals(SystemStatus.SUBSCRIBED, RealtimeBindings.systemStatus("ok", null))
        assertEquals(SystemStatus.FAILED, RealtimeBindings.systemStatus("error", "postgres_changes"))
        assertEquals(SystemStatus.FAILED, RealtimeBindings.systemStatus("error", "system"))
        assertEquals(SystemStatus.OTHER, RealtimeBindings.systemStatus("ok", "presence"))
        assertEquals(SystemStatus.OTHER, RealtimeBindings.systemStatus(null, null))
    }
}
