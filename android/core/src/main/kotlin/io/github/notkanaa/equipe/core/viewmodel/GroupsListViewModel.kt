package io.github.notkanaa.equipe.core.viewmodel

import io.github.notkanaa.equipe.core.GroupSummary
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.collectLatest
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.map
import java.util.UUID
import kotlin.coroutines.cancellation.CancellationException

// Port of TeamTasksCore/ViewModels/Groups/GroupsListViewModel.swift.

/** State of the « Groupes » tab root. */
data class GroupsListState(
    /** Most recently active first. */
    val groups: List<GroupSummary> = emptyList(),
    val loadState: LoadState = LoadState.Idle,
    override val error: ErrorState? = null,
) : ErrorHolder {
    /** Loaded, and the user belongs to no group: show the empty state. */
    val isEmpty: Boolean get() = loadState == LoadState.Loaded && groups.isEmpty()
}

/**
 * « Groupes » tab root: the groups of the current user, most recently active first.
 *
 * Reloads when the memberships revision changes (joined, left, removed, role changed, group created or deleted) and when
 * one of the listed groups has activity (renamed, reordered by `last_activity_at`).
 * Screen: `LaunchedEffect(model) { model.autoRefresh() }`, pull to refresh / « Réessayer » → [reload].
 *
 * @param scope where the fetches run (e.g. `viewModelScope`); cancelling a caller of [load] never cancels a fetch.
 */
class GroupsListViewModel(
    val session: SessionModel,
    scope: CoroutineScope,
) : ScreenModel<GroupsListState>(GroupsListState(), { state, error -> state.copy(error = error) }) {
    private val runner = LoadRunner(scope)
    private var loadedMemberships: Int? = null
    private var loadedGroupRevisions: Map<UUID, Int> = emptyMap()

    /** Memberships revision read when the fetch in progress started. */
    private var fetchingMemberships: Int? = null

    /** What the list shows: the memberships revision plus the revision of every listed group. */
    val refreshKey: RefreshKey
        get() {
            val feed = session.feed
            var revision = feed.membershipsRevision.value
            for (group in current.groups) revision += feed.groupRevision(group.id)
            return RefreshKey(revision)
        }

    /** [refreshKey] as a flow: the current value first, then every change. */
    val refreshKeys: Flow<RefreshKey> = run {
        val feed = session.feed
        val listedIds = mutableState.map { state -> state.groups.map { it.id } }.distinctUntilChanged()
        combine(feed.membershipsRevision, feed.allRevision, feed.groupRevisions, listedIds) { memberships, all, groups, ids ->
            var revision = memberships
            for (id in ids) revision += all + (groups[id] ?: 0)
            RefreshKey(revision)
        }.distinctUntilChanged()
    }

    /** True when the content is older than the latest change signals. */
    val needsRefresh: Boolean
        get() {
            val feed = session.feed
            val state = current
            if (state.loadState != LoadState.Loaded || loadedMemberships != feed.membershipsRevision.value) return true
            return state.groups.any { feed.groupRevision(it.id) != loadedGroupRevisions[it.id] }
        }

    /** Loads if never loaded or out of date; otherwise returns immediately. Safe to call repeatedly. */
    suspend fun load() {
        if (!needsRefresh) return
        val upToDate = runner.isRunning && fetchingMemberships == session.feed.membershipsRevision.value
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
        val feed = session.feed
        val startMemberships = feed.membershipsRevision.value
        val startGroupRevisions = HashMap<UUID, Int>()
        for (group in current.groups) startGroupRevisions.putIfAbsent(group.id, feed.groupRevision(group.id))
        fetchingMemberships = startMemberships
        try {
            update { it.copy(loadState = startedLoad(it.loadState)) }
            val result = session.services.groups.myGroups()
            loadedMemberships = startMemberships
            // Groups new to the list: their revision at the end of the fetch (their data is at least that recent).
            val revisions = HashMap<UUID, Int>()
            for (group in result) {
                revisions.putIfAbsent(group.id, startGroupRevisions[group.id] ?: feed.groupRevision(group.id))
            }
            loadedGroupRevisions = revisions
            update { it.copy(groups = result, loadState = LoadState.Loaded) }
        } catch (error: CancellationException) {
            update { it.copy(loadState = cancelledLoad(it.loadState)) }
            throw error
        } catch (error: Exception) {
            update {
                val failure = loadFailure(it.loadState, it.error, error)
                it.copy(loadState = failure.loadState, error = failure.error)
            }
        } finally {
            fetchingMemberships = null
        }
    }

    companion object {
        const val EMPTY_TITLE: String = "Aucun groupe"
        const val EMPTY_MESSAGE: String = "Créez un groupe ou rejoignez-en un avec un code d’invitation."
    }
}
