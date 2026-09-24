package io.github.notkanaa.equipe.core.logic

import io.github.notkanaa.equipe.core.TaskItem
import io.github.notkanaa.equipe.core.TaskPriority
import io.github.notkanaa.equipe.core.TaskStatus
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import io.github.notkanaa.equipe.core.logic.LogicFixtures as F

/** Port of the TaskSortTests suite of Logic/TaskFilterSortTests.swift. */
class TaskSortTest {
    private fun titles(tasks: List<TaskItem>): List<String> = tasks.map { it.title }

    @Test
    fun dueDateThenPriorityThenTitleWithNilLast() {
        val day = F.date(2026, 9, 25, 10, 0)
        val tasks = listOf(
            F.task(1, title = "Sans date", priority = TaskPriority.HIGH, due = null),
            F.task(2, title = "Zèbre", priority = TaskPriority.LOW, due = day),
            F.task(3, title = "banane", priority = TaskPriority.HIGH, due = day),
            F.task(4, title = "Abricot", priority = TaskPriority.HIGH, due = day),
            F.task(5, title = "Tôt", priority = TaskPriority.LOW, due = day.minusSeconds(60)),
            F.task(6, title = "Autre sans date", priority = TaskPriority.LOW, due = null),
        )
        assertEquals(
            listOf("Tôt", "Abricot", "banane", "Zèbre", "Sans date", "Autre sans date"),
            titles(TaskSort.DUE_DATE.sorted(tasks)),
        )
    }

    @Test
    fun priorityThenDueDate() {
        val tasks = listOf(
            F.task(1, title = "Moyenne", priority = TaskPriority.MEDIUM, due = F.date(2026, 9, 25)),
            F.task(2, title = "Haute sans date", priority = TaskPriority.HIGH, due = null),
            F.task(3, title = "Haute tôt", priority = TaskPriority.HIGH, due = F.date(2026, 9, 24)),
            F.task(4, title = "Basse", priority = TaskPriority.LOW, due = F.date(2026, 9, 1)),
        )
        assertEquals(
            listOf("Haute tôt", "Haute sans date", "Moyenne", "Basse"),
            titles(TaskSort.PRIORITY.sorted(tasks)),
        )
    }

    @Test
    fun recentlyCreatedFirst() {
        val tasks = listOf(
            F.task(1, title = "Ancienne", createdAt = F.date(2026, 1, 1)),
            F.task(2, title = "Récente", createdAt = F.date(2026, 9, 1)),
            F.task(3, title = "Moyenne", createdAt = F.date(2026, 5, 1)),
        )
        assertEquals(listOf("Récente", "Moyenne", "Ancienne"), titles(TaskSort.RECENTLY_CREATED.sorted(tasks)))
    }

    @Test
    fun titlesCompareIgnoringCaseAndAccents() {
        val tasks = listOf("fenêtre", "Éclairage", "eau", "Zinc", "arrosage").mapIndexed { index, title ->
            F.task(index + 1, title = title)
        }
        assertEquals(
            listOf("arrosage", "eau", "Éclairage", "fenêtre", "Zinc"),
            titles(TaskSort.DUE_DATE.sorted(tasks)),
        )
    }

    /**
     * PostgREST reads have no ORDER BY: distinct tasks equal on every visible criterion must still get one order
     * whatever the input order (creation date, then id).
     */
    @Test
    fun distinctTasksSortIndependentlyOfInputOrder() {
        val due = F.date(2026, 9, 25, 20, 0)
        val older = F.task(2, title = "Sortir les poubelles", due = due, createdAt = F.date(2026, 9, 1))
        val newer = F.task(1, title = "Sortir les poubelles", due = due, createdAt = F.date(2026, 9, 2))
        val twin = F.task(3, title = "Sortir les poubelles", due = due, createdAt = F.date(2026, 9, 2))
        for (sort in listOf(TaskSort.DUE_DATE, TaskSort.PRIORITY)) {
            val expected = listOf(older, newer, twin).map { it.id }
            assertEquals("$sort", expected, sort.sorted(listOf(older, newer, twin)).map { it.id })
            assertEquals("$sort", expected, sort.sorted(listOf(twin, newer, older)).map { it.id })
        }
        val recentFirst = listOf(newer, twin, older).map { it.id }
        assertEquals(recentFirst, TaskSort.RECENTLY_CREATED.sorted(listOf(older, twin, newer)).map { it.id })
        assertEquals(recentFirst, TaskSort.RECENTLY_CREATED.sorted(listOf(twin, older, newer)).map { it.id })
        assertTrue(TaskSort.DUE_DATE.areInIncreasingOrder(newer, twin))
    }

    /** Only two copies of the same task (same id) keep their input order. */
    @Test
    fun sameTaskTwiceKeepsTheInputOrder() {
        val task = F.task(1, title = "Même tâche", due = F.date(2026, 9, 25))
        val copy = task.copy(status = TaskStatus.IN_PROGRESS)
        for (sort in TaskSort.entries) {
            assertEquals(listOf(TaskStatus.TODO, TaskStatus.IN_PROGRESS), sort.sorted(listOf(task, copy)).map { it.status })
            assertEquals(listOf(TaskStatus.IN_PROGRESS, TaskStatus.TODO), sort.sorted(listOf(copy, task)).map { it.status })
        }
    }

    /** French alphabetical order reads « œ » as « oe » and « æ » as « ae ». */
    @Test
    fun ligaturesSortAsTwoLetters() {
        val tasks = listOf(
            "Payer le loyer", "Œufs pour la fête", "Nettoyer la cuisine", "Zinc", "Ænéide", "Adresse", "Afficher",
        ).mapIndexed { index, title -> F.task(index + 1, title = title) }
        assertEquals(
            listOf("Adresse", "Ænéide", "Afficher", "Nettoyer la cuisine", "Œufs pour la fête", "Payer le loyer", "Zinc"),
            titles(TaskSort.DUE_DATE.sorted(tasks)),
        )
    }

    @Test
    fun deterministicWhateverTheInputOrder() {
        val tasks = listOf(
            F.task(1, title = "b", priority = TaskPriority.LOW, due = F.date(2026, 9, 25)),
            F.task(2, title = "a", priority = TaskPriority.LOW, due = F.date(2026, 9, 25)),
            F.task(3, title = "c", priority = TaskPriority.HIGH, due = null),
            F.task(4, title = "d", priority = TaskPriority.MEDIUM, due = F.date(2026, 9, 26)),
        )
        for (sort in TaskSort.entries) {
            val expected = sort.sorted(tasks).map { it.id }
            assertEquals(expected, sort.sorted(tasks.reversed()).map { it.id })
            assertEquals(expected, sort.sorted(listOf(tasks[2], tasks[0], tasks[3], tasks[1])).map { it.id })
        }
    }

    @Test
    fun predicateMatchesSortedOrder() {
        val tasks = listOf(
            F.task(1, title = "b", priority = TaskPriority.LOW, due = F.date(2026, 9, 25)),
            F.task(2, title = "a", priority = TaskPriority.HIGH, due = F.date(2026, 9, 25)),
            F.task(3, title = "c", priority = TaskPriority.HIGH, due = null),
        )
        for (sort in TaskSort.entries) {
            val byPredicate = tasks.sortedWith { lhs, rhs ->
                when {
                    sort.areInIncreasingOrder(lhs, rhs) -> -1
                    sort.areInIncreasingOrder(rhs, lhs) -> 1
                    else -> 0
                }
            }
            assertEquals(sort.sorted(tasks).map { it.id }, byPredicate.map { it.id })
            assertEquals(sort.sorted(tasks).map { it.id }, tasks.sortedWith(sort.comparator).map { it.id })
        }
        assertFalse(TaskSort.DUE_DATE.areInIncreasingOrder(tasks[0], tasks[0]))
    }

    @Test
    fun frenchLabels() {
        assertEquals(listOf("Échéance", "Priorité", "Plus récentes"), TaskSort.entries.map { it.label })
        assertEquals(listOf("dueDate", "priority", "recentlyCreated"), TaskSort.entries.map { it.id })
        assertEquals(TaskSort.RECENTLY_CREATED, TaskSort.fromRawValue("recentlyCreated"))
    }

    /** Width-insensitive like Foundation: full-width letters sort with their ASCII forms. */
    @Test
    fun titleKeyFoldsCaseAccentsWidthAndLigatures() {
        assertEquals("eclairage", TaskSort.titleKey("Éclairage"))
        assertEquals("oeufs", TaskSort.titleKey("Œufs"))
        assertEquals("aeneide", TaskSort.titleKey("Ænéide"))
        assertEquals("strasse", TaskSort.titleKey("Straße"))
        assertEquals("abc 1", TaskSort.titleKey("ＡＢｃ　１"))
    }
}
