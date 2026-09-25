package io.github.notkanaa.equipe.ui.components.tasks

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Error
import androidx.compose.material.icons.outlined.Event
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.TextUnit
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import io.github.notkanaa.equipe.core.TaskPriority
import io.github.notkanaa.equipe.core.TaskStatus
import io.github.notkanaa.equipe.core.viewmodel.MyTasksViewModel
import io.github.notkanaa.equipe.core.viewmodel.label
import io.github.notkanaa.equipe.core.viewmodel.next

// Small building blocks describing a task: priority, status and « Nouveau » capsules, due date, status icon and the
// round status button. Shared by the task screen, « Mes tâches » and the group screen (port of the iOS
// TasksBadges.swift, TasksDueDateLabel.swift and TasksStatusControls.swift).

/** Capsule « Haute » / « Moyenne » / « Basse » with the priority icon. TalkBack: « Priorité haute ». */
@Composable
fun PriorityBadge(priority: TaskPriority, modifier: Modifier = Modifier, showsLabel: Boolean = true) {
    val description = priorityAccessibilityText(priority)
    PriorityCapsule(priority, showsLabel, modifier.clearAndSetSemantics { contentDescription = description })
}

/** Capsule « À faire » / « En cours » / « Terminée » with the status icon. TalkBack: « Statut : En cours ». */
@Composable
fun StatusBadge(status: TaskStatus, modifier: Modifier = Modifier) {
    val tint = statusTint(status)
    val description = "Statut : ${status.label}"
    Row(
        modifier = modifier
            .clearAndSetSemantics { contentDescription = description }
            .clip(CircleShape)
            .background(tint.copy(alpha = 0.15f))
            .padding(horizontal = 8.dp, vertical = 3.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(4.dp),
    ) {
        Icon(statusIcon(status), contentDescription = null, tint = tint, modifier = Modifier.size(scaledDp(16.sp)))
        Text(
            text = status.label,
            style = MaterialTheme.typography.labelMedium,
            fontWeight = FontWeight.SemiBold,
            color = tint,
            maxLines = 1,
        )
    }
}

/** « Nouveau » capsule of a task assigned by someone else since the user last looked (« Mes tâches »). */
@Composable
fun NewBadge(modifier: Modifier = Modifier) {
    Text(
        text = MyTasksViewModel.NEW_BADGE_TEXT,
        modifier = modifier
            .clip(CircleShape)
            // Not the dark-mode primary: white on the brand blue is 4.8:1 in both themes.
            .background(TaskAccentFill)
            .padding(horizontal = 7.dp, vertical = 2.dp),
        style = MaterialTheme.typography.labelSmall,
        fontWeight = FontWeight.Bold,
        color = Color.White,
        maxLines = 1,
        softWrap = false,
    )
}

/**
 * Due date of a task (« Aujourd’hui à 20:00 », already formatted by the view models), in red with a filled « ! » icon
 * when overdue. Without a due date it shows nothing, or « Aucune échéance » when [showsPlaceholder].
 * TalkBack: « Échéance : … » / « Échéance dépassée : … ».
 */
@Composable
fun DueLabel(text: String?, isOverdue: Boolean, modifier: Modifier = Modifier, showsPlaceholder: Boolean = false) {
    if (text == null && !showsPlaceholder) return
    val description = dueAccessibilityText(text, isOverdue)
    DueLabelContent(text, isOverdue, modifier.clearAndSetSemantics { contentDescription = description })
}

/** Status icon in its colour (decorative unless [contentDescription] is given). 24 dp unless [modifier] sizes it. */
@Composable
fun StatusIcon(status: TaskStatus, modifier: Modifier = Modifier, contentDescription: String? = null) {
    Icon(statusIcon(status), contentDescription = contentDescription, tint = statusTint(status), modifier = modifier)
}

/**
 * Round status button of a task row (48 dp touch target): a tap asks for the next status of the cycle (à faire → en cours
 * → terminée → à faire; the caller runs the change, e.g. `model.setStatus(row.status.next, row.task)`), with a spinner
 * while [isBusy]. [onClick] null: the status icon only, dimmed and hidden from TalkBack (no button). Test tag
 * `tasks.status`.
 */
@Composable
fun TaskStatusButton(status: TaskStatus, onClick: (() -> Unit)?, modifier: Modifier = Modifier, isBusy: Boolean = false) {
    val tint = statusTint(status)
    val glyphSize = 26.dp
    if (onClick == null) {
        Box(modifier.size(48.dp).clearAndSetSemantics { }, contentAlignment = Alignment.Center) {
            Icon(statusIcon(status), contentDescription = null, tint = tint.copy(alpha = 0.55f), modifier = Modifier.size(glyphSize))
        }
        return
    }
    val description = "Statut : ${status.label}"
    Box(
        modifier = modifier
            .size(48.dp)
            .clip(CircleShape)
            .clickable(
                enabled = !isBusy,
                onClickLabel = nextStatusActionTitle(status),
                role = Role.Button,
                onClick = onClick,
            )
            .semantics { contentDescription = description }
            .testTag(TaskTestTags.STATUS_BUTTON),
        contentAlignment = Alignment.Center,
    ) {
        if (isBusy) {
            CircularProgressIndicator(modifier = Modifier.size(20.dp), color = tint, strokeWidth = 2.dp)
        } else {
            Icon(statusIcon(status), contentDescription = null, tint = tint, modifier = Modifier.size(glyphSize))
        }
    }
}

// region Internal pieces (also used inside the task row, whose single TalkBack sentence replaces their descriptions)

/** The priority capsule without semantics of its own (its text stays in the tree). */
@Composable
internal fun PriorityCapsule(priority: TaskPriority, showsLabel: Boolean, modifier: Modifier = Modifier) {
    val tint = priorityTint(priority)
    Row(
        modifier = modifier
            .clip(CircleShape)
            .background(tint.copy(alpha = 0.15f))
            .padding(horizontal = 8.dp, vertical = 3.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(3.dp),
    ) {
        Icon(priorityIcon(priority), contentDescription = null, tint = tint, modifier = Modifier.size(scaledDp(14.sp)))
        if (showsLabel) {
            Text(
                text = priority.label,
                style = MaterialTheme.typography.labelMedium,
                fontWeight = FontWeight.SemiBold,
                color = tint,
                maxLines = 1,
            )
        }
    }
}

/** The due date label without semantics of its own; « Aucune échéance » when [text] is null. */
@Composable
internal fun DueLabelContent(
    text: String?,
    isOverdue: Boolean,
    modifier: Modifier = Modifier,
    style: TextStyle = MaterialTheme.typography.bodySmall,
) {
    val overdue = isOverdue && text != null
    val color = if (overdue) overdueTint() else MaterialTheme.colorScheme.onSurfaceVariant
    Row(
        modifier = modifier,
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(4.dp),
    ) {
        Icon(
            imageVector = if (overdue) Icons.Filled.Error else Icons.Outlined.Event,
            contentDescription = null,
            tint = color,
            modifier = Modifier.size(scaledDp(if (style.fontSize.isSp) style.fontSize else 12.sp, extra = 2.dp)),
        )
        Text(
            text = text ?: NO_DUE_DATE_TEXT,
            style = style,
            fontWeight = if (overdue) FontWeight.SemiBold else FontWeight.Normal,
            color = color,
            maxLines = 2,
            overflow = TextOverflow.Ellipsis,
        )
    }
}

internal const val NO_DUE_DATE_TEXT: String = "Aucune échéance"

/** « Priorité haute ». */
internal fun priorityAccessibilityText(priority: TaskPriority): String = "Priorité ${priority.label.lowercase()}"

/** « Échéance : Demain à 18:00 », « Échéance dépassée : Hier à 18:00 », « Aucune échéance ». */
internal fun dueAccessibilityText(text: String?, isOverdue: Boolean): String = when {
    text == null -> NO_DUE_DATE_TEXT
    isOverdue -> "Échéance dépassée : $text"
    else -> "Échéance : $text"
}

/** « Passer à « En cours » » (status cycle action). */
internal fun nextStatusActionTitle(status: TaskStatus): String = "Passer à « ${status.next.label} »"

/** A size that follows the font scale like text of [fontSize] does (icons next to text), plus [extra]. */
@Composable
internal fun scaledDp(fontSize: TextUnit, extra: Dp = 0.dp): Dp = with(LocalDensity.current) { fontSize.toDp() } + extra

// endregion
