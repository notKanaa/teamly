package io.github.notkanaa.equipe.core.viewmodel

import io.github.notkanaa.equipe.core.AppCalendar
import io.github.notkanaa.equipe.core.AppError
import io.github.notkanaa.equipe.core.KeyValueStore
import io.github.notkanaa.equipe.core.KeyValueStoreJson
import io.github.notkanaa.equipe.core.TaskItem
import io.github.notkanaa.equipe.core.TaskStatus
import io.github.notkanaa.equipe.core.logic.DueBucket
import io.github.notkanaa.equipe.core.logic.InstantIsoSerializer
import io.github.notkanaa.equipe.core.logic.isAssignedTo
import io.github.notkanaa.equipe.core.logic.isOverdue
import io.github.notkanaa.equipe.core.uuidString
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.collectLatest
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.map
import java.time.Instant
import java.util.UUID
import kotlin.coroutines.cancellation.CancellationException

// Port of TeamTasksCore/ViewModels/Tasks/MyTasksViewModel.swift.

/** A section of « Mes tâches ». */
data class MyTasksSection(
    val bucket: DueBucket,
    val rows: List<TaskRow>,
) {
    val id: DueBucket get() = bucket

    /** « En retard », « Aujourd’hui », « Cette semaine », « Plus tard », « Sans échéance », « Terminées ». */
    val title: String get() = bucket.title
}

/** State of the « Mes tâches » tab. */
data class MyTasksState(
    /** The signed-in user. */
    val currentUserId: UUID,
    /** Calendar of the sections and date wording. */
    val calendar: AppCalendar,
    /** Every loaded task (display [sections]). */
    val tasks: List<TaskItem> = emptyList(),
    val loadState: LoadState = LoadState.Idle,
    /** Also show done tasks (« Terminées » section; reloads). */
    val includeDone: Boolean = false,
    /** Assignments after this date are « Nouveau » (null: never looked, every assignment by someone else is new). */
    val lastSeenAt: Instant? = null,
    /** Date used for the sections and the due texts (refreshed at every load). */
    val referenceDate: Instant,
    /** Tasks with a status change in progress. */
    val busyTaskIds: Set<UUID> = emptySet(),
    override val error: ErrorState? = null,
) : ErrorHolder {
    /** Non-empty sections in display order (done tasks only when [includeDone]). */
    val sections: List<MyTasksSection> by lazy {
        val visible = if (includeDone) tasks else tasks.filter { it.status != TaskStatus.DONE }
        DueBucket.sections(visible, referenceDate, calendar).map { section ->
            MyTasksSection(section.bucket, section.tasks.map { row(it) })
        }
    }

    val isEmpty: Boolean get() = loadState == LoadState.Loaded && sections.isEmpty()

    /** Number of « Nouveau » tasks (tab badge). */
    val newCount: Int get() = tasks.count { isNew(it) }

    /**
     * Assigned to me by someone else (or by a since-deleted account) after [lastSeenAt], not done. Tasks I created and
     * tasks I assigned to myself are never new (like `AssignmentNotifier`, which ignores self-assignments).
     */
    fun isNew(task: TaskItem): Boolean {
        if (task.status == TaskStatus.DONE || task.createdBy == currentUserId || task.myAssignedBy == currentUserId) {
            return false
        }
        val assignedAt = task.myAssignedAt ?: return false
        val lastSeen = lastSeenAt ?: return true
        return assignedAt > lastSeen
    }

    private fun row(task: TaskItem): TaskRow = TaskRow(
        task = task,
        dueText = task.dueAt?.let { DateText.relative(it, referenceDate, calendar) },
        isOverdue = task.isOverdue(referenceDate),
        assigneesText = null,
        groupName = task.groupName,
        isNew = isNew(task),
        // An assignee may always change the status; editing needs the role, known on the group screens.
        canChangeStatus = task.isAssignedTo(currentUserId),
        canEdit = false,
        canDelete = false,
    )
}

/**
 * « Mes tâches » tab: tasks assigned to the current user in every group, in due-date sections, with a « Nouveau » badge
 * on tasks assigned by someone else since the user last looked ([markAllSeen]).
 *
 * Every successful load also synchronizes the due-date reminders with the loaded list (never after a failed load).
 * Reloads when the « Mes tâches » revision changes and when [MyTasksState.includeDone] flips.
 * Screen: `LaunchedEffect(model) { model.autoRefresh() }`, pull to refresh → [reload], [markAllSeen] when the screen is
 * left (`DisposableEffect`), tab badge [MyTasksState.newCount]. One instance per session is available as
 * `SessionModel.myTasks` (shared by the tab badge and the screen).
 */
class MyTasksViewModel(
    val session: SessionModel,
    scope: CoroutineScope,
) : ScreenModel<MyTasksState>(
    MyTasksState(
        currentUserId = session.userId,
        calendar = session.platform.calendar,
        referenceDate = session.platform.now(),
    ),
    { state, error -> state.copy(error = error) },
) {
    private val runner = LoadRunner(scope)
    private var loadedKey: RefreshKey? = null
    private var fetchingKey: RefreshKey? = null
    private var hasReadLastSeen = false

    /** Also show done tasks (changes [refreshKey]: reloads). */
    var includeDone: Boolean
        get() = current.includeDone
        set(value) = update { it.copy(includeDone = value) }

    // region Loading

    val refreshKey: RefreshKey
        get() = RefreshKey(session.feed.myTasksRevision.value, includeDone = current.includeDone)

    /** [refreshKey] as a flow: the current value first, then every change. */
    val refreshKeys: Flow<RefreshKey> = combine(
        session.feed.myTasksRevision,
        mutableState.map { it.includeDone }.distinctUntilChanged(),
    ) { revision, includeDone -> RefreshKey(revision, includeDone) }.distinctUntilChanged()

    val needsRefresh: Boolean get() = current.loadState != LoadState.Loaded || loadedKey != refreshKey

    /** Loads if never loaded or out of date; otherwise returns immediately. */
    suspend fun load() {
        if (!needsRefresh) return
        val upToDate = runner.isRunning && fetchingKey == refreshKey
        runner.run(rerunIfRunning = !upToDate) { fetch() }
    }

    /** Always fetches again (pull to refresh, « Réessayer »). */
    suspend fun reload() {
        runner.run(rerunIfRunning = true) { fetch() }
    }

    /** Loads now, then again whenever [refreshKey] changes. Never returns: run it in a `LaunchedEffect`. */
    suspend fun autoRefresh() {
        refreshKeys.collectLatest { load() }
    }

    private suspend fun fetch() {
        val key = refreshKey
        fetchingKey = key
        try {
            if (!hasReadLastSeen) {
                hasReadLastSeen = true
                val lastSeen = loadLastSeen(session.platform.store, session.userId)
                update { it.copy(lastSeenAt = lastSeen) }
            }
            update { it.copy(loadState = startedLoad(it.loadState)) }
            val loaded = try {
                session.services.tasks.myTasks(key.includeDone)
            } catch (error: CancellationException) {
                update { it.copy(loadState = cancelledLoad(it.loadState)) }
                throw error
            } catch (error: Exception) {
                update {
                    val failure = loadFailure(it.loadState, it.error, error)
                    it.copy(loadState = failure.loadState, error = failure.error)
                }
                return
            }
            loadedKey = key
            update {
                it.copy(
                    tasks = loaded,
                    referenceDate = session.platform.now(),
                    calendar = session.platform.calendar,
                    loadState = LoadState.Loaded,
                )
            }
            // Only a successfully loaded list may drive the reminders (docs/CONTRACTS.md §7).
            session.synchronizeReminders(loaded)
        } finally {
            fetchingKey = null
        }
    }

    // endregion

    // region Actions

    /**
     * Clears every « Nouveau » badge (persisted per user). Uses the latest assignment date when the device clock is
     * behind the server.
     */
    fun markAllSeen() {
        val latest = current.tasks.mapNotNull { it.myAssignedAt }.maxOrNull()
        val now = session.platform.now()
        val mark = if (latest != null && latest > now) latest else now
        hasReadLastSeen = true
        update { it.copy(lastSeenAt = mark) }
        saveLastSeen(session.platform.store, session.userId, mark)
    }

    /** Changes the status of one of my tasks (assignees may always do it). */
    suspend fun setStatus(status: TaskStatus, task: TaskItem): Boolean {
        if (task.id in current.busyTaskIds) return false
        update { it.copy(error = null, busyTaskIds = it.busyTaskIds + task.id) }
        try {
            val updated = session.services.tasks.setStatus(task.id, status)
            update { state ->
                val index = state.tasks.indexOfFirst { it.id == task.id }
                if (index < 0) {
                    state
                } else {
                    val previous = state.tasks[index]
                    val merged = updated.copy(
                        myAssignedAt = previous.myAssignedAt,
                        myAssignedBy = previous.myAssignedBy,
                        groupName = previous.groupName,
                    )
                    state.copy(tasks = state.tasks.toMutableList().also { it[index] = merged })
                }
            }
            session.feed.bump(task.groupId)
            session.feed.bumpMyTasks()
            return true
        } catch (error: CancellationException) {
            throw error
        } catch (error: Exception) {
            if (present(error) == AppError.NotFound) {
                update { state -> state.copy(tasks = state.tasks.filter { it.id != task.id }) }
                session.feed.bumpMyTasks()
            }
            return false
        } finally {
            update { it.copy(busyTaskIds = it.busyTaskIds - task.id) }
        }
    }

    // endregion

    companion object {
        const val EMPTY_TITLE: String = "Aucune tâche"
        const val EMPTY_MESSAGE: String = "Les tâches qui vous sont assignées apparaîtront ici."
        const val NEW_BADGE_TEXT: String = "Nouveau"

        /** `KeyValueStore` key of the user's « last seen » date. */
        fun lastSeenKey(userId: UUID): String = "myTasks.lastSeen.${userId.uuidString}"

        /** The stored « last seen » date of [userId] (ISO-8601 JSON string), null when absent or unreadable. */
        internal fun loadLastSeen(store: KeyValueStore, userId: UUID): Instant? {
            val bytes = store.data(lastSeenKey(userId)) ?: return null
            return try {
                KeyValueStoreJson.decodeFromString(InstantIsoSerializer, bytes.decodeToString())
            } catch (error: IllegalArgumentException) { // SerializationException included
                null
            }
        }

        internal fun saveLastSeen(store: KeyValueStore, userId: UUID, date: Instant) {
            store.set(lastSeenKey(userId), KeyValueStoreJson.encodeToString(InstantIsoSerializer, date).encodeToByteArray())
        }
    }
}
