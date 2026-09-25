package io.github.notkanaa.equipe.ui.mytasks

import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.CheckCircle
import androidx.compose.material.icons.outlined.FilterList
import androidx.compose.material.icons.outlined.Warning
import androidx.compose.material3.Button
import androidx.compose.material3.Checkbox
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.LargeTopAppBar
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.material3.pulltorefresh.PullToRefreshBox
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.input.nestedscroll.nestedScroll
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.semantics.toggleableState
import androidx.compose.ui.state.ToggleableState
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import io.github.notkanaa.equipe.core.TaskItem
import io.github.notkanaa.equipe.core.TaskStatus
import io.github.notkanaa.equipe.core.logic.DueBucket
import io.github.notkanaa.equipe.core.viewmodel.AppRoute
import io.github.notkanaa.equipe.core.viewmodel.AppTab
import io.github.notkanaa.equipe.core.viewmodel.LoadState
import io.github.notkanaa.equipe.core.viewmodel.MyTasksSection
import io.github.notkanaa.equipe.core.viewmodel.MyTasksState
import io.github.notkanaa.equipe.core.viewmodel.MyTasksViewModel
import io.github.notkanaa.equipe.core.viewmodel.Router
import io.github.notkanaa.equipe.core.viewmodel.SessionModel
import io.github.notkanaa.equipe.core.viewmodel.TaskRow
import io.github.notkanaa.equipe.core.viewmodel.next
import io.github.notkanaa.equipe.ui.components.tasks.GroupedCardItem
import io.github.notkanaa.equipe.ui.components.tasks.TaskErrorAlert
import io.github.notkanaa.equipe.ui.components.tasks.TaskLoadingView
import io.github.notkanaa.equipe.ui.components.tasks.TaskMessageView
import io.github.notkanaa.equipe.ui.components.tasks.TaskRowItem
import io.github.notkanaa.equipe.ui.components.tasks.TaskStatusMenu
import io.github.notkanaa.equipe.ui.components.tasks.dueBucketIcon
import io.github.notkanaa.equipe.ui.components.tasks.groupedBackgroundColor
import io.github.notkanaa.equipe.ui.components.tasks.overdueTint
import kotlinx.coroutines.launch
import java.util.UUID

/** Test tags of « Mes tâches »: the iOS `AccessibilityID.MyTasks` identifiers. */
object MyTasksTestTags {
    const val LIST: String = "myTasks.list"
    const val OPTIONS_MENU: String = "myTasks.options"
    const val SHOW_DONE_TOGGLE: String = "myTasks.showDone"
    const val EMPTY_STATE: String = "myTasks.empty"
    const val RETRY_BUTTON: String = "myTasks.retry"
}

/**
 * « Mes tâches » tab root (port of the iOS `MyTasksView`): the tasks assigned to the user in every group, in due-date
 * sections (En retard, Aujourd’hui, Cette semaine, Plus tard, Sans échéance, and Terminées when shown) with their icon
 * and count, the group name, a « Nouveau » badge and a quick status change (round button; long press: every status).
 * The options menu shows or hides the done tasks; pull to refresh reloads. A tap pushes the task on the « Mes tâches »
 * back stack (like the iOS `NavigationLink`); the « Nouveau » badges are cleared when the screen is left
 * (`markAllSeen`).
 *
 * Uses the session's shared [SessionModel.myTasks] (also behind the tab badge).
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun MyTasksScreen(session: SessionModel, router: Router) {
    val model = session.myTasks
    val state by model.state.collectAsStateWithLifecycle()
    val scope = rememberCoroutineScope()
    var isRefreshing by remember { mutableStateOf(false) }
    var menuTaskId by remember { mutableStateOf<UUID?>(null) }

    LaunchedEffect(model) { model.autoRefresh() }
    DisposableEffect(model) {
        onDispose {
            // Only what was actually shown counts as seen.
            if (model.state.value.loadState == LoadState.Loaded) model.markAllSeen()
        }
    }

    // Mutations run in the session's scope: they complete even if the screen goes away.
    val setStatus: (TaskStatus, TaskItem) -> Unit = { status, task ->
        session.scope.launch { model.setStatus(status, task) }
    }

    val background = groupedBackgroundColor()
    val scrollBehavior = TopAppBarDefaults.exitUntilCollapsedScrollBehavior()
    Scaffold(
        containerColor = background,
        topBar = {
            LargeTopAppBar(
                title = { Text(AppTab.MY_TASKS.title) },
                actions = {
                    MyTasksOptionsMenu(
                        includeDone = state.includeDone,
                        onIncludeDoneChange = { model.includeDone = it },
                    )
                },
                colors = TopAppBarDefaults.topAppBarColors(
                    containerColor = background,
                    scrolledContainerColor = MaterialTheme.colorScheme.surfaceContainer,
                ),
                scrollBehavior = scrollBehavior,
            )
        },
    ) { padding ->
        PullToRefreshBox(
            isRefreshing = isRefreshing,
            onRefresh = {
                scope.launch {
                    isRefreshing = true
                    try {
                        model.reload()
                    } finally {
                        isRefreshing = false
                    }
                }
            },
            modifier = Modifier
                .padding(padding)
                .fillMaxSize(),
        ) {
            MyTasksContent(
                state = state,
                menuTaskId = menuTaskId,
                onMenuTaskIdChange = { menuTaskId = it },
                onSetStatus = setStatus,
                onOpenTask = { row -> router.push(AppRoute.Task(row.task.groupId, row.id), AppTab.MY_TASKS) },
                onRetry = { scope.launch { model.reload() } },
                onShowDone = { model.includeDone = true },
                // The app bar's connection sits inside the pull-to-refresh: at the top, a pull first expands the large
                // title, then refreshes.
                modifier = Modifier
                    .fillMaxSize()
                    .nestedScroll(scrollBehavior.nestedScrollConnection),
            )
        }
    }

    state.error?.let { error ->
        TaskErrorAlert(message = error.message, onDismiss = model::dismissError)
    }
}

/** The sections, or the first-load spinner, the failure with « Réessayer », or the empty state. */
@Composable
private fun MyTasksContent(
    state: MyTasksState,
    menuTaskId: UUID?,
    onMenuTaskIdChange: (UUID?) -> Unit,
    onSetStatus: (TaskStatus, TaskItem) -> Unit,
    onOpenTask: (TaskRow) -> Unit,
    onRetry: () -> Unit,
    onShowDone: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val loadState = state.loadState
    when {
        state.sections.isNotEmpty() -> LazyColumn(
            modifier = modifier.testTag(MyTasksTestTags.LIST),
            contentPadding = PaddingValues(start = 16.dp, end = 16.dp, bottom = 24.dp),
        ) {
            for (section in state.sections) {
                item(key = "section-${section.bucket.name}", contentType = "header") {
                    MyTasksSectionHeader(section)
                }
                itemsIndexed(
                    items = section.rows,
                    key = { _, row -> row.id.toString() },
                    contentType = { _, _ -> "task" },
                ) { index, row ->
                    GroupedCardItem(index = index, count = section.rows.size, dividerStartIndent = 56.dp) {
                        Box {
                            TaskRowItem(
                                row = row,
                                onToggleStatus = { onSetStatus(row.status.next, row.task) },
                                onClick = { onOpenTask(row) },
                                showGroupName = true,
                                isBusy = row.id in state.busyTaskIds,
                                onLongClick = if (row.canChangeStatus) {
                                    { onMenuTaskIdChange(row.id) }
                                } else {
                                    null
                                },
                            )
                            TaskStatusMenu(
                                expanded = menuTaskId == row.id,
                                onDismissRequest = { onMenuTaskIdChange(null) },
                                currentStatus = row.status,
                                onSelectStatus = { status -> onSetStatus(status, row.task) },
                            )
                        }
                    }
                }
            }
        }
        loadState is LoadState.Failed -> TaskMessageView(
            icon = Icons.Outlined.Warning,
            title = "Impossible de charger vos tâches",
            message = loadState.message,
            modifier = modifier,
        ) {
            Button(onClick = onRetry, modifier = Modifier.testTag(MyTasksTestTags.RETRY_BUTTON)) {
                Text("Réessayer")
            }
        }
        state.isEmpty -> TaskMessageView(
            icon = Icons.Outlined.CheckCircle,
            title = MyTasksViewModel.EMPTY_TITLE,
            message = MyTasksViewModel.EMPTY_MESSAGE,
            modifier = modifier.testTag(MyTasksTestTags.EMPTY_STATE),
        ) {
            if (!state.includeDone) {
                TextButton(onClick = onShowDone) { Text("Afficher les terminées") }
            }
        }
        else -> TaskLoadingView(modifier)
    }
}

/** « En retard   2 »: icon, title and number of tasks of a section (red for the overdue tasks). */
@Composable
private fun MyTasksSectionHeader(section: MyTasksSection) {
    val count = section.rows.size
    val color = if (section.bucket == DueBucket.OVERDUE) overdueTint() else MaterialTheme.colorScheme.onSurfaceVariant
    val description = "${section.title}, $count ${if (count > 1) "tâches" else "tâche"}"
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .padding(start = 16.dp, end = 16.dp, top = 20.dp, bottom = 8.dp)
            .semantics(mergeDescendants = true) {
                heading()
                contentDescription = description
            },
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Icon(dueBucketIcon(section.bucket), contentDescription = null, tint = color, modifier = Modifier.size(20.dp))
        Spacer(Modifier.width(8.dp))
        Text(
            text = section.title,
            modifier = Modifier.weight(1f),
            style = MaterialTheme.typography.titleMedium,
            color = color,
        )
        Text(text = count.toString(), style = MaterialTheme.typography.titleMedium, color = color)
    }
}

/** « Options d’affichage » menu: « Afficher les terminées » (checkbox). */
@Composable
private fun MyTasksOptionsMenu(includeDone: Boolean, onIncludeDoneChange: (Boolean) -> Unit) {
    var expanded by remember { mutableStateOf(false) }
    Box {
        IconButton(
            onClick = { expanded = true },
            modifier = Modifier.testTag(MyTasksTestTags.OPTIONS_MENU),
        ) {
            Icon(Icons.Outlined.FilterList, contentDescription = "Options d’affichage")
        }
        DropdownMenu(expanded = expanded, onDismissRequest = { expanded = false }) {
            DropdownMenuItem(
                text = { Text("Afficher les terminées") },
                onClick = {
                    expanded = false
                    onIncludeDoneChange(!includeDone)
                },
                modifier = Modifier
                    .testTag(MyTasksTestTags.SHOW_DONE_TOGGLE)
                    .semantics {
                        toggleableState = ToggleableState(includeDone)
                        stateDescription = if (includeDone) "Activé" else "Désactivé"
                    },
                leadingIcon = { Icon(Icons.Outlined.CheckCircle, contentDescription = null) },
                trailingIcon = { Checkbox(checked = includeDone, onCheckedChange = null) },
            )
        }
    }
}

