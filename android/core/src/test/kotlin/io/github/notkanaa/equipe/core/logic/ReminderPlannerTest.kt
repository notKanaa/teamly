package io.github.notkanaa.equipe.core.logic

import io.github.notkanaa.equipe.core.TaskStatus
import io.github.notkanaa.equipe.core.uuidString
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.time.Instant
import java.util.UUID
import io.github.notkanaa.equipe.core.logic.LogicFixtures as F

/** Port of the ReminderPlannerTests suite of Logic/ReminderTests.swift. */
class ReminderPlannerTest {
    private val planner = ReminderPlanner(F.parisCalendar)
    private val now: Instant = F.date(2026, 9, 24, 12, 0)

    @Test
    fun identifierFormat() {
        val taskId = UUID.fromString("3F2504E0-4F89-11D3-9A0C-0305E82C3301")
        val due = Instant.ofEpochSecond(1_790_000_000L, 750_000_000L)
        assertEquals("due-3F2504E0-4F89-11D3-9A0C-0305E82C3301-1790000000", ReminderPlanner.identifier(taskId, due))
        assertEquals(-1L, ReminderPlanner.epochSeconds(Instant.ofEpochMilli(-500)))
    }

    @Test
    fun buildsAFrenchReminder() {
        val task = F.task(1, title = "Sortir les poubelles", due = F.date(2026, 9, 24, 20, 0))
        val plan = planner.plan(listOf(task), F.me, ReminderLeadTime.ONE_HOUR, now)
        assertEquals(1, plan.size)
        val reminder = plan.first()
        assertEquals(ReminderPlanner.identifier(task.id, task.dueAt!!), reminder.id)
        assertTrue(reminder.id.startsWith("due-"))
        assertEquals("Échéance proche", reminder.title)
        assertEquals("Sortir les poubelles — Coloc' rue des Lilas, aujourd’hui à 20:00", reminder.body)
        assertEquals(F.date(2026, 9, 24, 19, 0), reminder.fireDate)
        assertEquals(mapOf("taskId" to task.id.uuidString, "groupId" to F.groupA.uuidString), reminder.userInfo)
        assertEquals(F.groupA.uuidString, reminder.threadId)
    }

    @Test
    fun wordingIsRelativeToTheFireDate() {
        // With "1 jour avant", the reminder is shown the day before: the due date reads "demain".
        val task = F.task(1, title = "Réserver le gymnase", due = F.date(2026, 9, 26, 9, 30), groupName = "Projet Asso Sport")
        val reminder = planner.plan(listOf(task), F.me, ReminderLeadTime.ONE_DAY, now).first()
        assertEquals("Réserver le gymnase — Projet Asso Sport, demain à 09:30", reminder.body)
        assertEquals(F.date(2026, 9, 25, 9, 30), reminder.fireDate)
    }

    @Test
    fun groupNameFallbacks() {
        val unnamed = F.task(1, title = "Payer le loyer", due = F.date(2026, 9, 24, 20, 0), groupName = null)
        val withFallback = planner.plan(listOf(unnamed), F.me, ReminderLeadTime.ONE_HOUR, now, mapOf(F.groupA to "Coloc"))
        assertEquals("Payer le loyer — Coloc, aujourd’hui à 20:00", withFallback.first().body)
        val withoutName = planner.plan(listOf(unnamed), F.me, ReminderLeadTime.ONE_HOUR, now)
        assertEquals("Payer le loyer, aujourd’hui à 20:00", withoutName.first().body)
        val emptyName = F.task(2, title = "Payer le loyer", due = F.date(2026, 9, 24, 20, 0), groupName = "")
        val withEmptyName = planner.plan(listOf(emptyName), F.me, ReminderLeadTime.ONE_HOUR, now, mapOf(F.groupA to "Coloc"))
        assertEquals("Payer le loyer — Coloc, aujourd’hui à 20:00", withEmptyName.first().body)
    }

    @Test
    fun keepsOnlyMyOpenTasksWithADueDate() {
        val due = F.date(2026, 9, 25, 10, 0)
        val tasks = listOf(
            F.task(1, due = due),
            F.task(2, status = TaskStatus.IN_PROGRESS, due = due),
            F.task(3, status = TaskStatus.DONE, due = due),
            F.task(4, due = null),
            F.task(5, due = due, assignees = listOf(F.other)),
            F.task(6, due = due, assignees = emptyList()),
        )
        val plan = planner.plan(tasks, F.me, ReminderLeadTime.ONE_HOUR, now)
        assertEquals(listOf(F.uuid(1).uuidString, F.uuid(2).uuidString), plan.map { it.userInfo["taskId"] })
    }

    @Test
    fun leadTimeOffPlansNothing() {
        val tasks = listOf(F.task(1, due = F.date(2026, 9, 25, 10, 0)))
        assertTrue(planner.plan(tasks, F.me, ReminderLeadTime.OFF, now).isEmpty())
    }

    @Test
    fun fireDateMustBeStrictlyInTheFuture() {
        val tasks = listOf(
            F.task(1, due = now.plusSeconds(3600)), // fires exactly now → skipped
            F.task(2, due = now.plusSeconds(3601)), // fires in 1 s → kept
            F.task(3, due = now.plusSeconds(1800)), // due in 30 min, fire date passed → skipped
            F.task(4, due = now.minusSeconds(60)), // overdue → skipped
        )
        val plan = planner.plan(tasks, F.me, ReminderLeadTime.ONE_HOUR, now)
        assertEquals(listOf(F.uuid(2).uuidString), plan.map { it.userInfo["taskId"] })
        // At due time, a task due in 1 s is kept; one due now is not.
        val atDue = planner.plan(
            listOf(F.task(5, due = now), F.task(6, due = now.plusSeconds(1))),
            F.me,
            ReminderLeadTime.AT_DUE_TIME,
            now,
        )
        assertEquals(listOf(F.uuid(6).uuidString), atDue.map { it.userInfo["taskId"] })
    }

    @Test
    fun sixtyIsKeptInFull() {
        val tasks = (1..60).map { F.task(it, due = now.plusSeconds(7200L + it * 60L)) }
        val plan = planner.plan(tasks, F.me, ReminderLeadTime.ONE_HOUR, now)
        assertEquals(60, plan.size)
    }

    @Test
    fun sixtyOneKeepsTheSixtySoonest() {
        // Built in reverse so the input order is not the fire order.
        val tasks = (1..61).reversed().map { F.task(it, due = now.plusSeconds(7200L + it * 60L)) }
        val plan = planner.plan(tasks, F.me, ReminderLeadTime.ONE_HOUR, now)
        assertEquals(ReminderPlanner.DEFAULT_MAX_PENDING, plan.size)
        assertEquals((1..60).map { F.uuid(it).uuidString }, plan.map { it.userInfo["taskId"] })
        assertFalse(plan.any { it.userInfo["taskId"] == F.uuid(61).uuidString })
        val fireDates = plan.mapNotNull { it.fireDate }
        assertEquals(fireDates.sorted(), fireDates)
    }

    @Test
    fun soonestFirstWithDeterministicTies() {
        val due = F.date(2026, 9, 25, 10, 0)
        val tasks = listOf(F.task(3, due = due), F.task(1, due = due.plusSeconds(60)), F.task(2, due = due))
        val plan = planner.plan(tasks, F.me, ReminderLeadTime.ONE_HOUR, now)
        assertEquals(
            listOf(F.uuid(2).uuidString, F.uuid(3).uuidString, F.uuid(1).uuidString),
            plan.map { it.userInfo["taskId"] },
        )
        val shuffled = planner.plan(tasks.reversed(), F.me, ReminderLeadTime.ONE_HOUR, now)
        assertEquals(plan, shuffled)
    }

    @Test
    fun duplicatedTasksAreScheduledOnce() {
        val task = F.task(1, due = F.date(2026, 9, 25, 10, 0))
        assertEquals(1, planner.plan(listOf(task, task), F.me, ReminderLeadTime.ONE_HOUR, now).size)
    }

    @Test
    fun customCap() {
        val small = ReminderPlanner(F.parisCalendar, maxPending = 2)
        val tasks = (1..5).map { F.task(it, due = now.plusSeconds(7200L + it)) }
        assertEquals(2, small.plan(tasks, F.me, ReminderLeadTime.ONE_HOUR, now).size)
        val none = ReminderPlanner(F.parisCalendar, maxPending = 0)
        assertTrue(none.plan(tasks, F.me, ReminderLeadTime.ONE_HOUR, now).isEmpty())
        assertEquals(0, ReminderPlanner(F.parisCalendar, maxPending = -3).maxPending)
    }
}
