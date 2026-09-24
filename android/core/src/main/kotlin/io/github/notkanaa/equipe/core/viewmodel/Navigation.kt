package io.github.notkanaa.equipe.core.viewmodel

import io.github.notkanaa.equipe.core.uuidString
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import java.net.URI
import java.net.URISyntaxException
import java.util.Locale
import java.util.UUID

// Port of TeamTasksCore/ViewModels/Navigation/Router.swift (AppTab, AppRoute, DeepLink, Router).

/** Tabs of the signed-in app. [rawValue] is the Swift raw value. */
enum class AppTab(
    val rawValue: String,
    /** Tab title (French). */
    val title: String,
    /** SF Symbols name of the iOS tab icon (reference). */
    val systemImage: String,
    /** Material icon (material-icons-extended): `Groups`, `Checklist`, `Settings`. */
    val iconName: String,
) {
    GROUPS("groups", "Groupes", "person.3", "Groups"),
    MY_TASKS("myTasks", "Mes tâches", "checklist", "Checklist"),
    SETTINGS("settings", "Réglages", "gearshape", "Settings"),
    ;

    val id: String get() = rawValue

    companion object {
        /** The tab whose raw value is [rawValue], or null. */
        fun fromRawValue(rawValue: String): AppTab? = entries.firstOrNull { it.rawValue == rawValue }
    }
}

/** Destinations pushed on a tab's back stack. Only ids: every screen loads its own data. */
sealed interface AppRoute {
    /** The group this destination belongs to. */
    val groupId: UUID

    /** Group screen (`GroupDetailScreen`). */
    data class Group(override val groupId: UUID) : AppRoute

    /** Task screen (`TaskDetailScreen`). */
    data class Task(override val groupId: UUID, val taskId: UUID) : AppRoute

    /** « Membres » screen (`MembersScreen`). */
    data class Members(override val groupId: UUID) : AppRoute
}

/**
 * An external request to show something: `equipe://task/<groupId>/<taskId>` links (ntfy `click` field) and taps on
 * local notifications (docs/CONTRACTS.md §7).
 */
sealed interface DeepLink {
    data class Task(val groupId: UUID, val taskId: UUID) : DeepLink

    data class Group(val groupId: UUID) : DeepLink

    /** « Mes tâches » (e.g. a grouped notification about several groups). */
    data object MyTasks : DeepLink

    /** The `equipe://` URL of this link (upper-case UUIDs). */
    val url: String
        get() = when (this) {
            is Task -> "$SCHEME://task/${groupId.uuidString}/${taskId.uuidString}"
            is Group -> "$SCHEME://group/${groupId.uuidString}"
            MyTasks -> "$SCHEME://mytasks"
        }

    companion object {
        const val SCHEME: String = "equipe"

        private val uuidPattern =
            Regex("[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}")

        /**
         * Parses `equipe://task/<groupId>/<taskId>` (also `equipe://group/<groupId>` and `equipe://mytasks`). Scheme and
         * host are case-insensitive; a trailing slash is accepted. Returns null for anything else (Swift
         * `DeepLink(url:)`).
         */
        fun parse(url: String): DeepLink? {
            val uri = try {
                URI(url)
            } catch (error: URISyntaxException) {
                return null
            }
            if (uri.scheme?.lowercase(Locale.ROOT) != SCHEME) return null
            val host = (uri.host ?: uri.authority)?.lowercase(Locale.ROOT) ?: return null
            val parts = (uri.path ?: "").split('/').filter { it.isNotEmpty() }
            return when (host) {
                "task" -> {
                    if (parts.size != 2) return null
                    val groupId = parseUuid(parts[0]) ?: return null
                    val taskId = parseUuid(parts[1]) ?: return null
                    Task(groupId, taskId)
                }
                "group" -> {
                    if (parts.size != 1) return null
                    Group(parseUuid(parts[0]) ?: return null)
                }
                "mytasks" -> if (parts.isEmpty()) MyTasks else null
                else -> null
            }
        }

        /**
         * Routing of a tapped local notification from its extras (`taskId`, `groupId` as UUID strings; values of another
         * type are ignored): both → the task; only `groupId` (grouped summary of one group) → the group; otherwise
         * « Mes tâches » (Swift `DeepLink(notificationUserInfo:)`).
         */
        fun fromNotification(userInfo: Map<String, Any?>): DeepLink {
            val groupId = (userInfo["groupId"] as? String)?.let(::parseUuid)
            val taskId = (userInfo["taskId"] as? String)?.let(::parseUuid)
            return when {
                groupId != null && taskId != null -> Task(groupId, taskId)
                groupId != null -> Group(groupId)
                else -> MyTasks
            }
        }

        /** Swift `UUID(uuidString:)`: only the canonical 8-4-4-4-12 form (any case). */
        internal fun parseUuid(text: String): UUID? =
            if (uuidPattern.matches(text)) UUID.fromString(text) else null
    }
}

/** Navigation state of the signed-in app (see [Router]). */
data class RouterState(
    val selectedTab: AppTab = AppTab.GROUPS,
    /** Back stack of the « Groupes » tab above its root (the groups list): group, task, members. */
    val groupsPath: List<AppRoute> = emptyList(),
    /** Back stack of the « Mes tâches » tab above its root (task details, possibly group screens). */
    val myTasksPath: List<AppRoute> = emptyList(),
    /** A deep link waiting for a session. */
    val pendingDeepLink: DeepLink? = null,
    /** True while a session is active (deep links are applied immediately). */
    val isActive: Boolean = false,
) {
    /** Back stack of [tab] (always empty for « Réglages », which has no destinations). */
    fun path(tab: AppTab): List<AppRoute> = when (tab) {
        AppTab.GROUPS -> groupsPath
        AppTab.MY_TASKS -> myTasksPath
        AppTab.SETTINGS -> emptyList()
    }

    /** Back stack of the selected tab. */
    val currentPath: List<AppRoute> get() = path(selectedTab)

    /** Top destination of the selected tab, null at its root. */
    val currentRoute: AppRoute? get() = currentPath.lastOrNull()
}

/**
 * Navigation state of the signed-in app: selected tab and the back stacks of the « Groupes » and « Mes tâches » tabs
 * (each tab shows its root screen, then the routes of its path on top).
 *
 * Deep links received while no session is active (launch from a notification, signed out) are kept in
 * [RouterState.pendingDeepLink] and applied by [activate] when a session starts (`AppModel` does it).
 *
 * Android additions to the Swift API (the iOS `NavigationStack` edits its path binding itself): [push], [pop],
 * [setPath] and [path].
 */
class Router {
    private val mutableState = MutableStateFlow(RouterState())

    val state: StateFlow<RouterState> = mutableState.asStateFlow()

    var selectedTab: AppTab
        get() = mutableState.value.selectedTab
        set(value) = mutableState.update { it.copy(selectedTab = value) }

    var groupsPath: List<AppRoute>
        get() = mutableState.value.groupsPath
        set(value) = mutableState.update { it.copy(groupsPath = value.toList()) }

    var myTasksPath: List<AppRoute>
        get() = mutableState.value.myTasksPath
        set(value) = mutableState.update { it.copy(myTasksPath = value.toList()) }

    val pendingDeepLink: DeepLink? get() = mutableState.value.pendingDeepLink

    val isActive: Boolean get() = mutableState.value.isActive

    // region Deep links

    /** Shows [link] now if a session is active, otherwise keeps it for [activate]. */
    fun open(link: DeepLink) {
        mutableState.update { state -> if (state.isActive) applying(link, state) else state.copy(pendingDeepLink = link) }
    }

    /** Opens an `equipe://` URL. Returns false (and does nothing) when the URL is not one of ours. */
    fun open(url: String): Boolean {
        val link = DeepLink.parse(url) ?: return false
        open(link)
        return true
    }

    /** Opens the destination of a tapped notification (see [DeepLink.fromNotification]). */
    fun openNotification(userInfo: Map<String, Any?>) {
        open(DeepLink.fromNotification(userInfo))
    }

    // endregion

    // region Navigation helpers

    /** « Groupes » tab, showing the group. */
    fun showGroup(groupId: UUID) {
        mutableState.update { it.copy(selectedTab = AppTab.GROUPS, groupsPath = listOf(AppRoute.Group(groupId))) }
    }

    /** « Groupes » tab, showing the task above its group (so « retour » goes to the group). */
    fun showTask(groupId: UUID, taskId: UUID) {
        mutableState.update {
            it.copy(
                selectedTab = AppTab.GROUPS,
                groupsPath = listOf(AppRoute.Group(groupId), AppRoute.Task(groupId, taskId)),
            )
        }
    }

    /** « Groupes » tab, showing the members above their group. */
    fun showMembers(groupId: UUID) {
        mutableState.update {
            it.copy(selectedTab = AppTab.GROUPS, groupsPath = listOf(AppRoute.Group(groupId), AppRoute.Members(groupId)))
        }
    }

    /** « Mes tâches » tab, at its root. */
    fun showMyTasks() {
        mutableState.update { it.copy(selectedTab = AppTab.MY_TASKS, myTasksPath = emptyList()) }
    }

    /** Pops the given tab (the selected one by default) to its root. */
    fun popToRoot(tab: AppTab? = null) {
        mutableState.update { state -> state.withPath(tab ?: state.selectedTab, emptyList()) }
    }

    /** Removes every destination of a group that no longer exists or was left (and what is above it). */
    fun removeRoutesForGroup(groupId: UUID) {
        mutableState.update { state ->
            state.copy(
                groupsPath = state.groupsPath.truncatedAt { it.groupId == groupId },
                myTasksPath = state.myTasksPath.truncatedAt { it.groupId == groupId },
            )
        }
    }

    /** Removes a deleted task's screen (and what is above it). */
    fun removeRoutesForTask(taskId: UUID) {
        val isTask: (AppRoute) -> Boolean = { it is AppRoute.Task && it.taskId == taskId }
        mutableState.update { state ->
            state.copy(groupsPath = state.groupsPath.truncatedAt(isTask), myTasksPath = state.myTasksPath.truncatedAt(isTask))
        }
    }

    /** Back stack of [tab]. */
    fun path(tab: AppTab): List<AppRoute> = mutableState.value.path(tab)

    /** Replaces the back stack of [tab] (ignored for « Réglages »). */
    fun setPath(tab: AppTab, path: List<AppRoute>) {
        mutableState.update { it.withPath(tab, path.toList()) }
    }

    /** Pushes [route] on the back stack of [tab] (the selected one by default; ignored for « Réglages »). */
    fun push(route: AppRoute, tab: AppTab = selectedTab) {
        mutableState.update { it.withPath(tab, it.path(tab) + route) }
    }

    /**
     * Pops the top destination of [tab] (the selected one by default). Returns false when the tab was already at its
     * root (the system back then leaves the app or goes back to the first tab).
     */
    fun pop(tab: AppTab = selectedTab): Boolean {
        var popped = false
        mutableState.update { state ->
            val path = state.path(tab)
            popped = path.isNotEmpty()
            if (popped) state.withPath(tab, path.dropLast(1)) else state
        }
        return popped
    }

    // endregion

    // region Session lifecycle (called by AppModel)

    /** A session started: applies the pending deep link, if any. */
    fun activate() {
        mutableState.update { state ->
            val link = state.pendingDeepLink
            val active = state.copy(isActive = true, pendingDeepLink = null)
            if (link != null) applying(link, active) else active
        }
    }

    /**
     * The session ended: back to the first tab with empty paths. A deep link received afterwards waits for the next
     * session.
     */
    fun deactivate() {
        mutableState.update {
            it.copy(isActive = false, selectedTab = AppTab.GROUPS, groupsPath = emptyList(), myTasksPath = emptyList())
        }
    }

    /** First tab, empty paths (the pending deep link is kept). */
    fun reset() {
        mutableState.update { it.copy(selectedTab = AppTab.GROUPS, groupsPath = emptyList(), myTasksPath = emptyList()) }
    }

    // endregion

    private fun applying(link: DeepLink, state: RouterState): RouterState = when (link) {
        is DeepLink.Task -> state.copy(
            selectedTab = AppTab.GROUPS,
            groupsPath = listOf(AppRoute.Group(link.groupId), AppRoute.Task(link.groupId, link.taskId)),
        )
        is DeepLink.Group -> state.copy(selectedTab = AppTab.GROUPS, groupsPath = listOf(AppRoute.Group(link.groupId)))
        DeepLink.MyTasks -> state.copy(selectedTab = AppTab.MY_TASKS, myTasksPath = emptyList())
    }

    private fun RouterState.withPath(tab: AppTab, path: List<AppRoute>): RouterState = when (tab) {
        AppTab.GROUPS -> copy(groupsPath = path)
        AppTab.MY_TASKS -> copy(myTasksPath = path)
        AppTab.SETTINGS -> this
    }

    private fun List<AppRoute>.truncatedAt(predicate: (AppRoute) -> Boolean): List<AppRoute> {
        val index = indexOfFirst(predicate)
        return if (index >= 0) subList(0, index).toList() else this
    }
}
