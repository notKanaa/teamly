package io.github.notkanaa.equipe.core.viewmodel

import io.github.notkanaa.equipe.core.AppCalendar
import io.github.notkanaa.equipe.core.AppError
import io.github.notkanaa.equipe.core.MemberRole
import io.github.notkanaa.equipe.core.Membership
import io.github.notkanaa.equipe.core.TaskItem
import io.github.notkanaa.equipe.core.TaskPermissions
import io.github.notkanaa.equipe.core.TaskPriority
import io.github.notkanaa.equipe.core.TaskStatus
import io.github.notkanaa.equipe.core.logic.isOverdue
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.async
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.collectLatest
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.map
import java.time.Instant
import java.util.UUID
import kotlin.coroutines.cancellation.CancellationException

// Port of TeamTasksCore/ViewModels/Tasks/TaskDetailViewModel.swift.

/** State of the task screen. */
data class TaskDetailState(
    val groupId: UUID,
    val taskId: UUID,
    /** The signed-in user. */
    val currentUserId: UUID,
    /** Calendar of the date wording. */
    val calendar: AppCalendar,
    /** The task (the one handed over by the list until the first load), null when unknown or gone. */
    val task: TaskItem? = null,
    val members: List<Membership> = emptyList(),
    val loadState: LoadState = LoadState.Idle,
    /** Deleted (here or by someone else) or no longer visible: leave the screen. */
    val isGone: Boolean = false,
    /** Set by a successful `delete()`. */
    val didDelete: Boolean = false,
    /** Status change or deletion in progress. */
    val isWorking: Boolean = false,
    /** Date used for « En retard » and the date texts (refreshed at every load). */
    val referenceDate: Instant,
    override val error: ErrorState? = null,
) : ErrorHolder {
    val directory: MemberDirectory get() = MemberDirectory(members, currentUserId)

    /** The current user's role in the group, null when not a member (or not loaded yet). */
    val myRole: MemberRole? get() = directory.myRole

    /** The task's title (« Tâche » before it is known). */
    val title: String get() = task?.title ?: "Tâche"
    val details: String? get() = task?.details
    val status: TaskStatus? get() = task?.status
    val priority: TaskPriority? get() = task?.priority

    /** « Aujourd’hui à 20:00 », null without due date. */
    val dueText: String? get() = task?.dueAt?.let { DateText.relative(it, referenceDate, calendar) }

    val isOverdue: Boolean get() = task?.isOverdue(referenceDate) ?: false

    /** « Vous » first, then the other assignees by name; empty when unassigned. */
    val assigneeNames: List<String> get() = directory.names(task?.assigneeIds ?: emptyList())

    /** « Vous, Lucas Bernard » / « Non assignée ». */
    val assigneesText: String get() = directory.assigneesText(task?.assigneeIds ?: emptyList())

    /** « Vous », the creator's name, or « Ancien membre » (left the group or deleted account). */
    val creatorName: String?
        get() {
            val task = task ?: return null
            if (task.createdBy == currentUserId) return MemberDirectory.ME_NAME
            return directory.name(task.createdBy)
        }

    /** « Créée par Lucas Bernard hier à 10:00 » / « Créée par vous le lundi 14 septembre à 09:00 ». */
    val createdText: String?
        get() {
            val task = task ?: return null
            val creatorName = creatorName ?: return null
            val who = if (task.createdBy == currentUserId) "vous" else creatorName
            val whenText = DateText.relativeInSentence(task.createdAt, referenceDate, calendar)
            return "Créée par $who $whenText"
        }

    /** « Terminée aujourd’hui à 09:00 » / « Terminée le lundi 14 septembre à 09:00 », null unless done. */
    val completedText: String?
        get() {
            val task = task ?: return null
            val completedAt = task.completedAt ?: return null
            if (task.status != TaskStatus.DONE) return null
            return "Terminée ${DateText.relativeInSentence(completedAt, referenceDate, calendar)}"
        }

    // region Permissions

    val canEdit: Boolean get() = task?.let { TaskPermissions.canEdit(it, currentUserId, myRole) } ?: false

    val canChangeStatus: Boolean get() = task?.let { TaskPermissions.canChangeStatus(it, currentUserId, myRole) } ?: false

    val canDelete: Boolean get() = task?.let { TaskPermissions.canDelete(it, currentUserId, myRole) } ?: false

    // endregion

    /** Status choices, in order. */
    val statusOptions: List<TaskStatus> get() = TaskStatus.entries.toList()

    /** Mode of `TaskEditorSheet` for this task, null when not editable or not loaded. Android addition. */
    val editorMode: TaskEditorMode?
        get() {
            val task = task ?: return null
            return if (canEdit) TaskEditorMode.Edit(task) else null
        }

    /** Confirmation text of « Supprimer la tâche ». */
    val deleteConfirmationMessage: String
        get() = "La tâche « $title » sera supprimée pour tous les membres du groupe."
}

/**
 * Task screen: fields, assignee and creator names, status change (admin, creator, assignee), edit and delete (admin,
 * creator).
 *
 * Reloads when the group's revision changes. Screen: `LaunchedEffect(model) { model.autoRefresh() }`; leave the screen
 * when [TaskDetailState.isGone] becomes true (deleted here or elsewhere, or no longer visible:
 * `router.removeRoutesForTask(taskId)`).
 *
 * @param task the task from the list, if known (shown before the first load; ignored unless it matches both ids).
 */
class TaskDetailViewModel(
    val session: SessionModel,
    val groupId: UUID,
    val taskId: UUID,
    private val scope: CoroutineScope,
    task: TaskItem? = null,
) : ScreenModel<TaskDetailState>(
    TaskDetailState(
        groupId = groupId,
        taskId = taskId,
        currentUserId = session.userId,
        calendar = session.platform.calendar,
        task = task?.takeIf { it.id == taskId && it.groupId == groupId },
        referenceDate = session.platform.now(),
    ),
    { state, error -> state.copy(error = error) },
) {
    private val runner = LoadRunner(scope)
    private var loadedRevision: Int? = null
    private var fetchingRevision: Int? = null

    // region Loading

    val refreshKey: RefreshKey get() = RefreshKey(session.feed.groupRevision(groupId))

    /** [refreshKey] as a flow: the current value first, then every change. */
    val refreshKeys: Flow<RefreshKey> = session.feed.groupRevisionFlow(groupId).map { RefreshKey(it) }.distinctUntilChanged()

    val needsRefresh: Boolean
        get() = current.loadState != LoadState.Loaded || loadedRevision != refreshKey.revision

    /** Loads if never loaded or out of date (no-op once gone). */
    suspend fun load() {
        if (!needsRefresh || current.isGone) return
        val upToDate = runner.isRunning && fetchingRevision == refreshKey.revision
        runner.run(rerunIfRunning = !upToDate) { fetch() }
    }

    /** Always fetches again; no-op once gone. */
    suspend fun reload() {
        if (current.isGone) return
        runner.run(rerunIfRunning = true) { fetch() }
    }

    /** Loads now, then again whenever [refreshKey] changes. Never returns: run it in a `LaunchedEffect`. */
    suspend fun autoRefresh() {
        refreshKeys.collectLatest { load() }
    }

    private suspend fun fetch() {
        if (current.isGone) return
        val revision = refreshKey.revision
        fetchingRevision = revision
        try {
            update { it.copy(loadState = startedLoad(it.loadState)) }
            val taskService = session.services.tasks
            val groupService = session.services.groups
            val (task, members) = coroutineScope {
                val taskRequest = async { taskService.task(taskId) }
                val membersRequest = async { groupService.members(groupId) }
                taskRequest.await() to membersRequest.await()
            }
            if (task.groupId != groupId) {
                // A link naming another group (`equipe://task/<group>/<task>`; a task never changes group): the rights,
                // names and reloads would follow the wrong group.
                update { it.copy(task = null) }
                markGone()
                return
            }
            loadedRevision = revision
            update {
                it.copy(
                    task = task,
                    members = members,
                    referenceDate = session.platform.now(),
                    calendar = session.platform.calendar,
                    loadState = LoadState.Loaded,
                )
            }
        } catch (error: CancellationException) {
            update { it.copy(loadState = cancelledLoad(it.loadState)) }
            throw error
        } catch (error: Exception) {
            if (error == AppError.NotFound) {
                markGone()
            } else {
                update {
                    val failure = loadFailure(it.loadState, it.error, error)
                    it.copy(loadState = failure.loadState, error = failure.error)
                }
            }
        } finally {
            fetchingRevision = null
        }
    }

    private fun markGone() {
        update { it.copy(isGone = true, loadState = LoadState.Loaded) }
    }

    // endregion

    // region Actions

    /** Changes the status (admin, creator or assignee). Returns false when it is already [status]. */
    suspend fun setStatus(status: TaskStatus): Boolean {
        if (!current.canChangeStatus) {
            present(AppError.Forbidden)
            return false
        }
        if (current.isWorking || current.task?.status == status) return false
        update { it.copy(error = null, isWorking = true) }
        try {
            val updated = session.services.tasks.setStatus(taskId, status)
            update { it.copy(task = updated) }
            session.feed.bump(groupId)
            session.feed.bumpMyTasks()
            return true
        } catch (error: CancellationException) {
            throw error
        } catch (error: Exception) {
            if (present(error) == AppError.NotFound) markGone()
            return false
        } finally {
            update { it.copy(isWorking = false) }
        }
    }

    /** Deletes the task (admin or creator). On success [TaskDetailState.didDelete] and `isGone` become true. */
    suspend fun delete(): Boolean {
        if (!current.canDelete) {
            present(AppError.Forbidden)
            return false
        }
        if (current.isWorking) return false
        update { it.copy(error = null, isWorking = true) }
        try {
            session.services.tasks.delete(taskId)
            update { it.copy(didDelete = true) }
            markGone()
            session.feed.bump(groupId)
            session.feed.bumpMyTasks()
            return true
        } catch (error: CancellationException) {
            throw error
        } catch (error: Exception) {
            if (present(error) == AppError.NotFound) markGone()
            return false
        } finally {
            update { it.copy(isWorking = false) }
        }
    }

    /**
     * Editor for this task (null when not editable or not loaded), with the members handed over. On save call
     * [apply] (the group revision also changes, which reloads this screen).
     */
    fun makeEditor(editorScope: CoroutineScope = scope): TaskEditorViewModel? {
        val state = current
        val task = state.task ?: return null
        if (!state.canEdit) return null
        return TaskEditorViewModel(
            session,
            TaskEditorMode.Edit(task),
            editorScope,
            members = state.members.ifEmpty { null },
        )
    }

    /** Shows a task saved by the editor. */
    fun apply(updated: TaskItem) {
        if (updated.id != taskId) return
        update { it.copy(task = updated) }
    }

    // endregion

    companion object {
        const val GONE_MESSAGE: String = "Cette tâche n’existe plus."
    }
}
