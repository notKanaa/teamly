package io.github.notkanaa.equipe.mocks

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.time.Duration
import java.time.Instant
import java.time.temporal.ChronoUnit
import java.util.UUID

/**
 * DemoData against the canonical `supabase/seed.sql` (docs/CONTRACTS.md §8): every seeded row of the mock, written the
 * way the seed writes it (ids, texts, enums, `now() - interval 'N days'`, Paris wall-clock times), must be a row of
 * the seed, and the seed has no other row.
 */
class SeedParityTest {
    /** The seed without comments and casts, whitespace collapsed. */
    private val sql: String = repositoryFile("supabase/seed.sql").readLines()
        .joinToString(" ") { it.substringBefore("--") }
        .replace(Regex("::[a-zA-Z_.]+"), "")
        .replace(Regex("\\s+"), " ")

    private val now: Instant = TestDates.parisDate(2026, 9, 23, 10)
    private val data = BackendData().also { DemoData.seed(it, now, DemoData.calendar) }

    private fun literal(value: String?): String = if (value == null) "null" else "'" + value.replace("'", "''") + "'"

    private fun id(value: UUID?): String = literal(value?.toString())

    /** `now() - interval 'N days'`: exactly N × 24 hours before the seed time. */
    private fun ago(instant: Instant): String {
        val seconds = Duration.between(instant, now).seconds
        assertEquals("$instant is a whole number of days before $now", 0L, seconds % 86_400)
        return "now() - interval '${seconds / 86_400} days'"
    }

    /** `(paris.today [± N] + time 'HH:MM') at time zone 'Europe/Paris'`, or `null`. */
    private fun wallClock(instant: Instant?): String {
        if (instant == null) return "null"
        val calendar = DemoData.calendar
        val days = ChronoUnit.DAYS.between(calendar.localDate(now), calendar.localDate(instant))
        val time = calendar.zonedDateTime(instant).toLocalTime()
        val offset = when {
            days > 0 -> " + $days"
            days < 0 -> " - ${-days}"
            else -> ""
        }
        return "(paris.today$offset + time '${"%02d:%02d".format(time.hour, time.minute)}') at time zone 'Europe/Paris'"
    }

    private fun assertRow(row: String) {
        assertTrue("supabase/seed.sql has no row $row", sql.contains(row))
    }

    private fun occurrences(fragment: String): Int = sql.windowed(fragment.length).count { it == fragment }

    @Test
    fun usersMatchTheSeed() {
        assertEquals(DemoData.users.map { it.id }.toSet(), data.accounts.keys)
        for (user in DemoData.users) {
            assertRow("(${id(user.id)}, ${literal(user.email)}, ${literal(user.displayName)})")
            assertEquals("now() - interval '30 days'", ago(data.accounts.getValue(user.id).createdAt))
            assertEquals(DemoData.password, data.accounts.getValue(user.id).password)
        }
        assertTrue("password", sql.contains("crypt(${literal(DemoData.password)}"))
        assertTrue("accounts created 30 days ago", sql.contains("now() - interval '30 days'"))
        // The newcomer of `emptyGroups` is a mock-only account.
        assertFalse(sql.contains(DemoData.newcomer.email))
        assertFalse(sql.contains(DemoData.newcomer.id.toString()))
    }

    @Test
    fun groupsInvitesAndMembersMatchTheSeed() {
        assertEquals(setOf(DemoData.lilasGroupId, DemoData.sportGroupId), data.groups.keys)
        for (group in data.groups.values) {
            // The seed inserts last_activity_at = created_at; the AFTER triggers of the seeded rows then bump it to
            // now(), the value the mock stores directly.
            assertRow("(${id(group.id)}, ${literal(group.name)}, ${id(group.createdBy)}, ${ago(group.createdAt)}, ${ago(group.createdAt)})")
            assertEquals(now, group.lastActivityAt)
            val invite = data.invites.getValue(group.id)
            assertRow("(${id(group.id)}, ${literal(invite.code)}, ${id(invite.createdBy)}, ${ago(invite.createdAt)})")
        }
        val members = data.members.values.flatMap { it.values }
        assertEquals(5, members.size)
        for (member in members) {
            assertRow("(${id(member.groupId)}, ${id(member.userId)}, ${literal(member.role.rawValue)}, ${ago(member.joinedAt)})")
        }
        // Group, member and invite rows are the only ones starting with a group id.
        assertEquals(data.groups.size + members.size + data.invites.size, occurrences("('a0000000-"))
        for (profile in data.profiles.values) assertEquals(now, profile.membershipsChangedAt)
    }

    @Test
    fun tasksAndAssigneesMatchTheSeed() {
        assertEquals(7, data.tasks.size)
        for (task in data.tasks.values) {
            assertEquals(task.createdAt, task.updatedAt)
            assertRow(
                "(${id(task.id)}, ${id(task.groupId)}, ${literal(task.title)}, ${literal(task.details)}, " +
                    "${literal(task.status.rawValue)}, ${literal(task.priority.rawValue)}, ${wallClock(task.dueAt)}, " +
                    "${id(task.createdBy)}, ${ago(task.createdAt)}, ${wallClock(task.completedAt)})",
            )
        }
        val rows = data.assignees.values.flatMap { it.values }
        assertEquals(7, rows.size)
        for (row in rows) {
            assertRow("(${id(row.taskId)}, ${id(row.groupId)}, ${id(row.userId)}, ${id(row.assignedBy)}, ${ago(row.assignedAt)})")
        }
        // Task and assignee rows are the only ones starting with a task id.
        assertEquals(data.tasks.size + rows.size, occurrences("('b0000000-"))
    }
}
