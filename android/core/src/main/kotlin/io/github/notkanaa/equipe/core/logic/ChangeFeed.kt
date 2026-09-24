package io.github.notkanaa.equipe.core.logic

import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.update
import java.util.UUID

// Port of TeamTasksCore/Logic/ChangeFeed.swift (@MainActor @Observable → StateFlows, thread-safe).

/**
 * Revision counters that view models observe to know when to reload (fed by [RealtimeCoordinator], and bumped locally
 * after the user's own mutations).
 *
 * Revisions only ever increase (wrapping on overflow, like Swift's `&+`). A view model remembers the revision it loaded
 * and reloads when the observed value changes, e.g. `feed.groupRevisionFlow(groupId).collect { reload() }` or
 * `feed.myTasksRevision.collect { reload() }`.
 */
class ChangeFeed {
    private val membershipsState = MutableStateFlow(0)
    private val myTasksState = MutableStateFlow(0)
    private val allState = MutableStateFlow(0)
    private val groupsState = MutableStateFlow<Map<UUID, Int>>(emptyMap())

    /** Bumped when the current user's memberships change (group list, roles). */
    val membershipsRevision: StateFlow<Int> = membershipsState.asStateFlow()

    /** Bumped when the tasks assigned to the current user may have changed ("Mes tâches", reminders). */
    val myTasksRevision: StateFlow<Int> = myTasksState.asStateFlow()

    /** Bumped by [bumpAll]; part of every group revision. */
    val allRevision: StateFlow<Int> = allState.asStateFlow()

    /**
     * Per-group counters bumped by [bump] only (without [allRevision]; a group never bumped is absent).
     * Observe [groupRevisionFlow] or read [groupRevision] for a group's full revision.
     */
    val groupRevisions: StateFlow<Map<UUID, Int>> = groupsState.asStateFlow()

    /**
     * Revision of one group's content (tasks, assignees, members, name). Includes [allRevision], so [bumpAll] changes
     * every group's revision, including groups never bumped before.
     */
    fun groupRevision(groupId: UUID): Int = allState.value + (groupsState.value[groupId] ?: 0)

    /** [groupRevision] as a flow: the current value first, then every change. */
    fun groupRevisionFlow(groupId: UUID): Flow<Int> =
        combine(allState, groupsState) { all, groups -> all + (groups[groupId] ?: 0) }.distinctUntilChanged()

    fun bump(groupId: UUID) {
        groupsState.update { current -> current + (groupId to ((current[groupId] ?: 0) + 1)) }
    }

    fun bumpMemberships() {
        membershipsState.update { it + 1 }
    }

    fun bumpMyTasks() {
        myTasksState.update { it + 1 }
    }

    /** Everything may have changed (realtime reconnection, return to foreground). */
    fun bumpAll() {
        allState.update { it + 1 }
        membershipsState.update { it + 1 }
        myTasksState.update { it + 1 }
    }
}
