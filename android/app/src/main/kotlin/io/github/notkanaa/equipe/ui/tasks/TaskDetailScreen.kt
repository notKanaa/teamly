package io.github.notkanaa.equipe.ui.tasks

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.selection.selectable
import androidx.compose.foundation.selection.selectableGroup
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.Error
import androidx.compose.material.icons.filled.Verified
import androidx.compose.material.icons.outlined.Delete
import androidx.compose.material.icons.outlined.Edit
import androidx.compose.material.icons.outlined.PersonOff
import androidx.compose.material.icons.outlined.Warning
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.material3.pulltorefresh.PullToRefreshBox
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.input.nestedscroll.nestedScroll
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import io.github.notkanaa.equipe.core.NameOrder
import io.github.notkanaa.equipe.core.TaskItem
import io.github.notkanaa.equipe.core.TaskStatus
import io.github.notkanaa.equipe.core.uuidString
import io.github.notkanaa.equipe.core.viewmodel.LoadState
import io.github.notkanaa.equipe.core.viewmodel.MemberDirectory
import io.github.notkanaa.equipe.core.viewmodel.Router
import io.github.notkanaa.equipe.core.viewmodel.SessionModel
import io.github.notkanaa.equipe.core.viewmodel.TaskDetailState
import io.github.notkanaa.equipe.core.viewmodel.TaskDetailViewModel
import io.github.notkanaa.equipe.core.viewmodel.TaskEditorMode
import io.github.notkanaa.equipe.core.viewmodel.label
import io.github.notkanaa.equipe.ui.components.people.PersonAvatar
import io.github.notkanaa.equipe.ui.components.tasks.DueLabelContent
import io.github.notkanaa.equipe.ui.components.tasks.PriorityCapsule
import io.github.notkanaa.equipe.ui.components.tasks.StatusBadge
import io.github.notkanaa.equipe.ui.components.tasks.TaskCardDivider
import io.github.notkanaa.equipe.ui.components.tasks.TaskErrorAlert
import io.github.notkanaa.equipe.ui.components.tasks.TaskInlineMessage
import io.github.notkanaa.equipe.ui.components.tasks.TaskLoadingView
import io.github.notkanaa.equipe.ui.components.tasks.TaskMessageView
import io.github.notkanaa.equipe.ui.components.tasks.TaskSectionCard
import io.github.notkanaa.equipe.ui.components.tasks.TaskSectionFooter
import io.github.notkanaa.equipe.ui.components.tasks.TaskSectionHeader
import io.github.notkanaa.equipe.ui.components.tasks.TaskTestTags
import io.github.notkanaa.equipe.ui.components.tasks.completedTint
import io.github.notkanaa.equipe.ui.components.tasks.dueAccessibilityText
import io.github.notkanaa.equipe.ui.components.tasks.groupedBackgroundColor
import io.github.notkanaa.equipe.ui.components.tasks.overdueTint
import io.github.notkanaa.equipe.ui.components.tasks.statusIcon
import io.github.notkanaa.equipe.ui.components.tasks.statusTint
import io.github.notkanaa.equipe.ui.components.tasks.taskPalette
import kotlinx.coroutines.launch
import java.util.UUID

/**
 * Task screen (port of the iOS `TaskDetailView`), shown for `AppRoute.Task`: title, description, status (changeable by
 * admins, the creator and the assignees), priority, due date, assignees (« (vous) »), creator and completion lines;
 * « Modifier » ([TaskEditorSheet]) and « Supprimer la tâche » for admins and the creator. Leaves the back stack by itself
 * when the task disappears (deleted here or elsewhere, or no longer visible): `router.removeRoutesForTask(taskId)`.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun TaskDetailScreen(groupId: UUID, taskId: UUID, session: SessionModel, router: Router) {
    val scope = rememberCoroutineScope()
    val model = remember(session, groupId, taskId) { TaskDetailViewModel(session, groupId, taskId, scope) }
    val state by model.state.collectAsStateWithLifecycle()
    var editorMode by remember { mutableStateOf<TaskEditorMode?>(null) }
    var isConfirmingDelete by remember { mutableStateOf(false) }
    var pendingStatus by remember { mutableStateOf<TaskStatus?>(null) }
    var isRefreshing by remember { mutableStateOf(false) }

    LaunchedEffect(model) { model.autoRefresh() }
    LaunchedEffect(state.isGone) {
        if (state.isGone) {
            editorMode = null
            isConfirmingDelete = false
            router.removeRoutesForTask(taskId)
        }
    }

    // Mutations run in the session's scope: they complete even if the screen goes away.
    val changeStatus: (TaskStatus) -> Unit = { status ->
        pendingStatus = status
        session.scope.launch {
            try {
                model.setStatus(status)
            } finally {
                pendingStatus = null
            }
        }
    }

    val background = groupedBackgroundColor()
    val scrollBehavior = TopAppBarDefaults.pinnedScrollBehavior()
    Scaffold(
        modifier = Modifier.nestedScroll(scrollBehavior.nestedScrollConnection),
        containerColor = background,
        topBar = {
            TopAppBar(
                title = { Text("Tâche") },
                navigationIcon = {
                    IconButton(onClick = { router.pop() }) {
                        Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = "Retour")
                    }
                },
                actions = {
                    if (state.loadState.isLoading && state.task != null) {
                        CircularProgressIndicator(modifier = Modifier.padding(12.dp).size(24.dp), strokeWidth = 2.dp)
                    } else if (state.canEdit && !state.isGone) {
                        IconButton(
                            onClick = { editorMode = state.editorMode },
                            enabled = !state.isWorking,
                            modifier = Modifier.testTag(TaskTestTags.EDIT_BUTTON),
                        ) {
                            Icon(Icons.Outlined.Edit, contentDescription = "Modifier")
                        }
                    }
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
            val task = state.task
            val loadState = state.loadState
            when {
                task != null -> TaskDetailContent(
                    state = state,
                    task = task,
                    pendingStatus = pendingStatus,
                    onChangeStatus = changeStatus,
                    onRetry = { scope.launch { model.reload() } },
                    onDelete = { isConfirmingDelete = true },
                )
                state.isGone -> TaskMessageView(
                    icon = Icons.Outlined.Warning,
                    title = "Tâche indisponible",
                    message = TaskDetailViewModel.GONE_MESSAGE,
                )
                loadState is LoadState.Failed -> TaskMessageView(
                    icon = Icons.Outlined.Warning,
                    title = "Impossible d’afficher la tâche",
                    message = loadState.message,
                ) {
                    Button(onClick = { scope.launch { model.reload() } }) { Text("Réessayer") }
                }
                else -> TaskLoadingView()
            }
        }
    }

    if (isConfirmingDelete && state.canDelete) {
        AlertDialog(
            onDismissRequest = { isConfirmingDelete = false },
            title = { Text("Supprimer la tâche ?") },
            text = { Text(state.deleteConfirmationMessage) },
            confirmButton = {
                TextButton(
                    onClick = {
                        isConfirmingDelete = false
                        session.scope.launch { model.delete() }
                    },
                    modifier = Modifier.testTag(TaskTestTags.DELETE_CONFIRM_BUTTON),
                ) {
                    Text("Supprimer", color = MaterialTheme.colorScheme.error)
                }
            },
            dismissButton = {
                TextButton(onClick = { isConfirmingDelete = false }) { Text("Annuler") }
            },
        )
    }

    editorMode?.let { mode ->
        TaskEditorSheet(
            mode = mode,
            session = session,
            onDismiss = { editorMode = null },
            members = state.members.ifEmpty { null },
            onSaved = model::apply,
        )
    }

    state.error?.let { error ->
        TaskErrorAlert(message = error.message, onDismiss = model::dismissError)
    }
}

@Composable
private fun TaskDetailContent(
    state: TaskDetailState,
    task: TaskItem,
    pendingStatus: TaskStatus?,
    onChangeStatus: (TaskStatus) -> Unit,
    onRetry: () -> Unit,
    onDelete: () -> Unit,
) {
    Column(
        modifier = Modifier
            .fillMaxSize()
            .verticalScroll(rememberScrollState())
            .padding(start = 16.dp, end = 16.dp, top = 8.dp, bottom = 32.dp),
    ) {
        state.loadState.failureMessage?.let { message ->
            TaskSectionCard(Modifier.padding(bottom = 12.dp)) {
                TaskInlineMessage(
                    icon = Icons.Outlined.Warning,
                    text = message,
                    color = taskPalette().orange,
                    modifier = Modifier.padding(start = 16.dp, end = 16.dp, top = 12.dp),
                )
                TextButton(onClick = onRetry, modifier = Modifier.padding(start = 4.dp)) { Text("Réessayer") }
            }
        }

        HeaderCard(state, task)

        TaskSectionHeader("Description")
        TaskSectionCard {
            val details = state.details
            if (!details.isNullOrEmpty()) {
                SelectionContainer {
                    Text(
                        text = details,
                        modifier = Modifier.padding(16.dp),
                        style = MaterialTheme.typography.bodyLarge,
                    )
                }
            } else {
                Text(
                    text = "Aucune description.",
                    modifier = Modifier.padding(16.dp),
                    style = MaterialTheme.typography.bodyLarge,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
        }

        TaskSectionHeader("Statut")
        if (state.canChangeStatus) {
            TaskSectionCard {
                TaskStatusSelector(
                    selection = pendingStatus ?: task.status,
                    options = state.statusOptions,
                    isBusy = state.isWorking,
                    onSelect = onChangeStatus,
                    modifier = Modifier.padding(12.dp),
                )
            }
        } else {
            TaskSectionCard {
                LabeledRow(label = "Statut", description = "Statut : ${task.status.label}") {
                    StatusBadge(task.status)
                }
            }
            if (state.loadState == LoadState.Loaded) {
                TaskSectionFooter(
                    "Seuls les admins, le créateur de la tâche et les personnes assignées peuvent changer le statut.",
                )
            }
        }

        TaskSectionHeader("Informations")
        TaskSectionCard {
            LabeledRow(label = "Priorité", description = "Priorité : ${task.priority.label}") {
                PriorityCapsule(task.priority, showsLabel = true)
            }
            TaskCardDivider()
            LabeledRow(
                label = "Échéance",
                description = dueAccessibilityText(state.dueText, state.isOverdue),
            ) {
                DueLabelContent(
                    text = state.dueText,
                    isOverdue = state.isOverdue,
                    style = MaterialTheme.typography.bodyMedium,
                )
            }
        }
        state.createdText?.let { TaskSectionFooter(it) }

        TaskSectionHeader("Personnes assignées")
        TaskSectionCard {
            val people = detailAssignees(state)
            if (people.isEmpty()) {
                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .heightIn(min = 56.dp)
                        .padding(horizontal = 16.dp, vertical = 8.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Icon(Icons.Outlined.PersonOff, contentDescription = null, tint = MaterialTheme.colorScheme.onSurfaceVariant)
                    Spacer(Modifier.width(12.dp))
                    Text(
                        text = MemberDirectory.UNASSIGNED_TEXT,
                        style = MaterialTheme.typography.bodyLarge,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
            } else {
                people.forEachIndexed { index, person ->
                    if (index > 0) TaskCardDivider(startIndent = 60.dp)
                    Row(
                        modifier = Modifier
                            .fillMaxWidth()
                            .heightIn(min = 56.dp)
                            .semantics(mergeDescendants = true) { }
                            .padding(horizontal = 16.dp, vertical = 8.dp),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        // The same initials and colour as on the group screen and in « Membres ».
                        PersonAvatar(userId = person.id, name = person.name, size = 32.dp)
                        Spacer(Modifier.width(12.dp))
                        Text(
                            text = assigneeDisplayName(person, state.currentUserId),
                            style = MaterialTheme.typography.bodyLarge,
                        )
                    }
                }
            }
        }

        if (state.canDelete) {
            Spacer(Modifier.height(24.dp))
            TaskSectionCard {
                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .clickable(enabled = !state.isWorking, role = Role.Button, onClick = onDelete)
                        .testTag(TaskTestTags.DELETE_BUTTON)
                        .heightIn(min = 56.dp)
                        .padding(horizontal = 16.dp, vertical = 8.dp)
                        .alpha(if (state.isWorking) 0.5f else 1f),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Icon(Icons.Outlined.Delete, contentDescription = null, tint = MaterialTheme.colorScheme.error)
                    Spacer(Modifier.width(12.dp))
                    Text(
                        text = "Supprimer la tâche",
                        style = MaterialTheme.typography.bodyLarge,
                        color = MaterialTheme.colorScheme.error,
                    )
                }
            }
        }
    }
}

/** Title (heading), « En retard » and « Terminée … ». */
@Composable
private fun HeaderCard(state: TaskDetailState, task: TaskItem) {
    TaskSectionCard {
        Column(
            modifier = Modifier.padding(16.dp),
            verticalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            Text(
                text = task.title,
                modifier = Modifier
                    .testTag(TaskTestTags.DETAIL_TITLE)
                    .semantics { heading() },
                style = MaterialTheme.typography.headlineSmall,
                fontWeight = FontWeight.Bold,
            )
            if (state.isOverdue) {
                val red = overdueTint()
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Icon(Icons.Filled.Error, contentDescription = null, tint = red, modifier = Modifier.size(18.dp))
                    Spacer(Modifier.width(6.dp))
                    Text("En retard", style = MaterialTheme.typography.titleSmall, fontWeight = FontWeight.SemiBold, color = red)
                }
            }
            state.completedText?.let { completedText ->
                val green = completedTint()
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Icon(Icons.Filled.Verified, contentDescription = null, tint = green, modifier = Modifier.size(18.dp))
                    Spacer(Modifier.width(6.dp))
                    Text(completedText, style = MaterialTheme.typography.bodyMedium, color = green)
                }
            }
        }
    }
}

/** « Label ……… value » row of a card, read by TalkBack as [description]. */
@Composable
private fun LabeledRow(label: String, description: String, value: @Composable () -> Unit) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .heightIn(min = 52.dp)
            .clearAndSetSemantics { contentDescription = description }
            .padding(horizontal = 16.dp, vertical = 8.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(
            text = label,
            modifier = Modifier.weight(1f),
            style = MaterialTheme.typography.bodyLarge,
        )
        Spacer(Modifier.width(12.dp))
        value()
    }
}

/**
 * Status selector of the task screen (iOS `TasksStatusPicker`): one tile per status, the current one filled with its
 * colour. Selecting another status calls [onSelect]. Test tags `tasks.status.<rawValue>`.
 */
@Composable
internal fun TaskStatusSelector(
    selection: TaskStatus,
    options: List<TaskStatus>,
    isBusy: Boolean,
    onSelect: (TaskStatus) -> Unit,
    modifier: Modifier = Modifier,
) {
    val onTint = taskPalette().onTint
    Row(
        modifier = modifier
            .fillMaxWidth()
            .selectableGroup()
            .alpha(if (isBusy) 0.6f else 1f),
        horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        for (option in options) {
            val isSelected = option == selection
            val tint = statusTint(option)
            val content = if (isSelected) onTint else tint
            Column(
                modifier = Modifier
                    .weight(1f)
                    .clip(RoundedCornerShape(12.dp))
                    .background(if (isSelected) tint else tint.copy(alpha = 0.12f))
                    .selectable(
                        selected = isSelected,
                        enabled = !isBusy,
                        role = Role.RadioButton,
                        onClick = { if (!isSelected) onSelect(option) },
                    )
                    .testTag(TaskTestTags.statusOption(option))
                    .heightIn(min = 64.dp)
                    .padding(horizontal = 4.dp, vertical = 10.dp),
                horizontalAlignment = Alignment.CenterHorizontally,
                verticalArrangement = Arrangement.Center,
            ) {
                Icon(statusIcon(option), contentDescription = null, tint = content, modifier = Modifier.size(24.dp))
                Spacer(Modifier.height(4.dp))
                Text(
                    text = option.label,
                    style = MaterialTheme.typography.labelLarge,
                    fontWeight = FontWeight.SemiBold,
                    color = content,
                    textAlign = TextAlign.Center,
                )
            }
        }
    }
}

/** An assignee of the task screen. */
private data class AssigneePerson(val id: UUID, val name: String)

/**
 * The task's assignees with their real names: the current user first, then by name (« Ancien membre » for someone who
 * left the group; « Vous » for the current user until the members are loaded).
 */
private fun detailAssignees(state: TaskDetailState): List<AssigneePerson> {
    val directory = state.directory
    val me = state.currentUserId
    val people = LinkedHashSet(state.task?.assigneeIds ?: emptyList()).map { userId ->
        var name = directory.name(userId)
        if (userId == me && name == MemberDirectory.FORMER_MEMBER_NAME) name = MemberDirectory.ME_NAME
        AssigneePerson(userId, name)
    }
    return people.sortedWith { lhs, rhs ->
        when {
            lhs.id == me && rhs.id != me -> -1
            rhs.id == me && lhs.id != me -> 1
            else -> when (NameOrder.precedes(lhs.name, rhs.name)) {
                true -> -1
                false -> 1
                null -> lhs.id.uuidString.compareTo(rhs.id.uuidString)
            }
        }
    }
}

/** « Camille Martin (vous) » for the current user, as in « Membres » (« Vous » until the members are loaded). */
private fun assigneeDisplayName(person: AssigneePerson, currentUserId: UUID): String =
    if (person.id == currentUserId && person.name != MemberDirectory.ME_NAME) "${person.name} (vous)" else person.name

