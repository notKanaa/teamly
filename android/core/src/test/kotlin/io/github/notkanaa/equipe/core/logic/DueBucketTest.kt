package io.github.notkanaa.equipe.core.logic

import io.github.notkanaa.equipe.core.TaskPriority
import io.github.notkanaa.equipe.core.TaskStatus
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.time.DayOfWeek
import java.time.Duration
import java.time.Instant
import io.github.notkanaa.equipe.core.logic.LogicFixtures as F

/** Port of Logic/DueBucketTests.swift. */
class DueBucketTest {
    private val calendar = F.parisCalendar

    private fun bucket(due: Instant?, status: TaskStatus = TaskStatus.TODO, now: Instant): DueBucket =
        DueBucket.bucket(F.task(1, status = status, due = due), now, calendar)

    @Test
    fun frenchTitlesInDisplayOrder() {
        assertEquals(
            listOf("En retard", "Aujourd’hui", "Cette semaine", "Plus tard", "Sans échéance", "Terminées"),
            DueBucket.entries.map { it.title },
        )
        assertEquals(DueBucket.entries, DueBucket.entries.sorted())
        assertEquals(listOf(0, 1, 2, 3, 4, 5), DueBucket.entries.map { it.id })
    }

    @Test
    fun midweekBoundaries() {
        // Thursday 24 September 2026, 12:00 (Paris). The week ends on Sunday 27 at midnight.
        val now = F.date(2026, 9, 24, 12, 0)
        assertEquals(DueBucket.OVERDUE, bucket(F.date(2026, 9, 24, 11, 59), now = now))
        assertEquals(DueBucket.OVERDUE, bucket(F.date(2026, 9, 20), now = now))
        assertEquals(DueBucket.TODAY, bucket(now, now = now))
        assertEquals(DueBucket.TODAY, bucket(F.date(2026, 9, 24, 23, 59, 59), now = now))
        assertEquals(DueBucket.THIS_WEEK, bucket(F.date(2026, 9, 25, 0, 0), now = now))
        assertEquals(DueBucket.THIS_WEEK, bucket(F.date(2026, 9, 27, 23, 59, 59), now = now))
        assertEquals(DueBucket.LATER, bucket(F.date(2026, 9, 28, 0, 0), now = now))
        assertEquals(DueBucket.LATER, bucket(F.date(2027, 1, 1), now = now))
        assertEquals(DueBucket.NO_DUE_DATE, bucket(null, now = now))
        assertEquals(DueBucket.DONE, bucket(F.date(2026, 9, 20), status = TaskStatus.DONE, now = now))
        assertEquals(DueBucket.DONE, bucket(null, status = TaskStatus.DONE, now = now))
        assertEquals(DueBucket.THIS_WEEK, bucket(F.date(2026, 9, 25), status = TaskStatus.IN_PROGRESS, now = now))
    }

    @Test
    fun nowExactlyAtMidnight() {
        val now = F.date(2026, 9, 28, 0, 0) // Monday 00:00
        assertEquals(DueBucket.OVERDUE, bucket(F.date(2026, 9, 27, 23, 59), now = now))
        assertEquals(DueBucket.TODAY, bucket(now, now = now))
        assertEquals(DueBucket.TODAY, bucket(F.date(2026, 9, 28, 23, 59), now = now))
        assertEquals(DueBucket.THIS_WEEK, bucket(F.date(2026, 10, 4, 23, 59), now = now))
        assertEquals(DueBucket.LATER, bucket(F.date(2026, 10, 5, 0, 0), now = now))
    }

    @Test
    fun mondayHasAFullWeekAhead() {
        val now = F.date(2026, 9, 21, 8, 0) // Monday
        assertEquals(DueBucket.THIS_WEEK, bucket(F.date(2026, 9, 22, 9, 0), now = now))
        assertEquals(DueBucket.THIS_WEEK, bucket(F.date(2026, 9, 27, 23, 0), now = now))
        assertEquals(DueBucket.LATER, bucket(F.date(2026, 9, 28, 0, 0), now = now))
    }

    @Test
    fun sundayHasNoThisWeekSection() {
        // Sunday is the last day of a French week: tomorrow (Monday) is already "Plus tard".
        val now = F.date(2026, 9, 27, 10, 0)
        val boundaries = DueBucketBoundaries(now, calendar)
        assertEquals(F.date(2026, 9, 28), boundaries.startOfTomorrow)
        assertEquals(boundaries.startOfTomorrow, boundaries.startOfNextWeek)
        assertEquals(DueBucket.TODAY, bucket(F.date(2026, 9, 27, 22, 0), now = now))
        assertEquals(DueBucket.LATER, bucket(F.date(2026, 9, 28, 8, 0), now = now))
        val sections = DueBucket.sections(
            listOf(F.task(1, due = F.date(2026, 9, 27, 22, 0)), F.task(2, due = F.date(2026, 9, 28, 8, 0))),
            now,
            calendar,
        )
        assertEquals(listOf(DueBucket.TODAY, DueBucket.LATER), sections.map { it.bucket })
    }

    @Test
    fun weekStartFollowsTheInjectedCalendar() {
        // Swift injects a Sunday-first `Calendar`; `AppCalendar` is always French, so the first day is a parameter.
        val saturday = F.date(2026, 9, 26, 10, 0)
        val sunday = F.date(2026, 9, 27, 10, 0)
        // Sunday-first week: on Saturday the week ends tonight; on Sunday a whole week lies ahead.
        assertEquals(DueBucket.LATER, DueBucket.bucket(F.task(1, due = sunday), saturday, calendar, DayOfWeek.SUNDAY))
        assertEquals(
            DueBucket.THIS_WEEK,
            DueBucket.bucket(F.task(1, due = F.date(2026, 9, 28, 9, 0)), sunday, calendar, DayOfWeek.SUNDAY),
        )
        // Monday-first (French) week: Sunday is still this week when seen from Saturday.
        assertEquals(DueBucket.THIS_WEEK, DueBucket.bucket(F.task(1, due = sunday), saturday, calendar))
        assertEquals(DayOfWeek.MONDAY, calendar.weekFields.firstDayOfWeek)
    }

    @Test
    fun springForwardSunday() {
        // Sunday 29 March 2026: clocks jump from 02:00 to 03:00 (a 23-hour day).
        val now = F.date(2026, 3, 29, 1, 30)
        val boundaries = DueBucketBoundaries(now, calendar)
        assertEquals(F.date(2026, 3, 29), boundaries.startOfToday)
        assertEquals(F.date(2026, 3, 30), boundaries.startOfTomorrow)
        assertEquals(Duration.ofHours(23), Duration.between(boundaries.startOfToday, boundaries.startOfTomorrow))
        assertEquals(boundaries.startOfTomorrow, boundaries.startOfNextWeek)
        // Monday 00:30 is only 23.5 hours after Sunday 00:00: a naive "+24 h" would wrongly call it today.
        assertEquals(DueBucket.TODAY, bucket(F.date(2026, 3, 29, 23, 30), now = now))
        assertEquals(DueBucket.LATER, bucket(F.date(2026, 3, 30, 0, 30), now = now))
    }

    @Test
    fun springForwardSeenFromSaturday() {
        val now = F.date(2026, 3, 28, 18, 0)
        assertEquals(DueBucket.THIS_WEEK, bucket(F.date(2026, 3, 29, 3, 30), now = now))
        assertEquals(DueBucket.THIS_WEEK, bucket(F.date(2026, 3, 29, 23, 59), now = now))
        assertEquals(DueBucket.LATER, bucket(F.date(2026, 3, 30, 0, 0), now = now))
    }

    @Test
    fun fallBackSunday() {
        // Sunday 25 October 2026: clocks go back from 03:00 to 02:00 (a 25-hour day).
        val now = F.date(2026, 10, 25, 0, 30)
        val boundaries = DueBucketBoundaries(now, calendar)
        assertEquals(Duration.ofHours(25), Duration.between(boundaries.startOfToday, boundaries.startOfTomorrow))
        // Sunday 23:30 is 24.5 hours after midnight: a naive +24 h would wrongly call it tomorrow.
        val sundayLate = boundaries.startOfToday.plus(Duration.ofMinutes(24 * 60 + 30))
        assertEquals(DueBucket.TODAY, bucket(sundayLate, now = now))
        assertEquals(DueBucket.LATER, bucket(F.date(2026, 10, 26, 0, 0), now = now))
    }

    @Test
    fun fallBackSeenFromFriday() {
        val now = F.date(2026, 10, 23, 12, 0)
        val boundaries = DueBucketBoundaries(now, calendar)
        assertEquals(F.date(2026, 10, 26), boundaries.startOfNextWeek)
        assertEquals(DueBucket.THIS_WEEK, bucket(F.date(2026, 10, 25, 23, 59), now = now))
        assertEquals(DueBucket.LATER, bucket(F.date(2026, 10, 26, 0, 0), now = now))
    }

    @Test
    fun sectionsAreOrderedNonEmptyAndSorted() {
        val now = F.date(2026, 9, 24, 12, 0)
        val tasks = listOf(
            F.task(1, title = "Plus tard", due = F.date(2026, 10, 5)),
            F.task(2, title = "Sans date B", priority = TaskPriority.LOW, due = null),
            F.task(3, title = "Retard", due = F.date(2026, 9, 23)),
            F.task(4, title = "Fini ancien", status = TaskStatus.DONE, due = F.date(2026, 9, 1), completedAt = F.date(2026, 9, 2)),
            F.task(5, title = "Aujourd'hui 20h", due = F.date(2026, 9, 24, 20, 0)),
            F.task(6, title = "Sans date A", priority = TaskPriority.HIGH, due = null),
            F.task(7, title = "Aujourd'hui 14h", due = F.date(2026, 9, 24, 14, 0)),
            F.task(8, title = "Fini récent", status = TaskStatus.DONE, due = null, completedAt = F.date(2026, 9, 23)),
        )
        val sections = DueBucket.sections(tasks, now, calendar)
        assertEquals(
            listOf(DueBucket.OVERDUE, DueBucket.TODAY, DueBucket.LATER, DueBucket.NO_DUE_DATE, DueBucket.DONE),
            sections.map { it.bucket },
        )
        assertEquals(
            listOf("En retard", "Aujourd’hui", "Plus tard", "Sans échéance", "Terminées"),
            sections.map { it.title },
        )
        assertEquals(
            listOf(
                listOf("Retard"),
                listOf("Aujourd'hui 14h", "Aujourd'hui 20h"),
                listOf("Plus tard"),
                listOf("Sans date A", "Sans date B"),
                listOf("Fini récent", "Fini ancien"),
            ),
            sections.map { section -> section.tasks.map { it.title } },
        )
        assertTrue(sections.all { it.tasks.isNotEmpty() })
        assertEquals(tasks.size, sections.sumOf { it.tasks.size })
        assertEquals(sections.map { it.bucket }, sections.map { it.id })
    }

    @Test
    fun sectionsUseTheRequestedSort() {
        val now = F.date(2026, 9, 24, 12, 0)
        val tasks = listOf(
            F.task(1, title = "Basse tôt", priority = TaskPriority.LOW, due = F.date(2026, 9, 24, 13, 0)),
            F.task(2, title = "Haute tard", priority = TaskPriority.HIGH, due = F.date(2026, 9, 24, 22, 0)),
        )
        val byPriority = DueBucket.sections(tasks, now, calendar, sort = TaskSort.PRIORITY)
        assertEquals(listOf("Haute tard", "Basse tôt"), byPriority.first().tasks.map { it.title })
        val byDue = DueBucket.sections(tasks, now, calendar)
        assertEquals(listOf("Basse tôt", "Haute tard"), byDue.first().tasks.map { it.title })
    }

    @Test
    fun emptyInputGivesNoSections() {
        assertTrue(DueBucket.sections(emptyList(), F.date(2026, 9, 24), calendar).isEmpty())
    }

    /** Done tasks: most recently completed first, unknown completion date last, ties broken by the sort. */
    @Test
    fun doneSectionOrder() {
        val now = F.date(2026, 9, 24, 12, 0)
        val completed = F.date(2026, 9, 20)
        val tasks = listOf(
            F.task(1, title = "b", status = TaskStatus.DONE, completedAt = completed),
            F.task(2, title = "a", status = TaskStatus.DONE, completedAt = completed),
            F.task(3, title = "c", status = TaskStatus.DONE).copy(completedAt = null),
            F.task(4, title = "d", status = TaskStatus.DONE, completedAt = F.date(2026, 9, 21)),
        )
        val done = DueBucket.sections(tasks, now, calendar).single()
        assertEquals(DueBucket.DONE, done.bucket)
        assertEquals(listOf("d", "a", "b", "c"), done.tasks.map { it.title })
    }
}
