package io.github.notkanaa.equipe.core.logic

import io.github.notkanaa.equipe.core.InMemoryKeyValueStore
import kotlinx.serialization.builtins.ListSerializer
import kotlinx.serialization.json.Json
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.time.Duration
import io.github.notkanaa.equipe.core.logic.LogicFixtures as F

/** Port of the ReminderLeadTimeTests suite of Logic/ReminderTests.swift. */
class ReminderLeadTimeTest {
    private val calendar = F.parisCalendar

    @Test
    fun defaultIsOneHour() {
        assertEquals(ReminderLeadTime.ONE_HOUR, ReminderLeadTime.DEFAULT)
        assertEquals(ReminderLeadTime.ONE_HOUR, ReminderLeadTime.load(InMemoryKeyValueStore()))
    }

    @Test
    fun frenchLabels() {
        assertEquals(
            listOf("À l’heure de l’échéance", "15 minutes avant", "1 heure avant", "1 jour avant", "Aucun rappel"),
            ReminderLeadTime.entries.map { it.label },
        )
    }

    @Test
    fun persistsInKeyValueStore() {
        val store = InMemoryKeyValueStore()
        for (leadTime in ReminderLeadTime.entries) {
            leadTime.save(store)
            assertEquals(leadTime, ReminderLeadTime.load(store))
        }
        // Same key and JSON value as the iOS app.
        ReminderLeadTime.ONE_DAY.save(store)
        assertEquals("\"oneDay\"", store.data("settings.reminderLeadTime")?.decodeToString())
    }

    @Test
    fun unreadableValueFallsBackToDefault() {
        val store = InMemoryKeyValueStore()
        store.set(ReminderLeadTime.STORAGE_KEY, "\"twoWeeks\"".encodeToByteArray())
        assertEquals(ReminderLeadTime.ONE_HOUR, ReminderLeadTime.load(store))
        store.set(ReminderLeadTime.STORAGE_KEY, byteArrayOf(0xFF.toByte(), 0x00))
        assertEquals(ReminderLeadTime.ONE_HOUR, ReminderLeadTime.load(store))
    }

    @Test
    fun codableUsesStableRawValues() {
        val serializer = ListSerializer(ReminderLeadTime.serializer())
        val json = Json.encodeToString(serializer, listOf(ReminderLeadTime.FIFTEEN_MINUTES, ReminderLeadTime.OFF))
        assertEquals("[\"fifteenMinutes\",\"off\"]", json)
        assertEquals(listOf(ReminderLeadTime.FIFTEEN_MINUTES, ReminderLeadTime.OFF), Json.decodeFromString(serializer, json))
        assertEquals(ReminderLeadTime.entries.map { it.rawValue }, ReminderLeadTime.entries.map { it.id })
        assertEquals(ReminderLeadTime.AT_DUE_TIME, ReminderLeadTime.fromRawValue("atDueTime"))
        assertNull(ReminderLeadTime.fromRawValue("twoWeeks"))
    }

    @Test
    fun fireDates() {
        val due = F.date(2026, 9, 24, 20, 0)
        assertEquals(due, ReminderLeadTime.AT_DUE_TIME.fireDate(due, calendar))
        assertEquals(F.date(2026, 9, 24, 19, 45), ReminderLeadTime.FIFTEEN_MINUTES.fireDate(due, calendar))
        assertEquals(F.date(2026, 9, 24, 19, 0), ReminderLeadTime.ONE_HOUR.fireDate(due, calendar))
        assertEquals(F.date(2026, 9, 23, 20, 0), ReminderLeadTime.ONE_DAY.fireDate(due, calendar))
        assertNull(ReminderLeadTime.OFF.fireDate(due, calendar))
        assertFalse(ReminderLeadTime.OFF.isEnabled)
        assertTrue(ReminderLeadTime.AT_DUE_TIME.isEnabled)
    }

    @Test
    fun oneDayKeepsTheWallClockTimeAcrossDST() {
        // Due Sunday 29 March 2026 20:00 (CEST): the day before at 20:00 (CET) is only 23 hours earlier.
        val due = F.date(2026, 3, 29, 20, 0)
        val fire = ReminderLeadTime.ONE_DAY.fireDate(due, calendar)!!
        assertEquals(F.date(2026, 3, 28, 20, 0), fire)
        assertEquals(Duration.ofHours(23), Duration.between(fire, due))
        // Due Sunday 25 October 2026 20:00 (CET): Saturday 20:00 (CEST) is 25 hours earlier.
        val fallDue = F.date(2026, 10, 25, 20, 0)
        val fallFire = ReminderLeadTime.ONE_DAY.fireDate(fallDue, calendar)!!
        assertEquals(F.date(2026, 10, 24, 20, 0), fallFire)
        assertEquals(Duration.ofHours(25), Duration.between(fallFire, fallDue))
    }
}
