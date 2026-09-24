package io.github.notkanaa.equipe.core.viewmodel

import io.github.notkanaa.equipe.core.AppCalendar
import io.github.notkanaa.equipe.core.AppError
import io.github.notkanaa.equipe.core.GroupPermissions
import io.github.notkanaa.equipe.core.GroupSummary
import io.github.notkanaa.equipe.core.MemberRole
import io.github.notkanaa.equipe.core.Membership
import io.github.notkanaa.equipe.core.TaskItem
import io.github.notkanaa.equipe.core.TaskPermissions
import io.github.notkanaa.equipe.core.TaskStatus
import io.github.notkanaa.equipe.core.TeamGroup
import io.github.notkanaa.equipe.core.logic.TaskFilter
import io.github.notkanaa.equipe.core.logic.TaskSort
import io.github.notkanaa.equipe.core.logic.isOverdue
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.async
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.collectLatest
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.map
import java.time.Instant
import java.util.UUID
import kotlin.coroutines.cancellation.CancellationException

// Port of TeamTasksCore/ViewModels/Groups/GroupDetailViewModel.swift.

/** State of the group screen. */
data class GroupDetailState(
    val groupId: UUID,
    /** The signed-in user. */
    val currentUserId: UUID,
    /** Calendar of the date wording. */
    val calendar: AppCalendar,
    /** Name of the summary handed over by the list (title before the first load). */
    val initialName: String? = null,
    val group: TeamGroup? = null,
    /** The current user's role in the group, null when not (or no longer) a member. */
    val myRole: MemberRole? = null,
    val members: List<Membership> = emptyList(),
    /** Every loaded task (unfiltered); display [rows]. */
    val tasks: List<TaskItem> = emptyList(),
    val loadState: LoadState = LoadState.Idle,
    /** The group was deleted or the user is no longer a member: leave the group's screens. */
    val isGone: Boolean = false,
    /** Tasks with a status change or a deletion in progress. */
    val busyTaskIds: Set<UUID> = emptySet(),
    /** Rename or deletion of the group in progress. */
    val isUpdatingGroup: Boolean = false,
    /** Date used for « En retard » and the due texts (refreshed at every load). */
    val referenceDate: Instant,
    val filter: TaskFilter = TaskFilter.ALL,
    val sort: TaskSort = TaskSort.DUE_DATE,
    /** Also show tasks completed more than 30 days ago (reloads). */
    val includeOldDone: Boolean = false,
    override val error: ErrorState? = null,
) : ErrorHolder {
    /** Screen title: the group's name (« Groupe » before it is known). */
    val title: String get() = group?.name ?: initialName ?: "Groupe"

    val directory: MemberDirectory get() = MemberDirectory(members, currentUserId)

    /** Filtered and sorted tasks, ready to display. */
    val rows: List<TaskRow> by lazy {
        val directory = directory
        sort.sorted(filter.apply(tasks, currentUserId, referenceDate)).map { task ->
            TaskRow(
                task = task,
                dueText = task.dueAt?.let { DateText.relative(it, referenceDate, calendar) },
                isOverdue = task.isOverdue(referenceDate),
                assigneesText = directory.assigneesText(task.assigneeIds),
                groupName = null,
                isNew = false,
                canChangeStatus = TaskPermissions.canChangeStatus(task, currentUserId, myRole),
                canEdit = TaskPermissions.canEdit(task, currentUserId, myRole),
                canDelete = TaskPermissions.canDelete(task, currentUserId, myRole),
            )
        }
    }

    /** No task at all (loaded). */
    val isEmpty: Boolean get() = loadState == LoadState.Loaded && tasks.isEmpty()

    /** Message when [rows] is empty: no task at all, or none matching the filter. */
    val emptyRowsMessage: String
        get() = if (tasks.isEmpty()) GroupDetailViewModel.EMPTY_MESSAGE else GroupDetailViewModel.NO_MATCH_MESSAGE

    val filterChips: List<TaskFilterChip> get() = TaskFilterChip.chips(filter)

    val hasActiveFilter: Boolean get() = filter.isActive

    // region Permissions

    val canCreateTask: Boolean get() = TaskPermissions.canCreate(myRole)
    val canRename: Boolean get() = GroupPermissions.canRename(myRole)
    val canDeleteGroup: Boolean get() = GroupPermissions.canDelete(myRole)
    val canManageMembers: Boolean get() = GroupPermissions.canManageMembers(myRole)
    val canSeeInviteCode: Boolean get() = GroupPermissions.canSeeInviteCode(myRole)

    fun canEdit(task: TaskItem): Boolean = TaskPermissions.canEdit(task, currentUserId, myRole)

    fun canChangeStatus(task: TaskItem): Boolean = TaskPermissions.canChangeStatus(task, currentUserId, myRole)

    fun canDelete(task: TaskItem): Boolean = TaskPermissions.canDelete(task, currentUserId, myRole)

    // endregion

    /** Display name of a member (« Ancien membre » when unknown). */
    fun memberName(userId: UUID?): String = directory.name(userId)

    /** « Vous » first, then the other assignees in name order. */
    fun assigneeNames(task: TaskItem): List<String> = directory.names(task.assigneeIds)

    /** Confirmation text of « Supprimer le groupe ». */
    val deleteGroupConfirmationMessage: String
        get() = "Le groupe « $title » et toutes ses tâches seront supprimés pour tous ses membres. " +
            "Cette action est définitive."
}

/**
 * Group screen: its tasks (filter chips, sort, « Afficher les anciennes terminées »), the current user's role and what
 * it allows, member names for the assignees, rename / delete for admins.
 *
 * Reloads when the group's revision changes (any task, assignee or member change, rename) and when
 * [GroupDetailState.includeOldDone] flips. Screen: `LaunchedEffect(model) { model.autoRefresh() }`, pull to refresh →
 * [reload]; leave the group's screens when [GroupDetailState.isGone] becomes true
 * (`router.removeRoutesForGroup(groupId)`).
 *
 * @param group the summary from the list, if known (title and role shown before the first load).
 */
class GroupDetailViewModel(
    val session: SessionModel,
    val groupId: UUID,
    scope: CoroutineScope,
    group: GroupSummary? = null,
) : ScreenModel<GroupDetailState>(
    GroupDetailState(
        groupId = groupId,
        currentUserId = session.userId,
        calendar = session.platform.calendar,
        initialName = group?.group?.name,
        group = group?.group,
        myRole = group?.myRole,
        referenceDate = session.platform.now(),
    ),
    { state, error -> state.copy(error = error) },
) {
    private val runner = LoadRunner(scope)
    private var loadedKey: RefreshKey? = null
    private var fetchingKey: RefreshKey? = null

    var filter: TaskFilter
        get() = current.filter
        set(value) = update { it.copy(filter = value) }

    var sort: TaskSort
        get() = current.sort
        set(value) = update { it.copy(sort = value) }

    /** Also show tasks completed more than 30 days ago (changes [refreshKey]: reloads). */
    var includeOldDone: Boolean
        get() = current.includeOldDone
        set(value) = update { it.copy(includeOldDone = value) }

    // region Loading

    val refreshKey: RefreshKey
        get() = RefreshKey(session.feed.groupRevision(groupId), includeDone = current.includeOldDone)

    /** [refreshKey] as a flow: the current value first, then every change. */
    val refreshKeys: Flow<RefreshKey> = combine(
        session.feed.groupRevisionFlow(groupId),
        mutableState.map { it.includeOldDone }.distinctUntilChanged(),
    ) { revision, includeOldDone -> RefreshKey(revision, includeOldDone) }.distinctUntilChanged()

    val needsRefresh: Boolean get() = current.loadState != LoadState.Loaded || loadedKey != refreshKey

    /** Loads if never loaded or out of date (no-op once gone). */
    suspend fun load() {
        if (!needsRefresh || current.isGone) return
        val upToDate = runner.isRunning && fetchingKey == refreshKey
        runner.run(rerunIfRunning = !upToDate) { fetch() }
    }

    /** Always fetches again (pull to refresh, « Réessayer »); no-op once gone. */
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
        val key = refreshKey
        fetchingKey = key
        try {
            update { it.copy(loadState = startedLoad(it.loadState)) }
            val groupService = session.services.groups
            val taskService = session.services.tasks
            val (groups, members, tasks) = coroutineScope {
                val groupsRequest = async { groupService.myGroups() }
                val membersRequest = async { groupService.members(groupId) }
                val tasksRequest = async { taskService.tasks(groupId, key.includeDone) }
                Triple(groupsRequest.await(), membersRequest.await(), tasksRequest.await())
            }
            val summary = groups.firstOrNull { it.id == groupId }
            if (summary == null) {
                markGone()
                return
            }
            loadedKey = key
            update {
                it.copy(
                    group = summary.group,
                    myRole = summary.myRole,
                    members = members,
                    tasks = tasks,
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
            fetchingKey = null
        }
    }

    private fun markGone() {
        update { it.copy(isGone = true, loadState = LoadState.Loaded) }
    }

    // endregion

    // region Filter

    fun toggleFilterChip(kind: TaskFilterChip.Kind) {
        update { it.copy(filter = TaskFilterChip.toggling(kind, it.filter)) }
    }

    fun resetFilter() {
        update { it.copy(filter = TaskFilter.ALL) }
    }

    // endregion

    // region Task actions

    /** Changes a task's status (admin, creator or assignee). */
    suspend fun setStatus(status: TaskStatus, task: TaskItem): Boolean {
        if (!current.canChangeStatus(task)) {
            present(AppError.Forbidden)
            return false
        }
        if (task.id in current.busyTaskIds) return false
        update { it.copy(error = null, busyTaskIds = it.busyTaskIds + task.id) }
        try {
            val updated = session.services.tasks.setStatus(task.id, status)
            replace(updated)
            session.feed.bump(groupId)
            session.feed.bumpMyTasks()
            return true
        } catch (error: CancellationException) {
            throw error
        } catch (error: Exception) {
            handleTaskFailure(error, task.id)
            return false
        } finally {
            update { it.copy(busyTaskIds = it.busyTaskIds - task.id) }
        }
    }

    /** Deletes a task (admin or creator). */
    suspend fun delete(task: TaskItem): Boolean {
        if (!current.canDelete(task)) {
            present(AppError.Forbidden)
            return false
        }
        if (task.id in current.busyTaskIds) return false
        update { it.copy(error = null, busyTaskIds = it.busyTaskIds + task.id) }
        try {
            session.services.tasks.delete(task.id)
            update { state -> state.copy(tasks = state.tasks.filter { it.id != task.id }) }
            session.feed.bump(groupId)
            session.feed.bumpMyTasks()
            return true
        } catch (error: CancellationException) {
            throw error
        } catch (error: Exception) {
            handleTaskFailure(error, task.id)
            return false
        } finally {
            update { it.copy(busyTaskIds = it.busyTaskIds - task.id) }
        }
    }

    /** Puts a task returned by another screen (editor, detail) in the list. */
    fun apply(task: TaskItem) {
        if (task.groupId != groupId) return
        replace(task)
    }

    private fun replace(task: TaskItem) {
        update { state ->
            val index = state.tasks.indexOfFirst { it.id == task.id }
            val tasks = if (index >= 0) {
                state.tasks.toMutableList().also { it[index] = task }
            } else {
                state.tasks + task
            }
            state.copy(tasks = tasks)
        }
    }

    private fun handleTaskFailure(error: Exception, taskId: UUID) {
        val appError = present(error) ?: return
        if (appError == AppError.NotFound) {
            update { state -> state.copy(tasks = state.tasks.filter { it.id != taskId }) }
            session.feed.bump(groupId)
        }
    }

    // endregion

    // region Group actions (admins)

    /** Renames the group. Returns false with `error` set on failure (invalid name, not admin…). */
    suspend fun rename(name: String): Boolean {
        if (!current.canRename) {
            present(AppError.Forbidden)
            return false
        }
        if (current.isUpdatingGroup) return false
        dismissError()
        val message = CreateGroupViewModel.nameMessage(name)
        if (message != null) {
            present(message, AppError.InvalidName)
            return false
        }
        update { it.copy(isUpdatingGroup = true) }
        try {
            val renamed = session.services.groups.rename(groupId, name)
            update { it.copy(group = renamed) }
            session.feed.bump(groupId)
            session.feed.bumpMemberships()
            return true
        } catch (error: CancellationException) {
            throw error
        } catch (error: Exception) {
            if (present(error) == AppError.NotFound) markGone()
            return false
        } finally {
            update { it.copy(isUpdatingGroup = false) }
        }
    }

    /** Deletes the group and all its tasks (admins). On success [GroupDetailState.isGone] becomes true. */
    suspend fun deleteGroup(): Boolean {
        if (!current.canDeleteGroup) {
            present(AppError.Forbidden)
            return false
        }
        if (current.isUpdatingGroup) return false
        dismissError()
        update { it.copy(isUpdatingGroup = true) }
        try {
            session.services.groups.deleteGroup(groupId)
            markGone()
            session.feed.bumpMemberships()
            session.feed.bumpMyTasks()
            return true
        } catch (error: CancellationException) {
            throw error
        } catch (error: Exception) {
            if (present(error) == AppError.NotFound) markGone()
            return false
        } finally {
            update { it.copy(isUpdatingGroup = false) }
        }
    }

    // endregion

    companion object {
        const val GONE_MESSAGE: String = "Ce groupe n’existe plus ou vous n’en faites plus partie."
        const val EMPTY_MESSAGE: String = "Aucune tâche pour l’instant."
        const val NO_MATCH_MESSAGE: String = "Aucune tâche ne correspond aux filtres."
    }
}
