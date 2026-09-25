package io.github.notkanaa.equipe.ui.components.tasks

import io.github.notkanaa.equipe.core.MemberRole
import io.github.notkanaa.equipe.core.TaskItem
import io.github.notkanaa.equipe.core.TaskPriority
import io.github.notkanaa.equipe.core.TaskStatus
import io.github.notkanaa.equipe.core.viewmodel.AssigneeOption
import io.github.notkanaa.equipe.core.viewmodel.MemberDirectory
import io.github.notkanaa.equipe.core.viewmodel.TaskRow
import io.github.notkanaa.equipe.ui.tasks.assigneeSelectionSummary
import io.github.notkanaa.equipe.ui.tasks.filterAssigneeOptions
import org.junit.Assert.assertEquals
import org.junit.Test
import java.time.Instant
import java.util.UUID

/** Texts of the task rows and of the task editor: TalkBack sentences, French typography, assignee search. */
class TaskUiTextTest {
    private val now = Instant.parse("2026-09-24T09:41:00Z")

    private fun row(
        title: String,
        status: TaskStatus,
        priority: TaskPriority,
        dueText: String?,
        isOverdue: Boolean = false,
        isNew: Boolean = false,
        groupName: String? = null,
        assigneesText: String? = null,
    ) = TaskRow(
        task = TaskItem(
            id = UUID.randomUUID(),
            groupId = UUID.randomUUID(),
            title = title,
            status = status,
            priority = priority,
            createdBy = null,
            createdAt = now,
            updatedAt = now,
        ),
        dueText = dueText,
        isOverdue = isOverdue,
        assigneesText = assigneesText,
        groupName = groupName,
        isNew = isNew,
        canChangeStatus = true,
        canEdit = false,
        canDelete = false,
    )

    @Test
    fun rowSentenceMatchesTheIosWording() {
        assertEquals(
            "Payer le loyer, À faire, priorité haute, en retard, échéance hier à 18:00, assignée à Inès Dubois",
            taskRowAccessibilityText(
                row("Payer le loyer", TaskStatus.TODO, TaskPriority.HIGH, "Hier à 18:00", isOverdue = true, assigneesText = "Inès Dubois"),
                showGroupName = false,
            ),
        )
        assertEquals(
            "Faire les courses, nouveau, En cours, priorité moyenne, échéance demain à 18:00, groupe Coloc' rue des Lilas",
            taskRowAccessibilityText(
                row("Faire les courses", TaskStatus.IN_PROGRESS, TaskPriority.MEDIUM, "Demain à 18:00", isNew = true, groupName = "Coloc' rue des Lilas"),
                showGroupName = true,
            ),
        )
        assertEquals(
            "Réparer, Terminée, priorité basse, non assignée",
            taskRowAccessibilityText(
                row("Réparer", TaskStatus.DONE, TaskPriority.LOW, null, assigneesText = MemberDirectory.UNASSIGNED_TEXT),
                showGroupName = true,
            ),
        )
    }

    @Test
    fun smallTextsUseFrenchTypography() {
        assertEquals("Passer à « En cours »", nextStatusActionTitle(TaskStatus.TODO))
        assertEquals("Passer à « À faire »", nextStatusActionTitle(TaskStatus.DONE))
        assertEquals("Échéance dépassée : Hier à 18:00", dueAccessibilityText("Hier à 18:00", isOverdue = true))
        assertEquals("Échéance : Demain à 18:00", dueAccessibilityText("Demain à 18:00", isOverdue = false))
        assertEquals("Aucune échéance", dueAccessibilityText(null, isOverdue = false))
        assertEquals("Priorité haute", priorityAccessibilityText(TaskPriority.HIGH))
    }

    @Test
    fun assigneeSummaryAndSearch() {
        assertEquals("0 personne sélectionnée sur 20 au maximum.", assigneeSelectionSummary(0))
        assertEquals("1 personne sélectionnée sur 20 au maximum.", assigneeSelectionSummary(1))
        assertEquals("2 personnes sélectionnées sur 20 au maximum.", assigneeSelectionSummary(2))

        val options = listOf(
            AssigneeOption(UUID.randomUUID(), "Camille Martin (vous)", MemberRole.ADMIN, isMe = true, isSelected = false),
            AssigneeOption(UUID.randomUUID(), "Inès Dubois", MemberRole.MEMBER, isMe = false, isSelected = true),
            AssigneeOption(UUID.randomUUID(), "Lucas Bernard", MemberRole.MEMBER, isMe = false, isSelected = false),
        )
        assertEquals(options, filterAssigneeOptions(options, ""))
        assertEquals(listOf("Inès Dubois"), filterAssigneeOptions(options, "ines").map { it.name })
        assertEquals(listOf("Camille Martin (vous)"), filterAssigneeOptions(options, "CAMILLE").map { it.name })
        assertEquals(listOf("Camille Martin (vous)", "Lucas Bernard"), filterAssigneeOptions(options, "AR").map { it.name })
        assertEquals(emptyList<AssigneeOption>(), filterAssigneeOptions(options, "zzz"))
    }
}
