package io.github.notkanaa.equipe.ui.tasks

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.WindowInsetsSides
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.isImeVisible
import androidx.compose.foundation.layout.only
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.navigationBars
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.selection.toggleable
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowRight
import androidx.compose.material.icons.filled.Error
import androidx.compose.material.icons.outlined.CalendarToday
import androidx.compose.material.icons.outlined.Event
import androidx.compose.material.icons.outlined.Group
import androidx.compose.material.icons.outlined.Lock
import androidx.compose.material.icons.outlined.Schedule
import androidx.compose.material.icons.outlined.Warning
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FilledTonalButton
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.OutlinedTextFieldDefaults
import androidx.compose.material3.SegmentedButton
import androidx.compose.material3.SegmentedButtonDefaults
import androidx.compose.material3.SheetState
import androidx.compose.material3.SheetValue
import androidx.compose.material3.SingleChoiceSegmentedButtonRow
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.runtime.snapshotFlow
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.TextRange
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardCapitalization
import androidx.compose.ui.text.input.TextFieldValue
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import io.github.notkanaa.equipe.core.Membership
import io.github.notkanaa.equipe.core.TaskItem
import io.github.notkanaa.equipe.core.TaskPriority
import io.github.notkanaa.equipe.core.logic.FrenchDateFormatter
import io.github.notkanaa.equipe.core.viewmodel.DateText
import io.github.notkanaa.equipe.core.viewmodel.LoadState
import io.github.notkanaa.equipe.core.viewmodel.SessionModel
import io.github.notkanaa.equipe.core.viewmodel.TaskEditorMode
import io.github.notkanaa.equipe.core.viewmodel.TaskEditorState
import io.github.notkanaa.equipe.core.viewmodel.TaskEditorViewModel
import io.github.notkanaa.equipe.core.viewmodel.label
import io.github.notkanaa.equipe.core.viewmodel.pickerOrder
import io.github.notkanaa.equipe.ui.components.tasks.TaskCardDivider
import io.github.notkanaa.equipe.ui.components.tasks.TaskErrorAlert
import io.github.notkanaa.equipe.ui.components.tasks.TaskInlineMessage
import io.github.notkanaa.equipe.ui.components.tasks.TaskSectionCard
import io.github.notkanaa.equipe.ui.components.tasks.TaskSectionFooter
import io.github.notkanaa.equipe.ui.components.tasks.TaskSectionHeader
import io.github.notkanaa.equipe.ui.components.tasks.TaskTestTags
import io.github.notkanaa.equipe.ui.components.tasks.groupedBackgroundColor
import io.github.notkanaa.equipe.ui.components.tasks.groupedCardColor
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch
import java.time.Instant

/**
 * « Nouvelle tâche » / « Modifier la tâche » sheet (port of the iOS `TaskEditorView` and `TaskEditorAssigneePicker`), a
 * Material 3 modal bottom sheet: title, multi-line description, priority (Haute / Moyenne / Basse), optional due date
 * (French date and 24 h time pickers) and assignees (members of the group with a search field, 20 at most). Fields are
 * validated inline; « Créer » / « Enregistrer » saves, then [onSaved] is called and the sheet closes itself (through
 * [onDismiss]). « Annuler », the back button, a swipe or a tap outside close it, after confirming when something was
 * changed (never while saving).
 *
 * @param mode `TaskEditorMode.Create(groupId)` or `TaskEditorMode.Edit(task)` (e.g. `TaskDetailState.editorMode`).
 * @param onDismiss called once the sheet is closed (saved or cancelled): remove it from the composition.
 * @param members the group's members when already loaded (the assignee picker then needs no request). Android addition.
 * @param onSaved called with the created or updated task, right before the sheet closes. Android addition.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun TaskEditorSheet(
    mode: TaskEditorMode,
    session: SessionModel,
    onDismiss: () -> Unit,
    members: List<Membership>? = null,
    onSaved: (TaskItem) -> Unit = {},
) {
    val scope = rememberCoroutineScope()
    val model = remember(mode) { TaskEditorViewModel(session, mode, scope, members) }
    val state by model.state.collectAsStateWithLifecycle()
    val latestOnDismiss by rememberUpdatedState(onDismiss)
    val latestOnSaved by rememberUpdatedState(onSaved)

    // The sheet refuses to hide (swipe, tap outside) while something would be lost; `gate.isForced` lets it go after the
    // user confirmed « Abandonner » or saw that the task is gone.
    val gate = remember { DismissGate() }
    val canDismiss = rememberUpdatedState(state.savedTask != null || (!state.hasChanges && !state.isSaving))
    val confirmValueChange = remember {
        { value: SheetValue -> value != SheetValue.Hidden || gate.isForced || canDismiss.value }
    }
    val sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true, confirmValueChange = confirmValueChange)

    val close: () -> Unit = {
        gate.isForced = true
        scope.launch { sheetState.hide() }.invokeOnCompletion { latestOnDismiss() }
    }

    LaunchedEffect(model) { model.load() }
    LaunchedEffect(state.savedTask) {
        val saved = state.savedTask ?: return@LaunchedEffect
        latestOnSaved(saved)
        close()
    }

    ModalBottomSheet(
        onDismissRequest = { latestOnDismiss() },
        sheetState = sheetState,
        containerColor = groupedBackgroundColor(),
        // The navigation bar here; the keyboard with `imePadding()` on the content (the header stays in place).
        contentWindowInsets = { WindowInsets.navigationBars.only(WindowInsetsSides.Bottom) },
    ) {
        TaskEditorContent(
            model = model,
            state = state,
            session = session,
            sheetState = sheetState,
            onClose = close,
        )
    }
}

/** Lets the sheet hide although the form has changes (after a confirmed discard, or when the task is gone). */
private class DismissGate {
    var isForced: Boolean = false
}

private enum class EditorPage { FORM, ASSIGNEES }

/** The sheet's content (composed in the sheet's window: its focus, keyboard and back handling are the sheet's). */
@OptIn(ExperimentalMaterial3Api::class, ExperimentalLayoutApi::class)
@Composable
private fun TaskEditorContent(
    model: TaskEditorViewModel,
    state: TaskEditorState,
    session: SessionModel,
    sheetState: SheetState,
    onClose: () -> Unit,
) {
    val scope = rememberCoroutineScope()
    val focusManager = LocalFocusManager.current
    val titleFocus = remember { FocusRequester() }
    val detailsFocus = remember { FocusRequester() }
    var page by remember { mutableStateOf(EditorPage.FORM) }
    var isConfirmingDiscard by remember { mutableStateOf(false) }
    var titleFocusRequests by remember { mutableIntStateOf(0) }

    val cancel: () -> Unit = {
        if (!model.state.value.isSaving) {
            if (model.state.value.hasChanges) isConfirmingDiscard = true else onClose()
        }
    }
    val save: () -> Unit = {
        focusManager.clearFocus()
        // In the session's scope: the save completes even if the sheet goes away meanwhile.
        session.scope.launch {
            val saved = model.save()
            if (saved == null && model.state.value.titleError != null) titleFocusRequests++
        }
    }

    BackHandler {
        if (page == EditorPage.ASSIGNEES) page = EditorPage.FORM else cancel()
    }

    // A new task starts in the title field once the sheet is open.
    LaunchedEffect(Unit) {
        if (model.mode is TaskEditorMode.Create) {
            snapshotFlow { sheetState.currentValue }.first { it == SheetValue.Expanded }
            runCatching { titleFocus.requestFocus() }
        }
    }
    LaunchedEffect(titleFocusRequests) {
        if (titleFocusRequests > 0) {
            page = EditorPage.FORM
            runCatching { titleFocus.requestFocus() }
        }
    }

    Column(
        modifier = Modifier
            .fillMaxWidth()
            .fillMaxHeight(SHEET_HEIGHT_FRACTION)
            .imePadding(),
    ) {
        when (page) {
            EditorPage.FORM -> {
                EditorTopBar(state = state, onCancel = cancel, onSave = save)
                HorizontalDivider(color = MaterialTheme.colorScheme.outlineVariant)
                EditorForm(
                    model = model,
                    state = state,
                    session = session,
                    titleFocus = titleFocus,
                    detailsFocus = detailsFocus,
                    onOpenAssignees = {
                        focusManager.clearFocus()
                        page = EditorPage.ASSIGNEES
                    },
                    onRetryMembers = { scope.launch { model.reload() } },
                    modifier = Modifier.weight(1f),
                )
            }
            EditorPage.ASSIGNEES -> TaskEditorAssigneePicker(
                state = state,
                onToggle = model::toggleAssignee,
                onClearAll = { for (userId in model.state.value.assigneeIds) model.toggleAssignee(userId) },
                onBack = {
                    focusManager.clearFocus()
                    page = EditorPage.FORM
                },
                modifier = Modifier.weight(1f),
            )
        }
        // Return adds a line to the description: « OK » closes the keyboard, which otherwise hides the other fields.
        if (WindowInsets.isImeVisible) {
            HorizontalDivider(color = MaterialTheme.colorScheme.outlineVariant)
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(horizontal = 8.dp),
                horizontalArrangement = Arrangement.End,
            ) {
                TextButton(onClick = { focusManager.clearFocus() }) {
                    Text("OK", fontWeight = FontWeight.SemiBold)
                }
            }
        }
    }

    if (isConfirmingDiscard) {
        AlertDialog(
            onDismissRequest = { isConfirmingDiscard = false },
            title = { Text("Abandonner les modifications ?") },
            text = { Text("Les changements apportés à cette tâche seront perdus.") },
            confirmButton = {
                TextButton(
                    onClick = {
                        isConfirmingDiscard = false
                        onClose()
                    },
                ) {
                    Text("Abandonner", color = MaterialTheme.colorScheme.error)
                }
            },
            dismissButton = {
                TextButton(onClick = { isConfirmingDiscard = false }) { Text("Continuer la saisie") }
            },
        )
    }

    state.error?.let { error ->
        TaskErrorAlert(message = error.message) {
            model.dismissError()
            if (model.state.value.isGone) {
                // The task was deleted meanwhile: the screens showing it reload, notice it and leave.
                session.feed.bump(model.groupId)
                session.feed.bumpMyTasks()
                onClose()
            }
        }
    }
}

/** « Annuler », the title and « Créer » / « Enregistrer » (a spinner while saving). */
@Composable
private fun EditorTopBar(state: TaskEditorState, onCancel: () -> Unit, onSave: () -> Unit) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .heightIn(min = 56.dp)
            .padding(horizontal = 8.dp, vertical = 4.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        TextButton(
            onClick = onCancel,
            enabled = !state.isSaving,
            modifier = Modifier.testTag(TaskTestTags.CANCEL_BUTTON),
        ) {
            Text("Annuler")
        }
        Text(
            text = state.navigationTitle,
            modifier = Modifier
                .weight(1f)
                .padding(horizontal = 4.dp)
                .semantics { heading() },
            style = MaterialTheme.typography.titleMedium,
            fontWeight = FontWeight.SemiBold,
            textAlign = TextAlign.Center,
            maxLines = 2,
            overflow = TextOverflow.Ellipsis,
        )
        if (state.isSaving) {
            CircularProgressIndicator(
                modifier = Modifier
                    .padding(horizontal = 24.dp)
                    .size(24.dp)
                    .semantics { contentDescription = "Enregistrement en cours" },
                strokeWidth = 2.dp,
            )
        } else {
            Button(
                onClick = onSave,
                enabled = state.canSave,
                modifier = Modifier.testTag(TaskTestTags.SAVE_BUTTON),
            ) {
                Text(state.saveButtonTitle, fontWeight = FontWeight.SemiBold)
            }
        }
    }
}

/** The form: title, description, priority, due date, assignees. */
@OptIn(ExperimentalMaterial3Api::class, ExperimentalLayoutApi::class)
@Composable
private fun EditorForm(
    model: TaskEditorViewModel,
    state: TaskEditorState,
    session: SessionModel,
    titleFocus: FocusRequester,
    detailsFocus: FocusRequester,
    onOpenAssignees: () -> Unit,
    onRetryMembers: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val isReadOnly = !state.canEdit
    val fieldsEnabled = !state.isSaving && !isReadOnly
    val cardColor = groupedCardColor()
    val fieldColors = OutlinedTextFieldDefaults.colors(
        focusedContainerColor = cardColor,
        unfocusedContainerColor = cardColor,
        disabledContainerColor = cardColor,
        errorContainerColor = cardColor,
    )
    // Local text states: the field must see its own edits synchronously (the view model's state arrives a frame later).
    var titleValue by remember(model) { mutableStateOf(TextFieldValue(model.title, TextRange(model.title.length))) }
    var detailsValue by remember(model) { mutableStateOf(TextFieldValue(model.details, TextRange(model.details.length))) }
    var isPickingDate by remember { mutableStateOf(false) }
    var isPickingTime by remember { mutableStateOf(false) }
    val calendar = session.platform.calendar
    val formatter = remember(calendar) { FrenchDateFormatter.of(calendar) }

    Column(
        modifier = modifier
            .fillMaxWidth()
            .verticalScroll(rememberScrollState())
            .padding(start = 16.dp, end = 16.dp, bottom = 24.dp),
    ) {
        if (isReadOnly) {
            Spacer(Modifier.height(12.dp))
            TaskSectionCard {
                TaskInlineMessage(
                    icon = Icons.Outlined.Lock,
                    text = "Vous ne pouvez pas modifier cette tâche.",
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.padding(16.dp),
                )
            }
        }

        TaskSectionHeader("Titre")
        OutlinedTextField(
            value = titleValue,
            onValueChange = {
                titleValue = it
                model.title = it.text
            },
            modifier = Modifier
                .fillMaxWidth()
                .focusRequester(titleFocus)
                .testTag(TaskTestTags.TITLE_FIELD),
            enabled = fieldsEnabled,
            placeholder = { Text("Titre de la tâche") },
            isError = state.titleError != null,
            supportingText = state.titleError?.let { message -> { FieldError(message) } },
            singleLine = true,
            keyboardOptions = KeyboardOptions(capitalization = KeyboardCapitalization.Sentences, imeAction = ImeAction.Next),
            keyboardActions = KeyboardActions(onNext = { runCatching { detailsFocus.requestFocus() } }),
            shape = MaterialTheme.shapes.medium,
            colors = fieldColors,
        )

        TaskSectionHeader("Description")
        OutlinedTextField(
            value = detailsValue,
            onValueChange = {
                detailsValue = it
                model.details = it.text
            },
            modifier = Modifier
                .fillMaxWidth()
                .focusRequester(detailsFocus)
                .testTag(TaskTestTags.DETAILS_FIELD),
            enabled = fieldsEnabled,
            placeholder = { Text("Ajoutez des précisions (facultatif)") },
            isError = state.detailsError != null,
            supportingText = state.detailsError?.let { message -> { FieldError(message) } },
            minLines = 4,
            maxLines = 10,
            keyboardOptions = KeyboardOptions(capitalization = KeyboardCapitalization.Sentences),
            shape = MaterialTheme.shapes.medium,
            colors = fieldColors,
        )

        TaskSectionHeader("Priorité")
        val priorities = TaskPriority.pickerOrder
        SingleChoiceSegmentedButtonRow(
            modifier = Modifier
                .fillMaxWidth()
                .testTag(TaskTestTags.PRIORITY_PICKER),
        ) {
            priorities.forEachIndexed { index, priority ->
                SegmentedButton(
                    selected = state.priority == priority,
                    onClick = { model.priority = priority },
                    shape = SegmentedButtonDefaults.itemShape(index = index, count = priorities.size),
                    modifier = Modifier.testTag(TaskTestTags.priorityOption(priority)),
                    enabled = fieldsEnabled,
                    colors = SegmentedButtonDefaults.colors(inactiveContainerColor = cardColor),
                ) {
                    Text(priority.label, maxLines = 1, overflow = TextOverflow.Ellipsis)
                }
            }
        }

        TaskSectionHeader("Échéance")
        TaskSectionCard {
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .toggleable(
                        value = state.hasDueDate,
                        enabled = fieldsEnabled,
                        role = Role.Switch,
                        onValueChange = { model.hasDueDate = it },
                    )
                    .testTag(TaskTestTags.DUE_DATE_TOGGLE)
                    .heightIn(min = 56.dp)
                    .padding(horizontal = 16.dp, vertical = 8.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Icon(Icons.Outlined.Event, contentDescription = null, tint = MaterialTheme.colorScheme.onSurfaceVariant)
                Spacer(Modifier.width(12.dp))
                Text("Date d’échéance", modifier = Modifier.weight(1f), style = MaterialTheme.typography.bodyLarge)
                Switch(checked = state.hasDueDate, onCheckedChange = null, enabled = fieldsEnabled)
            }
            if (state.hasDueDate) {
                TaskCardDivider()
                val dateText = FrenchDateFormatter.capitalizingFirstLetter(formatter.day(state.dueDate, includeYear = true))
                val timeText = formatter.time(state.dueDate)
                FlowRow(
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(horizontal = 16.dp, vertical = 12.dp),
                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                    verticalArrangement = Arrangement.spacedBy(8.dp),
                ) {
                    FilledTonalButton(
                        onClick = { isPickingDate = true },
                        enabled = fieldsEnabled,
                        modifier = Modifier
                            .testTag(TaskTestTags.DUE_DATE_PICKER)
                            .semantics { contentDescription = "Date d’échéance : $dateText" },
                    ) {
                        Icon(Icons.Outlined.CalendarToday, contentDescription = null, modifier = Modifier.size(18.dp))
                        Spacer(Modifier.width(8.dp))
                        Text(dateText)
                    }
                    FilledTonalButton(
                        onClick = { isPickingTime = true },
                        enabled = fieldsEnabled,
                        modifier = Modifier
                            .testTag(TaskTestTags.DUE_TIME_PICKER)
                            .semantics { contentDescription = "Heure d’échéance : $timeText" },
                    ) {
                        Icon(Icons.Outlined.Schedule, contentDescription = null, modifier = Modifier.size(18.dp))
                        Spacer(Modifier.width(8.dp))
                        Text(timeText)
                    }
                }
            }
        }
        val dueDateError = state.dueDateError
        when {
            dueDateError != null -> FieldError(dueDateError, Modifier.padding(start = 16.dp, end = 16.dp, top = 6.dp))
            state.hasDueDate -> TaskSectionFooter(dueDateSummary(state.dueDate, session))
        }

        TaskSectionHeader("Assignation")
        TaskSectionCard {
            when (val loadState = state.loadState) {
                LoadState.Loaded -> Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .clickable(enabled = fieldsEnabled, role = Role.Button, onClick = onOpenAssignees)
                        .testTag(TaskTestTags.ASSIGNEES_BUTTON)
                        .heightIn(min = 56.dp)
                        .padding(horizontal = 16.dp, vertical = 8.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Icon(Icons.Outlined.Group, contentDescription = null, tint = MaterialTheme.colorScheme.onSurfaceVariant)
                    Spacer(Modifier.width(12.dp))
                    Text("Assigner à", style = MaterialTheme.typography.bodyLarge)
                    Spacer(Modifier.width(12.dp))
                    Text(
                        text = state.assigneesSummary,
                        modifier = Modifier.weight(1f),
                        style = MaterialTheme.typography.bodyMedium,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        textAlign = TextAlign.End,
                        maxLines = 2,
                        overflow = TextOverflow.Ellipsis,
                    )
                    Icon(
                        Icons.AutoMirrored.Filled.KeyboardArrowRight,
                        contentDescription = null,
                        tint = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
                is LoadState.Failed -> Column(Modifier.padding(start = 16.dp, end = 16.dp, top = 12.dp)) {
                    TaskInlineMessage(
                        icon = Icons.Outlined.Warning,
                        text = loadState.message,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                    TextButton(onClick = onRetryMembers) { Text("Réessayer") }
                }
                else -> Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .heightIn(min = 56.dp)
                        .padding(horizontal = 16.dp, vertical = 8.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    CircularProgressIndicator(modifier = Modifier.size(20.dp), strokeWidth = 2.dp)
                    Spacer(Modifier.width(12.dp))
                    Text(
                        "Chargement des membres…",
                        style = MaterialTheme.typography.bodyMedium,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
            }
        }
        state.assigneesError?.let { FieldError(it, Modifier.padding(start = 16.dp, end = 16.dp, top = 6.dp)) }
    }

    if (isPickingDate) {
        TaskDatePickerDialog(
            initialDate = calendar.localDate(state.dueDate),
            onDismiss = { isPickingDate = false },
            onConfirm = { date ->
                isPickingDate = false
                val current = model.dueDate
                model.dueDate = calendar.instant(date, current.atZone(calendar.zone).toLocalTime())
            },
        )
    }
    if (isPickingTime) {
        TaskTimePickerDialog(
            initialTime = state.dueDate.atZone(calendar.zone).toLocalTime(),
            onDismiss = { isPickingTime = false },
            onConfirm = { time ->
                isPickingTime = false
                model.dueDate = calendar.instant(calendar.localDate(model.dueDate), time)
            },
        )
    }
}

/** Inline validation message under a field (red, with an icon). */
@Composable
internal fun FieldError(message: String, modifier: Modifier = Modifier) {
    TaskInlineMessage(
        icon = Icons.Filled.Error,
        text = message,
        color = MaterialTheme.colorScheme.error,
        modifier = modifier,
    )
}

/** « Demain à 18:00 » under the due date. */
private fun dueDateSummary(dueDate: Instant, session: SessionModel): String =
    DateText.relative(dueDate, session.platform.now(), session.platform.calendar)

/** Height of the sheet (like the iOS page sheet: the screen above stays visible). */
private const val SHEET_HEIGHT_FRACTION = 0.94f
