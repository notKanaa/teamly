package io.github.notkanaa.equipe.core

import kotlinx.serialization.Serializable
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.time.Instant
import java.time.LocalDate
import java.time.LocalTime
import java.time.ZoneId
import java.util.UUID

class ModelsAndPortsTest {
    private val t0: Instant = Instant.parse("2026-09-24T10:00:00Z")

    @Test
    fun rawValuesMatchTheSqlEnums() {
        assertEquals(listOf("admin", "member"), MemberRole.entries.map { it.rawValue })
        assertEquals(listOf("todo", "in_progress", "done"), TaskStatus.entries.map { it.rawValue })
        assertEquals(listOf("low", "medium", "high"), TaskPriority.entries.map { it.rawValue })
        assertEquals(TaskStatus.IN_PROGRESS, TaskStatus.fromRawValue("in_progress"))
        assertNull(MemberRole.fromRawValue("owner"))
        assertTrue(TaskPriority.LOW < TaskPriority.MEDIUM && TaskPriority.MEDIUM < TaskPriority.HIGH)
        assertEquals(listOf(0, 1, 2), TaskPriority.entries.map { it.rank })
    }

    @Test
    fun draftOfATask() {
        val a = UUID.randomUUID()
        val task = TaskItem(
            id = UUID.randomUUID(), groupId = UUID.randomUUID(), title = "Payer le loyer", priority = TaskPriority.HIGH,
            dueAt = t0, createdBy = null, createdAt = t0, updatedAt = t0, assigneeIds = listOf(a),
        )
        assertEquals(TaskDraft("Payer le loyer", "", TaskPriority.HIGH, t0, setOf(a)), TaskDraft(task))
        assertEquals(TaskStatus.TODO, task.status)
        assertEquals(TaskDraft(title = "", details = "", priority = TaskPriority.MEDIUM), TaskDraft())
    }

    @Test
    fun authStateUser() {
        val user = AuthUser(UUID.randomUUID(), "camille@example.com")
        assertEquals(user, AuthState.SignedIn(user).user)
        assertNull(AuthState.SignedOut.user)
        assertNull(AuthState.Unknown.user)
    }

    @Test
    fun uuidStringIsUpperCaseAndOrdersLikeSwift() {
        val low = UUID.fromString("10000000-0000-4000-8000-00000000000a")
        val high = UUID.fromString("80000000-0000-4000-8000-000000000000")
        assertEquals("10000000-0000-4000-8000-00000000000A", low.uuidString)
        assertTrue(high < low) // signed comparison: not the contract order
        assertEquals(listOf(low, high), listOf(high, low).sortedWith(UuidStringOrder))
    }

    @Test
    fun codePointHelpers() {
        assertEquals(2, "a😀".codePointLength())
        // UTF-16 order would put U+1F600 (surrogates D83D…) before U+FF01; code point order does not.
        assertTrue(compareCodePoints("😀", "！") > 0)
        assertEquals(0, compareLikeSwift("é", "é"))
    }

    @Serializable
    private data class Stored(val name: String, val count: Int)

    @Test
    fun inMemoryStoreAndJsonHelpers() {
        val store = InMemoryKeyValueStore()
        val bytes = byteArrayOf(1, 2, 3)
        store.set("k", bytes)
        bytes[0] = 9
        assertArrayEquals(byteArrayOf(1, 2, 3), store.data("k"))
        store.data("k")!![0] = 9
        assertArrayEquals(byteArrayOf(1, 2, 3), store.data("k"))
        store.set("k", null)
        assertNull(store.data("k"))

        store.setValue("stored", Stored("x", 2))
        assertEquals(Stored("x", 2), store.value<Stored>("stored"))
        store.setValue("map", mapOf("a" to "b"))
        assertEquals(mapOf("a" to "b"), store.value<Map<String, String>>("map"))
        store.set("bad", byteArrayOf(0xFF.toByte(), 0x00))
        assertNull(store.value<Stored>("bad"))
        store.setValue<Stored>("stored", null)
        assertNull(store.data("stored"))
    }

    @Test
    fun frenchCalendarInParis() {
        val calendar = AppCalendar.frenchGregorian(AppCalendar.PARIS)
        assertEquals(java.util.Locale.FRANCE, calendar.locale)
        assertEquals(java.time.DayOfWeek.MONDAY, calendar.weekFields.firstDayOfWeek)
        assertEquals(4, calendar.weekFields.minimalDaysInFirstWeek)
        // 2026-03-29: DST starts in Paris (02:00 → 03:00).
        val day = LocalDate.of(2026, 3, 29)
        assertEquals(Instant.parse("2026-03-28T23:00:00Z"), calendar.startOfDay(day))
        assertEquals(Instant.parse("2026-03-29T18:00:00Z"), calendar.instant(day, LocalTime.of(20, 0)))
        assertEquals(day, calendar.localDate(Instant.parse("2026-03-29T21:59:59Z")))
        assertTrue(calendar.isSameDay(Instant.parse("2026-03-28T23:00:00Z"), Instant.parse("2026-03-29T21:59:59Z")))
        assertEquals(ZoneId.of("Europe/Paris"), calendar.zone)
    }

    @Test
    fun platformServicesDefaults() {
        val fixed = { t0 }
        val services = PlatformServices(
            notifications = object : NotificationScheduler {
                override suspend fun authorizationStatus() = NotificationAuthorization.AUTHORIZED
                override suspend fun requestAuthorization() = true
                override suspend fun pendingIdentifiers(prefix: String) = emptyList<String>()
                override suspend fun add(notification: LocalNotification) {}
                override suspend fun removePending(ids: List<String>) {}
                override suspend fun setBadge(count: Int) {}
            },
            store = InMemoryKeyValueStore(),
            now = fixed,
            calendar = AppCalendar.frenchGregorian(AppCalendar.PARIS),
        )
        assertEquals(t0, services.now())
        assertEquals(LocalNotification("due-x", "T", "B"), LocalNotification("due-x", "T", "B", null, emptyMap(), null))
    }
}
