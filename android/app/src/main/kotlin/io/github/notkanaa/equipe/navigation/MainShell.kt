package io.github.notkanaa.equipe.navigation

import androidx.activity.compose.BackHandler
import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.AnimatedContentTransitionScope
import androidx.compose.animation.ContentTransform
import androidx.compose.animation.EnterExitState
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.slideInHorizontally
import androidx.compose.animation.slideOutHorizontally
import androidx.compose.animation.togetherWith
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.consumeWindowInsets
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Checklist
import androidx.compose.material.icons.filled.Groups
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material.icons.outlined.Checklist
import androidx.compose.material.icons.outlined.Groups
import androidx.compose.material.icons.outlined.Settings
import androidx.compose.material3.Badge
import androidx.compose.material3.BadgedBox
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.NavigationBar
import androidx.compose.material3.NavigationBarItem
import androidx.compose.material3.NavigationBarItemDefaults
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.SaveableStateHolder
import androidx.compose.runtime.saveable.rememberSaveableStateHolder
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.luminance
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.input.pointer.PointerEventPass
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.Density
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import io.github.notkanaa.equipe.core.viewmodel.AppModel
import io.github.notkanaa.equipe.core.viewmodel.AppRoute
import io.github.notkanaa.equipe.core.viewmodel.AppTab
import io.github.notkanaa.equipe.core.viewmodel.Router
import io.github.notkanaa.equipe.core.viewmodel.RouterState
import io.github.notkanaa.equipe.core.viewmodel.SessionModel
import io.github.notkanaa.equipe.ui.groups.GroupDetailScreen
import io.github.notkanaa.equipe.ui.groups.GroupsListScreen
import io.github.notkanaa.equipe.ui.members.MembersScreen
import io.github.notkanaa.equipe.ui.mytasks.MyTasksScreen
import io.github.notkanaa.equipe.ui.settings.SettingsScreen
import io.github.notkanaa.equipe.ui.tasks.TaskDetailScreen
import io.github.notkanaa.equipe.ui.theme.extendedColors
import kotlinx.coroutines.CoroutineScope

/** Test tags of the tab bar items (same identifiers as iOS `AccessibilityID.Tabs`). */
object TabTestTags {
    const val GROUPS: String = "tab.groups"
    const val MY_TASKS: String = "tab.myTasks"
    const val SETTINGS: String = "tab.settings"

    fun of(tab: AppTab): String = when (tab) {
        AppTab.GROUPS -> GROUPS
        AppTab.MY_TASKS -> MY_TASKS
        AppTab.SETTINGS -> SETTINGS
    }
}

/**
 * The signed-in app (iOS `MainTabView`): « Groupes », « Mes tâches » (badge = new assignments) and « Réglages », each
 * tab showing its root screen and the [AppRoute]s of its [Router] back stack on top (pushed screens slide in, system
 * back pops). Only the top screen of the selected tab is composed: a screen that leaves (tab switch, push) is disposed,
 * its `rememberSaveable` state is kept until it is popped (its view model is created again when it comes back).
 *
 * Hosting contract of the screens: they fill the area above the navigation bar, whose insets are already consumed
 * (a Scaffold's default content insets only add the status bar); they draw their own top app bar under the status bar
 * (edge-to-edge) and call `router.pop()` from their back arrow. System back is handled here.
 */
@Composable
fun MainShell(appModel: AppModel, session: SessionModel, actionScope: CoroutineScope) {
    val router = appModel.router
    val routerState by router.state.collectAsStateWithLifecycle()
    val myTasksState by session.myTasks.state.collectAsStateWithLifecycle()
    val stateHolder = rememberSaveableStateHolder()

    // Keeps the badge current even before « Mes tâches » is opened (realtime signals, own changes, return to the
    // foreground); `load()` is a no-op when the list is current.
    LaunchedEffect(session) { session.myTasks.autoRefresh() }
    // Asks for the notification permission once, after sign-in (no-op once answered).
    LaunchedEffect(session) { session.requestNotificationAuthorizationIfNeeded() }

    val selectedTab = routerState.selectedTab
    // Registered before the screens: their own handlers (sheets, dialogs) take precedence.
    BackHandler(enabled = routerState.currentPath.isNotEmpty() || selectedTab != AppTab.GROUPS) {
        if (!router.pop()) router.selectedTab = AppTab.GROUPS
    }
    ForgetRemovedEntries(routerState, stateHolder)

    Scaffold(
        containerColor = MaterialTheme.colorScheme.background,
        contentWindowInsets = WindowInsets(0, 0, 0, 0),
        bottomBar = {
            EquipeNavigationBar(
                selectedTab = selectedTab,
                newTaskCount = myTasksState.newCount,
                onSelect = { tab ->
                    // Tapping the selected tab goes back to its root (like iOS).
                    if (tab == selectedTab) router.popToRoot(tab) else router.selectedTab = tab
                },
            )
        },
    ) { innerPadding ->
        Box(
            modifier = Modifier
                .fillMaxSize()
                .padding(innerPadding)
                .consumeWindowInsets(innerPadding),
        ) {
            AnimatedContent(
                targetState = selectedTab,
                transitionSpec = { fadeIn(tween(TAB_FADE_IN_MILLIS)) togetherWith fadeOut(tween(TAB_FADE_OUT_MILLIS)) },
                label = "tab",
            ) { tab ->
                when (tab) {
                    AppTab.GROUPS -> TabStack(
                        tab = tab,
                        path = routerState.groupsPath,
                        stateHolder = stateHolder,
                        root = { GroupsListScreen(session, router) },
                        destination = { route -> RouteScreen(route, session, router) },
                    )
                    AppTab.MY_TASKS -> TabStack(
                        tab = tab,
                        path = routerState.myTasksPath,
                        stateHolder = stateHolder,
                        root = { MyTasksScreen(session, router) },
                        destination = { route -> RouteScreen(route, session, router) },
                    )
                    AppTab.SETTINGS -> stateHolder.SaveableStateProvider(StackEntry(tab, 0, null).key) {
                        SettingsScreen(session, actionScope)
                    }
                }
            }
        }
    }
}

/** The pinned screen of a pushed destination. */
@Composable
private fun RouteScreen(route: AppRoute, session: SessionModel, router: Router) {
    when (route) {
        is AppRoute.Group -> GroupDetailScreen(route.groupId, session, router)
        is AppRoute.Task -> TaskDetailScreen(route.groupId, route.taskId, session, router)
        is AppRoute.Members -> MembersScreen(route.groupId, session, router)
    }
}

/** The top of a tab's back stack: its root (depth 0) or the route at [depth]. */
private data class StackEntry(val tab: AppTab, val depth: Int, val route: AppRoute?) {
    /** Saveable-state key, unique in the shell. */
    val key: String
        get() = "${tab.rawValue}/$depth/" + when (route) {
            null -> "root"
            is AppRoute.Group -> "group/${route.groupId}"
            is AppRoute.Task -> "task/${route.groupId}/${route.taskId}"
            is AppRoute.Members -> "members/${route.groupId}"
        }
}

/** Shows the top of a tab's back stack; a push slides the new screen in from the end, a pop slides it out. */
@Composable
private fun TabStack(
    tab: AppTab,
    path: List<AppRoute>,
    stateHolder: SaveableStateHolder,
    root: @Composable () -> Unit,
    destination: @Composable (AppRoute) -> Unit,
) {
    AnimatedContent(
        targetState = StackEntry(tab, path.size, path.lastOrNull()),
        contentKey = { it.key },
        transitionSpec = { stackTransition() },
        label = "stack-${tab.rawValue}",
    ) { entry ->
        // The screen sliding away ignores touches (a second tap during a push would push again, like iOS prevents).
        val isLeaving = transition.targetState == EnterExitState.PostExit
        Box(modifier = Modifier.fillMaxSize().then(if (isLeaving) Modifier.ignoreTouches() else Modifier)) {
            stateHolder.SaveableStateProvider(entry.key) {
                val route = entry.route
                if (route == null) root() else destination(route)
            }
        }
    }
}

/** Consumes every pointer event before the content sees it. */
private fun Modifier.ignoreTouches(): Modifier = pointerInput(Unit) {
    awaitPointerEventScope {
        while (true) {
            awaitPointerEvent(PointerEventPass.Initial).changes.forEach { it.consume() }
        }
    }
}

private fun AnimatedContentTransitionScope<StackEntry>.stackTransition(): ContentTransform {
    val forward = targetState.depth > initialState.depth
    val backward = targetState.depth < initialState.depth
    val transform = when {
        forward ->
            (slideInHorizontally(tween(STACK_MILLIS)) { it } + fadeIn(tween(STACK_MILLIS))) togetherWith
                (slideOutHorizontally(tween(STACK_MILLIS)) { -it / 4 } + fadeOut(tween(STACK_MILLIS)))
        backward ->
            (slideInHorizontally(tween(STACK_MILLIS)) { -it / 4 } + fadeIn(tween(STACK_MILLIS))) togetherWith
                (slideOutHorizontally(tween(STACK_MILLIS)) { it } + fadeOut(tween(STACK_MILLIS)))
        // Same depth (a deep link replaced the destination): cross-fade.
        else -> fadeIn(tween(TAB_FADE_IN_MILLIS)) togetherWith fadeOut(tween(TAB_FADE_OUT_MILLIS))
    }
    // The deeper screen is drawn on top, both when it slides in and when it slides out.
    transform.targetContentZIndex = targetState.depth.toFloat()
    return transform
}

/** Drops the saved state of the screens that left every back stack (popped, or removed with their group or task). */
@Composable
private fun ForgetRemovedEntries(routerState: RouterState, stateHolder: SaveableStateHolder) {
    val known = remember { HashSet<String>() }
    val live = remember(routerState.groupsPath, routerState.myTasksPath) {
        buildSet {
            for (tab in AppTab.entries) {
                val path = routerState.path(tab)
                add(StackEntry(tab, 0, null).key)
                path.forEachIndexed { index, route -> add(StackEntry(tab, index + 1, route).key) }
            }
        }
    }
    LaunchedEffect(live) {
        for (key in known) {
            if (key !in live) stateHolder.removeState(key)
        }
        known.clear()
        known.addAll(live)
    }
}

@Composable
private fun EquipeNavigationBar(selectedTab: AppTab, newTaskCount: Int, onSelect: (AppTab) -> Unit) {
    val scheme = MaterialTheme.colorScheme
    // The selected icon sits on the indicator (primaryContainer): the primary blue in light mode (4.2:1), the light
    // on-container tint in dark mode, where the dark primary would give only 2.7:1 (3:1 needed).
    val selectedIconColor = if (scheme.background.luminance() < 0.5f) scheme.onPrimaryContainer else scheme.primary
    NavigationBar(containerColor = MaterialTheme.extendedColors.card) {
        for (tab in AppTab.entries) {
            val selected = tab == selectedTab
            val showsBadge = tab == AppTab.MY_TASKS && newTaskCount > 0
            NavigationBarItem(
                selected = selected,
                onClick = { onSelect(tab) },
                icon = {
                    val icon = tabIcon(tab, selected)
                    if (showsBadge) {
                        BadgedBox(
                            badge = {
                                Badge {
                                    // At the largest font scales the badge would hide the icon: its digits grow
                                    // at most 1.3 times (the count is also read with the tab by TalkBack).
                                    LimitedFontScale(max = BADGE_MAX_FONT_SCALE) {
                                        Text(if (newTaskCount > 99) "99+" else newTaskCount.toString())
                                    }
                                }
                            },
                        ) {
                            Icon(icon, contentDescription = null)
                        }
                    } else {
                        Icon(icon, contentDescription = null)
                    }
                },
                label = { Text(tab.title) },
                colors = NavigationBarItemDefaults.colors(
                    selectedIconColor = selectedIconColor,
                    selectedTextColor = MaterialTheme.colorScheme.primary,
                    indicatorColor = MaterialTheme.colorScheme.primaryContainer,
                    unselectedIconColor = MaterialTheme.colorScheme.onSurfaceVariant,
                    unselectedTextColor = MaterialTheme.colorScheme.onSurfaceVariant,
                ),
                // The item clears the semantics of its icon (the label names it): the badge is announced with the
                // tab, « Mes tâches, 2 nouvelles tâches ».
                modifier = Modifier
                    .testTag(TabTestTags.of(tab))
                    .semantics {
                        if (showsBadge) contentDescription = "${tab.title}, ${newTasksDescription(newTaskCount)}"
                    },
            )
        }
    }
}

/** `AppTab.iconName` (material-icons-extended): filled when selected, outlined otherwise. */
private fun tabIcon(tab: AppTab, selected: Boolean): ImageVector = when (tab) {
    AppTab.GROUPS -> if (selected) Icons.Filled.Groups else Icons.Outlined.Groups
    AppTab.MY_TASKS -> if (selected) Icons.Filled.Checklist else Icons.Outlined.Checklist
    AppTab.SETTINGS -> if (selected) Icons.Filled.Settings else Icons.Outlined.Settings
}

/** Content whose text grows at most [max] times with the system font scale (never shrinks it). */
@Composable
private fun LimitedFontScale(max: Float, content: @Composable () -> Unit) {
    val density = LocalDensity.current
    if (density.fontScale <= max) {
        content()
    } else {
        CompositionLocalProvider(LocalDensity provides Density(density.density, max), content = content)
    }
}

/** « 1 nouvelle tâche », « 3 nouvelles tâches » (TalkBack, badge). */
private fun newTasksDescription(count: Int): String =
    if (count <= 1) "$count nouvelle tâche" else "$count nouvelles tâches"

private const val BADGE_MAX_FONT_SCALE = 1.3f
private const val STACK_MILLIS = 300
private const val TAB_FADE_IN_MILLIS = 180
private const val TAB_FADE_OUT_MILLIS = 90
