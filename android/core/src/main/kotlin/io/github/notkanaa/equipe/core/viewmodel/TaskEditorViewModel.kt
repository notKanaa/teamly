package io.github.notkanaa.equipe.core.viewmodel

import io.github.notkanaa.equipe.core.AppCalendar
import io.github.notkanaa.equipe.core.AppError
import io.github.notkanaa.equipe.core.InputValidation
import io.github.notkanaa.equipe.core.Limits
import io.github.notkanaa.equipe.core.MemberRole
import io.github.notkanaa.equipe.core.Membership
import io.github.notkanaa.equipe.core.NameOrder
import io.github.notkanaa.equipe.core.TaskDraft
import io.github.notkanaa.equipe.core.TaskItem
import io.github.notkanaa.equipe.core.TaskPermissions
import io.github.notkanaa.equipe.core.TaskPriority
import kotlinx.coroutines.CoroutineScope
import java.time.Instant
import java.time.LocalTime
import java.util.UUID
import kotlin.coroutines.cancellation.CancellationException

// Port of TeamTasksCore/ViewModels/Tasks/TaskEditorViewModel.swift.

/** What the task editor edits (Swift `TaskEditorViewModel.Mode`): the `mode` parameter of `TaskEditorSheet`. */
sealed interface TaskEditorMode {
    /** The task's group. */
    val groupId: UUID

    /** « Nouvelle tâche » in [groupId]. */
    data class Create(override val groupId: UUID) : TaskEditorMode

    /** « Modifier la tâche »: full edit of [task] (admin or creator). */
    data class Edit(val task: TaskItem) : TaskEditorMode {
        override val groupId: UUID get() = task.groupId
    }
}

/** A member offered in the assignee picker. */
data class AssigneeOption(
    val id: UUID,
    /** « Camille Martin (vous) » for the current user. */
    val name: String,
    val role: MemberRole,
    val isMe: Boolean,
    val isSelected: Boolean,
)

/** State of the « Nouvelle tâche » / « Modifier la tâche » sheet. */
data class TaskEditorState(
    val mode: TaskEditorMode,
    /** The signed-in user. */
    val currentUserId: UUID,
    /** Initial values (baseline of [hasChanges]). */
    val original: TaskDraft,
    val title: String,
    val details: String,
    val priority: TaskPriority,
    /** « Échéance » toggle. Turning it on keeps the last chosen date (tomorrow 18:00 by default). */
    val hasDueDate: Boolean,
    /** Date picker value (used when [hasDueDate]). */
    val dueDate: Instant,
    val assigneeIds: Set<UUID>,
    /** Members of the group (assignee picker), admins first then by name. */
    val members: List<Membership> = emptyList(),
    val loadState: LoadState = LoadState.Idle,
    val titleError: String? = null,
    val detailsError: String? = null,
    val dueDateError: String? = null,
    val assigneesError: String? = null,
    val isSaving: Boolean = false,
    /** Set on success: dismiss. */
    val savedTask: TaskItem? = null,
    /** Edit mode: the task was deleted meanwhile. */
    val isGone: Boolean = false,
    override val error: ErrorState? = null,
) : ErrorHolder {
    val groupId: UUID get() = mode.groupId

    val isEditing: Boolean get() = mode is TaskEditorMode.Edit

    /** « Modifier la tâche » / « Nouvelle tâche ». */
    val navigationTitle: String get() = if (isEditing) "Modifier la tâche" else "Nouvelle tâche"

    /** « Enregistrer » / « Créer ». */
    val saveButtonTitle: String get() = if (isEditing) "Enregistrer" else "Créer"

    /** The draft sent to the service. */
    val draft: TaskDraft
        get() = TaskDraft(
            title = title,
            details = details,
            priority = priority,
            dueAt = if (hasDueDate) dueDate else null,
            assigneeIds = assigneeIds,
        )

    /** Something differs from the initial values (ask before discarding). */
    val hasChanges: Boolean
        get() {
            // A create form with the toggle off has no due date whatever the picker shows.
            val baseline = if (isEditing) original else original.copy(dueAt = null)
            return draft != baseline
        }

    /** The current user's role in the group (from the members), null when not a member. */
    val myRole: MemberRole? get() = members.firstOrNull { it.user.id == currentUserId }?.role

    /** Edit mode: whether the user may edit this task (admin or creator). Always true for a new task of a member. */
    val canEdit: Boolean
        get() = when (mode) {
            is TaskEditorMode.Create -> loadState != LoadState.Loaded || TaskPermissions.canCreate(myRole)
            is TaskEditorMode.Edit ->
                loadState != LoadState.Loaded || TaskPermissions.canEdit(mode.task, currentUserId, myRole)
        }

    val canSave: Boolean get() = InputValidation.trimmed(title).isNotEmpty() && !isSaving && canEdit

    val assigneeOptions: List<AssigneeOption>
        get() = members.map { member ->
            val isMe = member.user.id == currentUserId
            AssigneeOption(
                id = member.user.id,
                name = if (isMe) "${member.user.displayName} (vous)" else member.user.displayName,
                role = member.role,
                isMe = isMe,
                isSelected = member.user.id in assigneeIds,
            )
        }

    /** 20 people are already assigned: others cannot be added. */
    val assigneeLimitReached: Boolean get() = assigneeIds.size >= TaskEditorViewModel.MAX_ASSIGNEES

    /** « Vous, Lucas Bernard » / « Non assignée ». */
    val assigneesSummary: String get() = MemberDirectory(members, currentUserId).assigneesText(assigneeIds)

    fun isAssigned(userId: UUID): Boolean = userId in assigneeIds
}

/**
 * « Nouvelle tâche » / « Modifier la tâche » sheet: title, details, priority, optional due date and assignees (members of
 * the group, at most 20). Fields are validated before calling the service, each with its message. On success
 * [TaskEditorState.savedTask] is set: dismiss.
 *
 * Screen: `LaunchedEffect(model) { model.load() }` (loads the members for the picker).
 *
 * @param members the group's members when already loaded (the picker then needs no request).
 */
class TaskEditorViewModel(
    val session: SessionModel,
    val mode: TaskEditorMode,
    scope: CoroutineScope,
    members: List<Membership>? = null,
) : ScreenModel<TaskEditorState>(initialState(session, mode, members), { state, error -> state.copy(error = error) }) {
    private val runner = LoadRunner(scope)

    val groupId: UUID get() = mode.groupId

    var title: String
        get() = current.title
        set(value) = update { it.copy(title = value, titleError = if (it.titleError != null) titleMessage(value) else null) }

    var details: String
        get() = current.details
        set(value) = update {
            it.copy(details = value, detailsError = if (it.detailsError != null) detailsMessage(value) else null)
        }

    var priority: TaskPriority
        get() = current.priority
        set(value) = update { it.copy(priority = value) }

    /** « Échéance » toggle. Turning it off clears the due date message. */
    var hasDueDate: Boolean
        get() = current.hasDueDate
        set(value) = update { it.copy(hasDueDate = value, dueDateError = if (value) it.dueDateError else null) }

    /** Date picker value (used when `hasDueDate`). */
    var dueDate: Instant
        get() = current.dueDate
        set(value) = update { it.copy(dueDate = value, dueDateError = null) }

    // region Loading (members)

    /** Loads the group's members for the picker (once). */
    suspend fun load() {
        if (current.loadState == LoadState.Loaded) return
        runner.run(rerunIfRunning = false) { fetchMembers() }
    }

    suspend fun reload() {
        runner.run(rerunIfRunning = true) { fetchMembers() }
    }

    /**
     * Loads the members and drops from the selection the people who are no longer members: the server refuses them
     * (`assignee_not_member`) and the picker has no row to unselect them.
     */
    private suspend fun fetchMembers() {
        try {
            update { it.copy(loadState = startedLoad(it.loadState)) }
            val members = NameOrder.sortedMembers(session.services.groups.members(groupId))
            val memberIds = members.map { it.user.id }.toSet()
            update {
                it.copy(
                    members = members,
                    loadState = LoadState.Loaded,
                    assigneeIds = it.assigneeIds.intersect(memberIds),
                    // Their assignments are gone on the server too: dropping them is not a change of the user.
                    original = it.original.copy(assigneeIds = it.original.assigneeIds.intersect(memberIds)),
                )
            }
        } catch (error: CancellationException) {
            update { it.copy(loadState = cancelledLoad(it.loadState)) }
            throw error
        } catch (error: Exception) {
            update {
                val failure = loadFailure(it.loadState, it.error, error)
                it.copy(loadState = failure.loadState, error = failure.error)
            }
        }
    }

    // endregion

    // region Assignees

    /** Adds or removes an assignee. Adding beyond 20 is refused with `assigneesError`. */
    fun toggleAssignee(userId: UUID) {
        update { state ->
            when {
                userId in state.assigneeIds -> {
                    val ids = state.assigneeIds - userId
                    state.copy(
                        assigneeIds = ids,
                        assigneesError = if (ids.size <= MAX_ASSIGNEES) null else state.assigneesError,
                    )
                }
                state.assigneeLimitReached -> state.copy(assigneesError = AppError.TooManyAssignees.messageFR)
                else -> state.copy(assigneeIds = state.assigneeIds + userId, assigneesError = null)
            }
        }
    }

    // endregion

    // region Save

    /** Checks every field (same order as the server) and sets their messages. Returns true when valid. */
    fun validate(): Boolean {
        val state = current
        val titleError = titleMessage(state.title)
        val detailsError = detailsMessage(state.details)
        val dueDateError = if (state.hasDueDate && !isValidDueDate(state.dueDate)) INVALID_DUE_DATE_MESSAGE else null
        val assigneesError = if (state.assigneeIds.size > MAX_ASSIGNEES) AppError.TooManyAssignees.messageFR else null
        update {
            it.copy(
                titleError = titleError,
                detailsError = detailsError,
                dueDateError = dueDateError,
                assigneesError = assigneesError,
            )
        }
        return titleError == null && detailsError == null && dueDateError == null && assigneesError == null
    }

    /** Creates or updates the task. Returns it on success ([TaskEditorState.savedTask]), null otherwise. */
    suspend fun save(): TaskItem? {
        if (current.isSaving) return null
        dismissError()
        if (!current.canEdit) {
            present(AppError.Forbidden)
            return null
        }
        if (!validate()) return null
        update { it.copy(isSaving = true) }
        try {
            val draft = current.draft
            val task = when (val editorMode = mode) {
                is TaskEditorMode.Create -> session.services.tasks.create(editorMode.groupId, draft)
                is TaskEditorMode.Edit -> session.services.tasks.update(editorMode.task.id, draft)
            }
            update { it.copy(savedTask = task) }
            session.feed.bump(groupId)
            session.feed.bumpMyTasks()
            return task
        } catch (error: CancellationException) {
            throw error
        } catch (error: Exception) {
            val appError = ErrorState.from(error)?.error ?: return null
            when {
                appError == AppError.InvalidTitle -> update { it.copy(titleError = appError.messageFR) }
                appError == AppError.InvalidDetails -> update { it.copy(detailsError = appError.messageFR) }
                appError == AppError.TooManyAssignees || appError == AppError.AssigneeNotMember -> {
                    update { it.copy(assigneesError = appError.messageFR) }
                    if (appError == AppError.AssigneeNotMember) {
                        val selected = current.assigneeIds
                        reload()
                        if (current.assigneeIds != selected) {
                            // The people who left were dropped: saving again works.
                            update { it.copy(assigneesError = DEPARTED_ASSIGNEES_MESSAGE) }
                        }
                    }
                }
                appError == AppError.NotFound && current.isEditing -> {
                    update { it.copy(isGone = true) }
                    present(GONE_MESSAGE, AppError.NotFound)
                }
                else -> present(appError)
            }
            return null
        } finally {
            update { it.copy(isSaving = false) }
        }
    }

    // endregion

    companion object {
        const val MAX_ASSIGNEES: Int = Limits.maxAssignees
        val MAX_TITLE_LENGTH: Int = Limits.taskTitle.last
        const val MAX_DETAILS_LENGTH: Int = Limits.taskDetailsMax
        const val INVALID_DUE_DATE_MESSAGE: String = "Date d’échéance invalide."
        const val GONE_MESSAGE: String = "Cette tâche a été supprimée."

        /** After `assignee_not_member`: the people who left the group were removed from the selection. */
        const val DEPARTED_ASSIGNEES_MESSAGE: String =
            "Une personne assignée a quitté le groupe : elle a été retirée. Enregistrez à nouveau."

        fun titleMessage(title: String): String? = try {
            InputValidation.taskTitle(title)
            null
        } catch (error: AppError) {
            AppError.InvalidTitle.messageFR
        }

        fun detailsMessage(details: String): String? = try {
            InputValidation.taskDetails(details)
            null
        } catch (error: AppError) {
            AppError.InvalidDetails.messageFR
        }

        /** Tomorrow at 18:00 in [calendar]'s time zone. */
        fun defaultDueDate(now: Instant, calendar: AppCalendar): Instant =
            calendar.instant(calendar.localDate(now).plusDays(1), LocalTime.of(18, 0))

        private fun isValidDueDate(date: Instant): Boolean = try {
            InputValidation.dueDate(date)
            true
        } catch (error: AppError) {
            false
        }

        private fun initialState(session: SessionModel, mode: TaskEditorMode, members: List<Membership>?): TaskEditorState {
            val draft = when (mode) {
                is TaskEditorMode.Create -> TaskDraft()
                is TaskEditorMode.Edit -> TaskDraft(mode.task)
            }
            return TaskEditorState(
                mode = mode,
                currentUserId = session.userId,
                original = draft,
                title = draft.title,
                details = draft.details,
                priority = draft.priority,
                hasDueDate = draft.dueAt != null,
                dueDate = draft.dueAt ?: defaultDueDate(session.platform.now(), session.platform.calendar),
                assigneeIds = draft.assigneeIds,
                members = members?.let { NameOrder.sortedMembers(it) } ?: emptyList(),
                loadState = if (members != null) LoadState.Loaded else LoadState.Idle,
            )
        }
    }
}
