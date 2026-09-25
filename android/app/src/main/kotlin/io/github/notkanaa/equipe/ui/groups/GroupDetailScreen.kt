@file:OptIn(ExperimentalMaterial3Api::class)

package io.github.notkanaa.equipe.ui.groups

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.text.input.TextFieldLineLimits
import androidx.compose.foundation.text.input.rememberTextFieldState
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowRight
import androidx.compose.material.icons.automirrored.filled.Sort
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.Checklist
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material.icons.filled.Edit
import androidx.compose.material.icons.filled.FilterListOff
import androidx.compose.material.icons.filled.Group
import androidx.compose.material.icons.filled.Groups
import androidx.compose.material.icons.filled.Inventory2
import androidx.compose.material.icons.filled.MoreVert
import androidx.compose.material.icons.filled.QrCode
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.Checkbox
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.material3.minimumInteractiveComponentSize
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.key
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.text.TextRange
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardCapitalization
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import io.github.notkanaa.equipe.core.MemberRole
import io.github.notkanaa.equipe.core.Membership
import io.github.notkanaa.equipe.core.NameOrder
import io.github.notkanaa.equipe.core.TaskItem
import io.github.notkanaa.equipe.core.TaskStatus
import io.github.notkanaa.equipe.core.logic.TaskSort
import io.github.notkanaa.equipe.core.uuidString
import io.github.notkanaa.equipe.core.viewmodel.AppRoute
import io.github.notkanaa.equipe.core.viewmodel.CreateGroupViewModel
import io.github.notkanaa.equipe.core.viewmodel.GroupDetailState
import io.github.notkanaa.equipe.core.viewmodel.GroupDetailViewModel
import io.github.notkanaa.equipe.core.viewmodel.Router
import io.github.notkanaa.equipe.core.viewmodel.SessionModel
import io.github.notkanaa.equipe.core.viewmodel.TaskEditorMode
import io.github.notkanaa.equipe.core.viewmodel.TaskFilterChip
import io.github.notkanaa.equipe.core.viewmodel.TaskRow
import io.github.notkanaa.equipe.core.viewmodel.next
import io.github.notkanaa.equipe.ui.components.people.PersonAvatarStack
import io.github.notkanaa.equipe.ui.components.tasks.TaskRowItem
import io.github.notkanaa.equipe.ui.components.tasks.TaskStatusMenu
import io.github.notkanaa.equipe.ui.tasks.TaskEditorSheet
import kotlinx.coroutines.launch
import java.util.UUID

// Port of App/Sources/Features/Groups/GroupDetailView.swift and Components/Groups/GroupsFilterChipBar.swift.

/**
 * Group screen: the members summary (→ « Membres ») and, for admins, « Inviter avec un code »; the filter chips, the
 * task count and the tasks (status toggle when allowed, assignees' initials; a tap opens the task); « + » (new task);
 * the options menu (sort, old done tasks, members, and for admins the invite code, rename and delete). Leaves the
 * group's screens when the group is gone (deleted, left, removed): `router.removeRoutesForGroup(groupId)`.
 */
@Composable
fun GroupDetailScreen(groupId: UUID, session: SessionModel, router: Router) {
    val scope = rememberCoroutineScope()
    val model = remember(session, groupId) { GroupDetailViewModel(session, groupId, scope) }
    val state by model.state.collectAsStateWithLifecycle()
    LaunchedEffect(model) { model.autoRefresh() }
    LaunchedEffect(state.isGone) {
        if (state.isGone) router.removeRoutesForGroup(groupId)
    }

    var editorMode by remember { mutableStateOf<TaskEditorMode?>(null) }
    var actionsTaskId by remember { mutableStateOf<UUID?>(null) }
    var taskPendingDeletion by remember { mutableStateOf<TaskItem?>(null) }
    var isShowingInviteCode by rememberSaveable { mutableStateOf(false) }
    var isRenaming by rememberSaveable { mutableStateOf(false) }
    var isConfirmingDeletion by rememberSaveable { mutableStateOf(false) }
    val surfaces = groupedSurfaces()
    val scrollBehavior = TopAppBarDefaults.exitUntilCollapsedScrollBehavior()
    val showsContent = state.loadState.isLoaded && !state.isGone
    val showMembers = { router.pushOnce(AppRoute.Members(groupId)) }

    Scaffold(
        containerColor = surfaces.screen,
        topBar = {
            GroupsLargeTopBar(
                title = state.title,
                scrollBehavior = scrollBehavior,
                containerColor = surfaces.screen,
                onBack = { router.pop() },
                actions = {
                    if (showsContent) {
                        GroupOptionsMenu(
                            state = state,
                            onSort = { model.sort = it },
                            onToggleOldDone = { model.includeOldDone = !state.includeOldDone },
                            onResetFilter = model::resetFilter,
                            onMembers = showMembers,
                            onInviteCode = { isShowingInviteCode = true },
                            onRename = { isRenaming = true },
                            onDelete = { isConfirmingDeletion = true },
                        )
                        if (state.canCreateTask) {
                            IconButton(
                                onClick = { editorMode = TaskEditorMode.Create(groupId) },
                                modifier = Modifier.testTag(GroupsTags.TASKS_ADD),
                            ) {
                                Icon(Icons.Filled.Add, contentDescription = "Nouvelle tâche")
                            }
                        }
                    }
                },
            )
        },
    ) { padding ->
        RefreshableContent(scrollBehavior, padding, onRefresh = model::reload) {
            when {
                state.isGone -> ScrollablePlaceholder {
                    ContentUnavailable(
                        icon = Icons.Filled.Groups,
                        title = GroupsText.GONE_TITLE,
                        message = GroupDetailViewModel.GONE_MESSAGE,
                    )
                }
                !state.loadState.isLoaded -> ScrollablePlaceholder {
                    LoadStateView(state.loadState, onRetry = { scope.launch { model.reload() } })
                }
                else -> GroupDetailContent(
                    state = state,
                    cardColor = surfaces.card,
                    actionsTaskId = actionsTaskId,
                    onMembers = showMembers,
                    onInviteCode = { isShowingInviteCode = true },
                    onToggleChip = model::toggleFilterChip,
                    onResetFilter = model::resetFilter,
                    onCreateTask = { editorMode = TaskEditorMode.Create(groupId) },
                    // Status changes and deletions complete even if the screen goes away.
                    onSetStatus = { status, task -> session.scope.launch { model.setStatus(status, task) } },
                    onShowActions = { taskId -> actionsTaskId = taskId },
                    onOpenTask = { row -> router.pushOnce(AppRoute.Task(groupId, row.id)) },
                    onEditTask = { task -> editorMode = TaskEditorMode.Edit(task) },
                    onDeleteTask = { task -> taskPendingDeletion = task },
                )
            }
        }
    }

    editorMode?.let { mode ->
        // The loaded members spare the assignee picker a request; the saved task shows at once.
        TaskEditorSheet(
            mode = mode,
            session = session,
            onDismiss = { editorMode = null },
            members = state.members.ifEmpty { null },
            onSaved = model::apply,
        )
    }
    taskPendingDeletion?.let { task ->
        ConfirmationDialog(
            title = "Supprimer cette tâche ?",
            message = "« ${task.title} » sera supprimée pour tous les membres du groupe.",
            confirmLabel = "Supprimer la tâche",
            confirmTag = GroupsTags.DELETE_TASK_CONFIRM,
            onConfirm = { session.scope.launch { model.delete(task) } },
            onDismiss = { taskPendingDeletion = null },
        )
    }
    if (isShowingInviteCode) {
        InviteCodeSheet(groupId = groupId, session = session, onDismiss = { isShowingInviteCode = false })
    }
    if (isRenaming) {
        RenameGroupDialog(
            initialName = state.group?.name ?: state.title,
            onRename = { name -> session.scope.launch { model.rename(name) } },
            onDismiss = { isRenaming = false },
        )
    }
    if (isConfirmingDeletion) {
        ConfirmationDialog(
            title = "Supprimer le groupe ?",
            message = state.deleteGroupConfirmationMessage,
            confirmLabel = "Supprimer le groupe",
            confirmTag = GroupsTags.DELETE_CONFIRM,
            onConfirm = { session.scope.launch { model.deleteGroup() } },
            onDismiss = { isConfirmingDeletion = false },
        )
    }
    ErrorAlert(state.error, model::dismissError)
}

@Composable
private fun GroupDetailContent(
    state: GroupDetailState,
    cardColor: Color,
    actionsTaskId: UUID?,
    onMembers: () -> Unit,
    onInviteCode: () -> Unit,
    onToggleChip: (TaskFilterChip.Kind) -> Unit,
    onResetFilter: () -> Unit,
    onCreateTask: () -> Unit,
    onSetStatus: (TaskStatus, TaskItem) -> Unit,
    onShowActions: (UUID?) -> Unit,
    onOpenTask: (TaskRow) -> Unit,
    onEditTask: (TaskItem) -> Unit,
    onDeleteTask: (TaskItem) -> Unit,
) {
    val rows = state.rows
    LazyColumn(
        modifier = Modifier
            .fillMaxSize()
            .testTag(GroupsTags.TASKS_LIST),
        contentPadding = PaddingValues(top = 8.dp, bottom = 24.dp),
    ) {
        item(key = "members") {
            MembersCard(state = state, cardColor = cardColor, onMembers = onMembers, onInviteCode = onInviteCode)
        }
        if (!state.isEmpty) {
            item(key = "filters") {
                FilterChipBar(chips = state.filterChips, onToggle = onToggleChip, modifier = Modifier.padding(top = 12.dp))
            }
        }
        if (state.tasks.isNotEmpty()) {
            item(key = "count") { SectionHeader(tasksHeader(state, shown = rows.size)) }
        }
        if (rows.isEmpty()) {
            item(key = "empty") {
                EmptyTasks(state = state, onCreateTask = onCreateTask, onResetFilter = onResetFilter)
            }
        } else {
            itemsIndexed(rows, key = { _, row -> row.id }) { index, row ->
                Column(
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(horizontal = CardMargin)
                        .clip(groupedItemShape(index, rows.size))
                        .background(cardColor),
                ) {
                    if (index > 0) HorizontalDivider(Modifier.padding(start = 56.dp))
                    TaskCell(
                        row = row,
                        state = state,
                        showsActions = actionsTaskId == row.id,
                        onSetStatus = onSetStatus,
                        onShowActions = onShowActions,
                        onOpenTask = onOpenTask,
                        onEditTask = onEditTask,
                        onDeleteTask = onDeleteTask,
                    )
                }
            }
        }
    }
}

/**
 * A task of the group (the row of « Mes tâches » with the assignees' initials instead of the group name; tag
 * `tasks.row.<title>`): the status button cycles the status when allowed (spinner while it changes), a tap opens the
 * task, a long press opens the iOS context menu: the statuses, « Modifier », « Supprimer » (each when allowed).
 */
@Composable
private fun TaskCell(
    row: TaskRow,
    state: GroupDetailState,
    showsActions: Boolean,
    onSetStatus: (TaskStatus, TaskItem) -> Unit,
    onShowActions: (UUID?) -> Unit,
    onOpenTask: (TaskRow) -> Unit,
    onEditTask: (TaskItem) -> Unit,
    onDeleteTask: (TaskItem) -> Unit,
) {
    val hasActions = row.canChangeStatus || row.canEdit || row.canDelete
    Box {
        TaskRowItem(
            row = row,
            onToggleStatus = if (row.canChangeStatus) ({ onSetStatus(row.status.next, row.task) }) else null,
            onClick = { onOpenTask(row) },
            showGroupName = false,
            assignees = assignees(row.task, state.members, state.currentUserId),
            isBusy = row.id in state.busyTaskIds,
            onLongClick = if (hasActions) ({ onShowActions(row.id) }) else null,
        )
        TaskStatusMenu(
            expanded = showsActions,
            onDismissRequest = { onShowActions(null) },
            currentStatus = row.status,
            onSelectStatus = if (row.canChangeStatus) ({ status -> onSetStatus(status, row.task) }) else null,
            modifier = Modifier.windowTestTags(),
        ) {
            if (row.canEdit) {
                DropdownMenuItem(
                    text = { Text("Modifier") },
                    onClick = {
                        onShowActions(null)
                        onEditTask(row.task)
                    },
                    leadingIcon = { Icon(Icons.Filled.Edit, contentDescription = null) },
                    modifier = Modifier.testTag(GroupsTags.TASK_EDIT),
                )
            }
            if (row.canDelete) {
                DropdownMenuItem(
                    text = { Text("Supprimer", color = MaterialTheme.colorScheme.error) },
                    onClick = {
                        onShowActions(null)
                        onDeleteTask(row.task)
                    },
                    leadingIcon = {
                        Icon(Icons.Filled.Delete, contentDescription = null, tint = MaterialTheme.colorScheme.error)
                    },
                    modifier = Modifier.testTag(GroupsTags.TASK_DELETE),
                )
            }
        }
    }
}

/** Members (their initials, « 3 membres · vous êtes admin ») and, for admins, « Inviter avec un code ». */
@Composable
private fun MembersCard(
    state: GroupDetailState,
    cardColor: Color,
    onMembers: () -> Unit,
    onInviteCode: () -> Unit,
) {
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = CardMargin)
            .clip(groupedItemShape(0, 1))
            .background(cardColor),
    ) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .testTag(GroupsTags.MEMBERS)
                .clickable(onClickLabel = "voir les membres", role = Role.Button, onClick = onMembers)
                .padding(horizontal = CardMargin, vertical = 12.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            PersonAvatarStack(
                people = state.members.map { it.user.id to it.user.displayName },
                maxVisible = 4,
                size = 30.dp,
            )
            Column(Modifier.weight(1f)) {
                Text("Membres", style = MaterialTheme.typography.titleMedium)
                MembersSummary(count = state.members.size, role = state.myRole)
            }
            Icon(
                imageVector = Icons.AutoMirrored.Filled.KeyboardArrowRight,
                contentDescription = null,
                tint = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
        if (state.canSeeInviteCode) {
            HorizontalDivider(Modifier.padding(start = CardMargin))
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .testTag(GroupsTags.INVITE)
                    .clickable(role = Role.Button, onClick = onInviteCode)
                    .padding(horizontal = CardMargin, vertical = 14.dp),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(12.dp),
            ) {
                Icon(Icons.Filled.QrCode, contentDescription = null, tint = MaterialTheme.colorScheme.primary)
                Text(
                    text = "Inviter avec un code",
                    style = MaterialTheme.typography.bodyLarge,
                    color = MaterialTheme.colorScheme.primary,
                )
            }
        }
    }
}

/**
 * Horizontally scrollable filter chips (« Toutes », « À faire », « En cours », « Terminées », « Assignées à moi »,
 * « En retard »): full screen width, so the chips scroll out at the screen's edges instead of being cut at the cards'
 * margin; no fixed height, so they grow with the font scale. Not lazy: every chip stays reachable by TalkBack (focus
 * scrolls it into view) and by UI tests. The chips and what a tap does come from the view model.
 */
@Composable
private fun FilterChipBar(
    chips: List<TaskFilterChip>,
    onToggle: (TaskFilterChip.Kind) -> Unit,
    modifier: Modifier = Modifier,
) {
    Row(
        modifier = modifier
            .fillMaxWidth()
            .testTag(GroupsTags.TASKS_FILTER)
            .horizontalScroll(rememberScrollState())
            .padding(horizontal = CardMargin),
        horizontalArrangement = Arrangement.spacedBy(8.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        for (chip in chips) {
            key(chipKey(chip.kind)) {
                FilterChipButton(chip = chip, onClick = { onToggle(chip.kind) })
            }
        }
    }
}

/** A capsule: white on the brand blue when selected (4.8:1), the text color on a light tint otherwise. */
@Composable
private fun FilterChipButton(chip: TaskFilterChip, onClick: () -> Unit) {
    val background = if (chip.isSelected) {
        GroupsColors.accentFill
    } else {
        MaterialTheme.colorScheme.onSurface.copy(alpha = if (GroupsColors.isDark) 0.16f else 0.08f)
    }
    val foreground = if (chip.isSelected) GroupsColors.onAccentFill else MaterialTheme.colorScheme.onSurface
    Box(
        modifier = Modifier
            .testTag(GroupsTags.filterChip(chipKey(chip.kind)))
            .minimumInteractiveComponentSize()
            .clip(CircleShape)
            .background(background)
            .clickable(onClickLabel = "filtrer la liste des tâches", role = Role.Button, onClick = onClick)
            .semantics { selected = chip.isSelected }
            .padding(horizontal = 14.dp, vertical = 8.dp),
        contentAlignment = Alignment.Center,
    ) {
        Text(text = chip.label, style = MaterialTheme.typography.labelLarge, color = foreground, maxLines = 1)
    }
}

/** Stable identifier suffix of a chip (`all`, `todo`, `inProgress`, `done`, `notDone`, `assignedToMe`, `overdue`). */
private fun chipKey(kind: TaskFilterChip.Kind): String = when (kind) {
    is TaskFilterChip.Kind.Status -> kind.status.rawValue
    TaskFilterChip.Kind.AssignedToMe -> "assignedToMe"
    TaskFilterChip.Kind.Overdue -> "overdue"
}

/** « Aucune tâche » (+ « Nouvelle tâche ») or « Aucun résultat » (+ « Réinitialiser les filtres »). */
@Composable
private fun EmptyTasks(state: GroupDetailState, onCreateTask: () -> Unit, onResetFilter: () -> Unit) {
    val hasNoTask = state.tasks.isEmpty()
    Box(
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = 32.dp, vertical = 40.dp),
        contentAlignment = Alignment.Center,
    ) {
        ContentUnavailable(
            icon = if (hasNoTask) Icons.Filled.Checklist else Icons.Filled.FilterListOff,
            title = if (hasNoTask) "Aucune tâche" else "Aucun résultat",
            message = state.emptyRowsMessage,
            modifier = Modifier.testTag(GroupsTags.EMPTY_TASKS),
        ) {
            if (hasNoTask) {
                if (state.canCreateTask) {
                    Button(onClick = onCreateTask, modifier = Modifier.testTag(GroupsTags.CREATE_FIRST_TASK)) {
                        Icon(Icons.Filled.Add, contentDescription = null, modifier = Modifier.size(ButtonDefaults.IconSize))
                        Text("Nouvelle tâche", modifier = Modifier.padding(start = ButtonDefaults.IconSpacing))
                    }
                }
            } else if (state.hasActiveFilter) {
                OutlinedButton(onClick = onResetFilter, modifier = Modifier.testTag(GroupsTags.RESET_FILTER)) {
                    Text("Réinitialiser les filtres")
                }
            }
        }
    }
}

/** « Options du groupe »: sort, old done tasks, filters reset, members, and for admins invite code, rename, delete. */
@Composable
private fun GroupOptionsMenu(
    state: GroupDetailState,
    onSort: (TaskSort) -> Unit,
    onToggleOldDone: () -> Unit,
    onResetFilter: () -> Unit,
    onMembers: () -> Unit,
    onInviteCode: () -> Unit,
    onRename: () -> Unit,
    onDelete: () -> Unit,
) {
    var isExpanded by remember { mutableStateOf(false) }
    val select: (() -> Unit) -> Unit = { action ->
        isExpanded = false
        action()
    }
    Box {
        IconButton(
            onClick = { isExpanded = true },
            enabled = !state.isUpdatingGroup,
            modifier = Modifier.testTag(GroupsTags.DETAIL_MENU),
        ) {
            Icon(Icons.Filled.MoreVert, contentDescription = "Options du groupe")
        }
        DropdownMenu(
            expanded = isExpanded,
            onDismissRequest = { isExpanded = false },
            modifier = Modifier.windowTestTags(),
        ) {
            Row(
                modifier = Modifier
                    .padding(horizontal = 12.dp, vertical = 8.dp)
                    .testTag(GroupsTags.SORT_PICKER)
                    .semantics(mergeDescendants = true) { heading() },
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                Icon(
                    Icons.AutoMirrored.Filled.Sort,
                    contentDescription = null,
                    tint = MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.size(18.dp),
                )
                Text(
                    text = "Trier par",
                    style = MaterialTheme.typography.labelLarge,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
            for (sort in TaskSort.entries) {
                val isSelected = sort == state.sort
                DropdownMenuItem(
                    text = { Text(sort.label) },
                    onClick = { select { onSort(sort) } },
                    leadingIcon = {
                        if (isSelected) Icon(Icons.Filled.Check, contentDescription = null) else Spacer(Modifier.size(24.dp))
                    },
                    modifier = Modifier
                        .testTag(GroupsTags.sortOption(sort.rawValue))
                        .semantics { selected = isSelected },
                )
            }
            HorizontalDivider()
            DropdownMenuItem(
                text = { Text("Terminées depuis plus de 30 jours") },
                onClick = { select(onToggleOldDone) },
                leadingIcon = { Icon(Icons.Filled.Inventory2, contentDescription = null) },
                trailingIcon = { Checkbox(checked = state.includeOldDone, onCheckedChange = null) },
                modifier = Modifier
                    .testTag(GroupsTags.INCLUDE_OLD_DONE)
                    .semantics { stateDescription = if (state.includeOldDone) "Activé" else "Désactivé" },
            )
            if (state.hasActiveFilter) {
                DropdownMenuItem(
                    text = { Text("Réinitialiser les filtres") },
                    onClick = { select(onResetFilter) },
                    leadingIcon = { Icon(Icons.Filled.FilterListOff, contentDescription = null) },
                    modifier = Modifier.testTag(GroupsTags.MENU_RESET_FILTER),
                )
            }
            HorizontalDivider()
            DropdownMenuItem(
                text = { Text("Membres") },
                onClick = { select(onMembers) },
                leadingIcon = { Icon(Icons.Filled.Group, contentDescription = null) },
                modifier = Modifier.testTag(GroupsTags.MENU_MEMBERS),
            )
            if (state.canSeeInviteCode) {
                DropdownMenuItem(
                    text = { Text("Code d’invitation") },
                    onClick = { select(onInviteCode) },
                    leadingIcon = { Icon(Icons.Filled.QrCode, contentDescription = null) },
                    modifier = Modifier.testTag(GroupsTags.MENU_INVITE),
                )
            }
            if (state.canRename) {
                DropdownMenuItem(
                    text = { Text("Renommer le groupe") },
                    onClick = { select(onRename) },
                    leadingIcon = { Icon(Icons.Filled.Edit, contentDescription = null) },
                    modifier = Modifier.testTag(GroupsTags.RENAME),
                )
            }
            if (state.canDeleteGroup) {
                HorizontalDivider()
                DropdownMenuItem(
                    text = { Text("Supprimer le groupe", color = MaterialTheme.colorScheme.error) },
                    onClick = { select(onDelete) },
                    leadingIcon = {
                        Icon(Icons.Filled.Delete, contentDescription = null, tint = MaterialTheme.colorScheme.error)
                    },
                    modifier = Modifier.testTag(GroupsTags.DELETE),
                )
            }
        }
    }
}

/** « Renommer le groupe »: the name (with the « n/60 » counter), « Annuler » / « Renommer ». */
@Composable
private fun RenameGroupDialog(initialName: String, onRename: (String) -> Unit, onDismiss: () -> Unit) {
    val nameField = rememberTextFieldState(initialText = initialName, initialSelection = TextRange(initialName.length))
    val confirm = {
        onRename(nameField.text.toString())
        onDismiss()
    }
    AlertDialog(
        modifier = Modifier.windowTestTags(),
        onDismissRequest = onDismiss,
        title = { Text("Renommer le groupe") },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                Text(
                    "Le nouveau nom sera visible par tous les membres " +
                        "(${CreateGroupViewModel.MAX_NAME_LENGTH} caractères au maximum).",
                )
                OutlinedTextField(
                    state = nameField,
                    label = { Text("Nom du groupe") },
                    lineLimits = TextFieldLineLimits.SingleLine,
                    keyboardOptions = KeyboardOptions(
                        capitalization = KeyboardCapitalization.Sentences,
                        imeAction = ImeAction.Done,
                    ),
                    onKeyboardAction = { confirm() },
                    supportingText = {
                        Box(Modifier.fillMaxWidth(), contentAlignment = Alignment.CenterEnd) {
                            NameCounter(nameField.text.toString())
                        }
                    },
                    modifier = Modifier
                        .fillMaxWidth()
                        .testTag(GroupsTags.RENAME_FIELD),
                )
            }
        },
        confirmButton = {
            TextButton(onClick = confirm, modifier = Modifier.testTag(GroupsTags.RENAME_CONFIRM)) {
                Text("Renommer")
            }
        },
        dismissButton = { TextButton(onClick = onDismiss) { Text("Annuler") } },
    )
}

/**
 * « 3 membres · vous êtes admin », wrapped after « · » rather than inside « vous êtes admin » when the line is too
 * narrow (the two parts are laid out as a flow; TalkBack reads them in the merged row).
 */
@OptIn(ExperimentalLayoutApi::class)
@Composable
private fun MembersSummary(count: Int, role: MemberRole?) {
    val style = MaterialTheme.typography.bodyMedium
    val color = MaterialTheme.colorScheme.onSurfaceVariant
    val members = GroupsText.memberCount(count)
    val roleText = when (role) {
        MemberRole.ADMIN -> "vous êtes admin"
        MemberRole.MEMBER -> "vous êtes membre"
        null -> null
    }
    if (roleText == null) {
        Text(text = members, style = style, color = color)
    } else {
        FlowRow {
            Text(text = "$members · ", style = style, color = color)
            Text(text = roleText, style = style, color = color)
        }
    }
}

/** « 5 tâches », or « 2 tâches sur 5 » while a filter hides some. */
private fun tasksHeader(state: GroupDetailState, shown: Int): String {
    val total = state.tasks.size
    if (state.hasActiveFilter && shown != total) return "${GroupsText.taskCount(shown)} sur $total"
    return GroupsText.taskCount(shown)
}

/** Assignees of a task for the initials: the current user first, then by name (« ? » for a former member). */
private fun assignees(task: TaskItem, members: List<Membership>, me: UUID): List<Pair<UUID, String>> {
    val people = task.assigneeIds.map { userId ->
        userId to (members.firstOrNull { it.user.id == userId }?.user?.displayName ?: "?")
    }
    return people.sortedWith { lhs, rhs ->
        when {
            lhs.first == me -> if (rhs.first == me) 0 else -1
            rhs.first == me -> 1
            else -> when (NameOrder.precedes(lhs.second, rhs.second)) {
                true -> -1
                false -> 1
                null -> lhs.first.uuidString.compareTo(rhs.first.uuidString)
            }
        }
    }
}
