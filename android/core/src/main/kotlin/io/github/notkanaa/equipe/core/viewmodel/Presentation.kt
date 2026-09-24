package io.github.notkanaa.equipe.core.viewmodel

import io.github.notkanaa.equipe.core.AppCalendar
import io.github.notkanaa.equipe.core.MemberRole
import io.github.notkanaa.equipe.core.Membership
import io.github.notkanaa.equipe.core.NameOrder
import io.github.notkanaa.equipe.core.TaskItem
import io.github.notkanaa.equipe.core.TaskPriority
import io.github.notkanaa.equipe.core.TaskStatus
import io.github.notkanaa.equipe.core.logic.FrenchDateFormatter
import io.github.notkanaa.equipe.core.logic.TaskFilter
import io.github.notkanaa.equipe.core.logic.TaskStatusFilter
import java.time.Instant
import java.util.UUID

// French labels and ready-to-display values shared by the view models, so that every screen words things the same way
// (port of TeamTasksCore/ViewModels/Support/Presentation.swift).
// `systemImage` values are the iOS SF Symbols names (reference); `iconName` values are the matching Material icons of
// material-icons-extended (`Icons.Filled.<iconName>`, `Icons.Outlined.<iconName>`…).

// region Labels and icons

/** « À faire », « En cours », « Terminée ». */
val TaskStatus.label: String
    get() = when (this) {
        TaskStatus.TODO -> "À faire"
        TaskStatus.IN_PROGRESS -> "En cours"
        TaskStatus.DONE -> "Terminée"
    }

/** SF Symbols name (iOS reference). */
val TaskStatus.systemImage: String
    get() = when (this) {
        TaskStatus.TODO -> "circle"
        TaskStatus.IN_PROGRESS -> "circle.lefthalf.filled"
        TaskStatus.DONE -> "checkmark.circle.fill"
    }

/** Material icon: `RadioButtonUnchecked`, `Contrast` (half-filled circle), `CheckCircle`. */
val TaskStatus.iconName: String
    get() = when (this) {
        TaskStatus.TODO -> "RadioButtonUnchecked"
        TaskStatus.IN_PROGRESS -> "Contrast"
        TaskStatus.DONE -> "CheckCircle"
    }

/** Next status of a one-tap cycle: à faire → en cours → terminée → à faire. */
val TaskStatus.next: TaskStatus
    get() = when (this) {
        TaskStatus.TODO -> TaskStatus.IN_PROGRESS
        TaskStatus.IN_PROGRESS -> TaskStatus.DONE
        TaskStatus.DONE -> TaskStatus.TODO
    }

/** « Basse », « Moyenne », « Haute ». */
val TaskPriority.label: String
    get() = when (this) {
        TaskPriority.LOW -> "Basse"
        TaskPriority.MEDIUM -> "Moyenne"
        TaskPriority.HIGH -> "Haute"
    }

/** SF Symbols name (iOS reference). */
val TaskPriority.systemImage: String
    get() = when (this) {
        TaskPriority.LOW -> "arrow.down"
        TaskPriority.MEDIUM -> "minus"
        TaskPriority.HIGH -> "exclamationmark"
    }

/** Material icon: `ArrowDownward`, `Remove`, `PriorityHigh`. */
val TaskPriority.iconName: String
    get() = when (this) {
        TaskPriority.LOW -> "ArrowDownward"
        TaskPriority.MEDIUM -> "Remove"
        TaskPriority.HIGH -> "PriorityHigh"
    }

/** Picker order: high first (`TaskPriority.pickerOrder`). */
val TaskPriority.Companion.pickerOrder: List<TaskPriority>
    get() = listOf(TaskPriority.HIGH, TaskPriority.MEDIUM, TaskPriority.LOW)

/** « Admin », « Membre ». */
val MemberRole.label: String
    get() = when (this) {
        MemberRole.ADMIN -> "Admin"
        MemberRole.MEMBER -> "Membre"
    }

// endregion

/** Date wording of the screens (French, relative to a reference date, in the injected calendar's time zone). */
object DateText {
    /**
     * « Aujourd’hui à 20:00 », « Demain à 18:00 », « Hier à 09:30 », « Lundi à 18:00 » (2 to 6 days ahead),
     * « Jeudi 1er octobre à 18:00 ».
     */
    fun relative(date: Instant, now: Instant, calendar: AppCalendar): String =
        FrenchDateFormatter.capitalizingFirstLetter(FrenchDateFormatter.of(calendar).relativeDateTime(date, now))

    /** Same wording in lowercase, after a label (« Dernière activité : hier à 09:30 »). */
    fun relativeLowercase(date: Instant, now: Instant, calendar: AppCalendar): String =
        FrenchDateFormatter.of(calendar).relativeDateTime(date, now)

    /**
     * Wording for the middle of a sentence: « hier à 09:30 », « le lundi 14 septembre à 10:00 » (« Créée par Lucas
     * Bernard le lundi 14 septembre à 10:00 »).
     */
    fun relativeInSentence(date: Instant, now: Instant, calendar: AppCalendar): String =
        FrenchDateFormatter.of(calendar).relativeDateTimeInSentence(date, now)
}

/** Display names of a group's members, as seen by the current user. */
data class MemberDirectory(
    val members: List<Membership>,
    val currentUserId: UUID,
) {
    /** The current user's role, null when not a member. */
    val myRole: MemberRole? get() = role(currentUserId)

    fun role(userId: UUID): MemberRole? = members.firstOrNull { it.user.id == userId }?.role

    /** Display name of a member, « Ancien membre » when unknown or null. */
    fun name(userId: UUID?): String {
        if (userId == null) return FORMER_MEMBER_NAME
        return members.firstOrNull { it.user.id == userId }?.user?.displayName ?: FORMER_MEMBER_NAME
    }

    /** Names of [userIds] for a list: « Vous » first, then the others in name order ([NameOrder]). */
    fun names(userIds: Collection<UUID>): List<String> {
        var includesMe = false
        val others = ArrayList<String>()
        for (userId in LinkedHashSet(userIds)) {
            if (userId == currentUserId) {
                includesMe = true
            } else {
                others.add(name(userId))
            }
        }
        val sorted = others.sortedWith(NameOrder.nameComparator)
        return if (includesMe) listOf(ME_NAME) + sorted else sorted
    }

    /** « Vous, Lucas Bernard », or « Non assignée ». */
    fun assigneesText(userIds: Collection<UUID>): String {
        val names = names(userIds)
        return if (names.isEmpty()) UNASSIGNED_TEXT else names.joinToString(", ")
    }

    companion object {
        /** Shown for a user who is no longer a member (or a deleted account). */
        const val FORMER_MEMBER_NAME: String = "Ancien membre"

        /** Shown instead of the current user's own name in lists of people. */
        const val ME_NAME: String = "Vous"

        /** Assignee text of a task without assignees. */
        const val UNASSIGNED_TEXT: String = "Non assignée"
    }
}

/** One row of a task list, ready to display. */
data class TaskRow(
    val task: TaskItem,
    /** « Aujourd’hui à 20:00 », null without due date. */
    val dueText: String?,
    /** Not done and due in the past (show the due text in red). */
    val isOverdue: Boolean,
    /** « Vous, Lucas Bernard » / « Non assignée »; null on screens that do not show assignees (« Mes tâches »). */
    val assigneesText: String?,
    /** Group name, filled on « Mes tâches » only. */
    val groupName: String?,
    /** « Nouveau » badge (« Mes tâches » only). */
    val isNew: Boolean,
    val canChangeStatus: Boolean,
    val canEdit: Boolean,
    val canDelete: Boolean,
) {
    val id: UUID get() = task.id
    val title: String get() = task.title
    val status: TaskStatus get() = task.status
    val priority: TaskPriority get() = task.priority
    val isDone: Boolean get() = task.status == TaskStatus.DONE
}

/**
 * A filter chip of a task list (« Toutes », « À faire », « En cours », « Terminées », « Assignées à moi »,
 * « En retard »).
 */
data class TaskFilterChip(
    val kind: Kind,
    val label: String,
    val isSelected: Boolean,
) {
    sealed interface Kind {
        /** Mutually exclusive status choice ([TaskStatusFilter.ALL] resets the status criterion). */
        data class Status(val status: TaskStatusFilter) : Kind

        data object AssignedToMe : Kind

        data object Overdue : Kind
    }

    val id: Kind get() = kind

    companion object {
        /** Status choices offered as chips, in display order. */
        val statusChoices: List<TaskStatusFilter> = listOf(
            TaskStatusFilter.ALL,
            TaskStatusFilter.TODO,
            TaskStatusFilter.IN_PROGRESS,
            TaskStatusFilter.DONE,
        )

        /** The chips describing [filter]. */
        fun chips(filter: TaskFilter): List<TaskFilterChip> =
            statusChoices.map { TaskFilterChip(Kind.Status(it), it.label, filter.status == it) } + listOf(
                TaskFilterChip(Kind.AssignedToMe, "Assignées à moi", filter.onlyAssignedToMe),
                TaskFilterChip(Kind.Overdue, "En retard", filter.onlyOverdue),
            )

        /**
         * [filter] after a tap on the chip [kind]: a status chip selects its status (tapping the selected status again
         * goes back to « Toutes »); the other chips toggle.
         */
        fun toggling(kind: Kind, filter: TaskFilter): TaskFilter = when (kind) {
            is Kind.Status -> filter.copy(
                status = if (filter.status == kind.status && kind.status != TaskStatusFilter.ALL) {
                    TaskStatusFilter.ALL
                } else {
                    kind.status
                },
            )
            Kind.AssignedToMe -> filter.copy(onlyAssignedToMe = !filter.onlyAssignedToMe)
            Kind.Overdue -> filter.copy(onlyOverdue = !filter.onlyOverdue)
        }
    }
}
