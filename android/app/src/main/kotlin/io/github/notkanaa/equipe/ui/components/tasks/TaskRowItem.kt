package io.github.notkanaa.equipe.ui.components.tasks

import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.Groups
import androidx.compose.material.icons.outlined.Person
import androidx.compose.material.icons.outlined.PersonOff
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Icon
import androidx.compose.material3.LocalContentColor
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.CustomAccessibilityAction
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.customActions
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextDecoration
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.tooling.preview.Preview
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import io.github.notkanaa.equipe.core.TaskItem
import io.github.notkanaa.equipe.core.TaskPriority
import io.github.notkanaa.equipe.core.TaskStatus
import io.github.notkanaa.equipe.core.viewmodel.MemberDirectory
import io.github.notkanaa.equipe.core.viewmodel.MyTasksViewModel
import io.github.notkanaa.equipe.core.viewmodel.TaskRow
import io.github.notkanaa.equipe.core.viewmodel.label
import io.github.notkanaa.equipe.core.viewmodel.next
import io.github.notkanaa.equipe.ui.components.people.PersonAvatar
import java.time.Instant
import java.util.UUID

/**
 * One task of a list (group screen, « Mes tâches »; port of the iOS `TasksRowView`): round status button, title (struck
 * through when done), « Nouveau » capsule ([TaskRow.isNew]), group name ([showGroupName]), priority capsule and due
 * date (red when overdue), which go under each other instead of being cut, and the assignees' initials on the trailing
 * side. Put it inside a card; the row has no background of its own. Test tag `tasks.row.<title>`.
 *
 * TalkBack reads the row as one sentence (« Payer le loyer, À faire, priorité haute, en retard, échéance hier à 18:00,
 * assignée à Inès Dubois ») and offers the status change as a custom action; the status button stays a separate
 * element (`tasks.status`).
 *
 * @param onToggleStatus asks for `row.status.next` (e.g. `model.setStatus(row.status.next, row.task)`); the button is
 *   enabled only when `row.canChangeStatus`. null: no status button (the status icon is still drawn, dimmed).
 * @param onClick opens the task.
 * @param showGroupName shows `row.groupName` (« Mes tâches »).
 * @param assignees (user id, display name) of the task's assignees, drawn as `PersonAvatar` initials on the trailing
 *   side (3 at most, then « +N »). Empty: no initials; then, when `row.assigneesText` is set (group screen), an
 *   unassigned task shows the « no one » icon and a task whose names are not given shows `row.assigneesText` as a line.
 * @param isBusy a status change is in progress (spinner instead of the status icon), e.g. `row.id in state.busyTaskIds`.
 *   Android addition.
 * @param onLongClick long press, e.g. to open a [TaskStatusMenu] placed next to the row in a `Box`. Android addition.
 */
@OptIn(ExperimentalFoundationApi::class, ExperimentalLayoutApi::class)
@Composable
fun TaskRowItem(
    row: TaskRow,
    onToggleStatus: (() -> Unit)?,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    showGroupName: Boolean = false,
    assignees: List<Pair<UUID, String>> = emptyList(),
    isBusy: Boolean = false,
    onLongClick: (() -> Unit)? = null,
) {
    // The status change, when this row offers it.
    val toggle: (() -> Unit)? = if (row.canChangeStatus) onToggleStatus else null
    val sentence = remember(row, showGroupName) { taskRowAccessibilityText(row, showGroupName) }
    val actionTitle = nextStatusActionTitle(row.status)
    val isLargeText = LocalDensity.current.fontScale >= LARGE_FONT_SCALE
    val titleLineHeight = MaterialTheme.typography.bodyLarge.lineHeight
    // Puts the first line of the title level with the centre of the 48 dp status button.
    val detailsTopPadding = with(LocalDensity.current) {
        val line = if (titleLineHeight.isSp) titleLineHeight.toDp() else 24.dp
        ((48.dp - line) / 2).coerceAtLeast(0.dp)
    }
    val showsAssigneesText = assignees.isEmpty() && row.assigneesText != null && row.task.assigneeIds.isNotEmpty()
    val showsUnassignedIcon = assignees.isEmpty() && row.assigneesText != null && row.task.assigneeIds.isEmpty()

    Row(
        modifier = modifier
            .fillMaxWidth()
            .testTag(TaskTestTags.row(row.title))
            .combinedClickable(
                onClickLabel = "Afficher la tâche",
                onLongClickLabel = if (onLongClick != null) "Afficher les actions" else null,
                onLongClick = onLongClick,
                onClick = onClick,
            )
            .semantics {
                contentDescription = sentence
                if (toggle != null && !isBusy) {
                    customActions = listOf(
                        CustomAccessibilityAction(actionTitle) {
                            toggle()
                            true
                        },
                    )
                }
            }
            .heightIn(min = 56.dp)
            .padding(start = 4.dp, end = 16.dp, top = 4.dp, bottom = 4.dp),
        verticalAlignment = Alignment.Top,
    ) {
        TaskStatusButton(
            status = row.status,
            onClick = toggle,
            isBusy = isBusy,
        )
        Spacer(Modifier.width(4.dp))
        Row(
            modifier = Modifier
                .weight(1f)
                .padding(top = detailsTopPadding, bottom = 8.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Column(
                modifier = Modifier.weight(1f),
                verticalArrangement = Arrangement.spacedBy(5.dp),
            ) {
                TitleLine(row, isLargeText)
                if (showGroupName) {
                    row.groupName?.let { groupName ->
                        IconTextLine(Icons.Outlined.Groups, groupName, maxLines = if (isLargeText) 3 else 1)
                    }
                }
                FlowRow(
                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                    verticalArrangement = Arrangement.spacedBy(4.dp),
                    itemVerticalAlignment = Alignment.CenterVertically,
                ) {
                    PriorityCapsule(row.priority, showsLabel = true)
                    if (row.dueText != null) {
                        DueLabelContent(row.dueText, row.isOverdue)
                    }
                }
                if (showsAssigneesText) {
                    IconTextLine(Icons.Outlined.Person, row.assigneesText.orEmpty(), maxLines = if (isLargeText) 3 else 1)
                }
                if (isLargeText) {
                    TrailingPeople(assignees, showsUnassignedIcon)
                }
            }
            if (!isLargeText && (assignees.isNotEmpty() || showsUnassignedIcon)) {
                Spacer(Modifier.width(8.dp))
                TrailingPeople(assignees, showsUnassignedIcon)
            }
        }
    }
}

/**
 * Long-press menu of a task row: the three statuses (the current one disabled; hidden when [onSelectStatus] is null),
 * then [extraItems] (e.g. « Modifier », « Supprimer » on the group screen). Place it next to the row in a `Box` so that
 * it opens on the row:
 *
 *     Box {
 *         TaskRowItem(row, …, onLongClick = { menuTaskId = row.id })
 *         TaskStatusMenu(menuTaskId == row.id, { menuTaskId = null }, row.status, onSelectStatus = { … })
 *     }
 */
@Composable
fun TaskStatusMenu(
    expanded: Boolean,
    onDismissRequest: () -> Unit,
    currentStatus: TaskStatus,
    onSelectStatus: ((TaskStatus) -> Unit)?,
    modifier: Modifier = Modifier,
    extraItems: @Composable ColumnScope.() -> Unit = {},
) {
    DropdownMenu(expanded = expanded, onDismissRequest = onDismissRequest, modifier = modifier) {
        if (onSelectStatus != null) {
            for (status in TaskStatus.entries) {
                val enabled = status != currentStatus
                DropdownMenuItem(
                    text = { Text(status.label) },
                    onClick = {
                        onDismissRequest()
                        onSelectStatus(status)
                    },
                    leadingIcon = {
                        Icon(
                            imageVector = statusIcon(status),
                            contentDescription = null,
                            tint = if (enabled) statusTint(status) else LocalContentColor.current,
                        )
                    },
                    enabled = enabled,
                )
            }
        }
        extraItems()
    }
}

@Composable
private fun TitleLine(row: TaskRow, isLargeText: Boolean) {
    Row(verticalAlignment = Alignment.Top) {
        Text(
            text = row.title,
            modifier = Modifier
                .weight(1f)
                .alignByBaseline(),
            style = MaterialTheme.typography.bodyLarge,
            fontWeight = FontWeight.Medium,
            color = if (row.isDone) MaterialTheme.colorScheme.onSurfaceVariant else MaterialTheme.colorScheme.onSurface,
            textDecoration = if (row.isDone) TextDecoration.LineThrough else null,
            maxLines = if (isLargeText) Int.MAX_VALUE else 2,
            overflow = TextOverflow.Ellipsis,
        )
        if (row.isNew) {
            Spacer(Modifier.width(8.dp))
            NewBadge(Modifier.alignByBaseline())
        }
    }
}

@Composable
private fun IconTextLine(icon: ImageVector, text: String, maxLines: Int) {
    val color = MaterialTheme.colorScheme.onSurfaceVariant
    Row(verticalAlignment = Alignment.CenterVertically) {
        Icon(icon, contentDescription = null, tint = color, modifier = Modifier.size(scaledDp(14.sp)))
        Spacer(Modifier.width(4.dp))
        Text(
            text = text,
            style = MaterialTheme.typography.bodySmall,
            color = color,
            maxLines = maxLines,
            overflow = TextOverflow.Ellipsis,
        )
    }
}

/** Assignees' initials (3 at most, then « +N »), or the « no one » icon. Decorative: the row's sentence names them. */
@Composable
private fun TrailingPeople(assignees: List<Pair<UUID, String>>, showsUnassignedIcon: Boolean) {
    if (assignees.isEmpty()) {
        if (showsUnassignedIcon) {
            Icon(
                imageVector = Icons.Outlined.PersonOff,
                contentDescription = null,
                tint = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.size(26.dp),
            )
        }
        return
    }
    Row(
        modifier = Modifier.clearAndSetSemantics { },
        horizontalArrangement = Arrangement.spacedBy(3.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        for ((userId, name) in assignees.take(MAX_VISIBLE_AVATARS)) {
            PersonAvatar(userId = userId, name = name, size = AVATAR_SIZE)
        }
        if (assignees.size > MAX_VISIBLE_AVATARS) {
            Box(
                modifier = Modifier
                    .size(AVATAR_SIZE)
                    .clip(CircleShape)
                    .background(MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.15f)),
                contentAlignment = Alignment.Center,
            ) {
                Text(
                    text = "+${assignees.size - MAX_VISIBLE_AVATARS}",
                    style = MaterialTheme.typography.labelSmall,
                    fontWeight = FontWeight.SemiBold,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    maxLines = 1,
                )
            }
        }
    }
}

/**
 * The row's TalkBack sentence: « Payer le loyer, À faire, priorité haute, en retard, échéance hier à 18:00, assignée à
 * Inès Dubois »; « Faire les courses, nouveau, En cours, priorité moyenne, échéance demain à 18:00, groupe Coloc' rue
 * des Lilas » on « Mes tâches ».
 */
internal fun taskRowAccessibilityText(row: TaskRow, showGroupName: Boolean): String {
    val parts = ArrayList<String>()
    parts.add(row.title)
    if (row.isNew) parts.add(MyTasksViewModel.NEW_BADGE_TEXT.lowercase())
    parts.add(row.status.label)
    parts.add("priorité ${row.priority.label.lowercase()}")
    row.dueText?.let { dueText ->
        val due = "échéance ${dueText.lowercase()}"
        parts.add(if (row.isOverdue) "en retard, $due" else due)
    }
    if (showGroupName) row.groupName?.let { parts.add("groupe $it") }
    row.assigneesText?.let { text ->
        parts.add(if (text == MemberDirectory.UNASSIGNED_TEXT) text.lowercase() else "assignée à $text")
    }
    return parts.joinToString(", ")
}

/** Font scale from which the rows stop truncating and stack their parts. */
private const val LARGE_FONT_SCALE = 1.5f
private const val MAX_VISIBLE_AVATARS = 3
private val AVATAR_SIZE = 28.dp

// region Previews

private fun previewRow(
    title: String,
    status: TaskStatus,
    priority: TaskPriority,
    dueText: String?,
    isOverdue: Boolean = false,
    isNew: Boolean = false,
    groupName: String? = null,
    assigneesText: String? = null,
    assigneeIds: List<UUID> = emptyList(),
): TaskRow {
    val now = Instant.parse("2026-09-24T09:41:00Z")
    return TaskRow(
        task = TaskItem(
            id = UUID.nameUUIDFromBytes(title.toByteArray()),
            groupId = UUID(0, 1),
            title = title,
            status = status,
            priority = priority,
            createdBy = null,
            createdAt = now,
            updatedAt = now,
            assigneeIds = assigneeIds,
        ),
        dueText = dueText,
        isOverdue = isOverdue,
        assigneesText = assigneesText,
        groupName = groupName,
        isNew = isNew,
        canChangeStatus = true,
        canEdit = true,
        canDelete = true,
    )
}

@Preview(name = "Rows", locale = "fr", showBackground = true, backgroundColor = 0xFFF3EDF7)
@Composable
private fun TaskRowItemPreview() {
    MaterialTheme {
        Column(Modifier.padding(16.dp).clip(MaterialTheme.shapes.large).background(groupedCardColor())) {
            TaskRowItem(
                row = previewRow("Sortir les poubelles", TaskStatus.TODO, TaskPriority.HIGH, "Aujourd’hui à 20:00", isOverdue = true, groupName = "Coloc' rue des Lilas"),
                onToggleStatus = {},
                onClick = {},
                showGroupName = true,
            )
            TaskRowItem(
                row = previewRow("Faire les courses", TaskStatus.IN_PROGRESS, TaskPriority.MEDIUM, "Demain à 18:00", isNew = true, groupName = "Coloc' rue des Lilas"),
                onToggleStatus = {},
                onClick = {},
                showGroupName = true,
                isBusy = false,
            )
            val lucas = UUID(0, 2)
            TaskRowItem(
                row = previewRow("Nettoyer la cuisine", TaskStatus.DONE, TaskPriority.MEDIUM, null, assigneesText = "Lucas Bernard", assigneeIds = listOf(lucas)),
                onToggleStatus = null,
                onClick = {},
                assignees = listOf(lucas to "Lucas Bernard"),
            )
            TaskRowItem(
                row = previewRow("Réparer la fuite du lavabo", TaskStatus.TODO, TaskPriority.LOW, "Dimanche 27 septembre à 18:00", assigneesText = MemberDirectory.UNASSIGNED_TEXT),
                onToggleStatus = {},
                onClick = {},
            )
        }
    }
}

// endregion
