package io.github.notkanaa.equipe.ui.components.tasks

import androidx.compose.foundation.shape.CornerBasedShape
import androidx.compose.foundation.shape.ZeroCornerSize
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.ArrowDownward
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.Contrast
import androidx.compose.material.icons.filled.PriorityHigh
import androidx.compose.material.icons.filled.RadioButtonUnchecked
import androidx.compose.material.icons.filled.Remove
import androidx.compose.material.icons.outlined.CalendarMonth
import androidx.compose.material.icons.outlined.CheckCircle
import androidx.compose.material.icons.outlined.ErrorOutline
import androidx.compose.material.icons.outlined.EventRepeat
import androidx.compose.material.icons.outlined.Inbox
import androidx.compose.material.icons.outlined.WbSunny
import androidx.compose.material3.MaterialTheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.Immutable
import androidx.compose.runtime.ReadOnlyComposable
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.luminance
import androidx.compose.ui.graphics.vector.ImageVector
import io.github.notkanaa.equipe.core.TaskPriority
import io.github.notkanaa.equipe.core.TaskStatus
import io.github.notkanaa.equipe.core.logic.DueBucket
import io.github.notkanaa.equipe.core.viewmodel.iconName

// Colours, icons and surfaces of the task screens. Private tokens of this package (the brief forbids depending on the
// shell's theme objects): everything else comes from MaterialTheme.colorScheme / typography / shapes.

/**
 * Tints of the status and priority capsules, icons and due dates (port of the iOS `ShellPalette`, darkened in light mode
 * and lightened in dark mode for the Material surfaces): every tint reaches WCAG AA (4.5:1) as small text on the light
 * surfaces (white to #ECE6F0) or the dark ones (black to #2C2C2E), including inside its own 12–15 % capsule.
 */
@Immutable
internal class TaskPalette(
    val gray: Color,
    val blue: Color,
    val green: Color,
    val orange: Color,
    val red: Color,
    /** Text on a solid tint (selected status): white on the dark light-mode tints, black on the bright dark-mode ones. */
    val onTint: Color,
)

internal val LightTaskPalette = TaskPalette(
    gray = Color(0xFF59595E),
    blue = Color(0xFF1154B7),
    green = Color(0xFF17662B),
    orange = Color(0xFF8D4500),
    red = Color(0xFFAA1D16),
    onTint = Color.White,
)

internal val DarkTaskPalette = TaskPalette(
    gray = Color(0xFFAEAEB2),
    blue = Color(0xFF65AFFF),
    green = Color(0xFF30D158),
    orange = Color(0xFFFF9F0A),
    red = Color(0xFFFF8881),
    onTint = Color.Black,
)

/** Fill behind white text (« Nouveau »): the brand blue #416CD9, 4.8:1 with white, in both themes. */
internal val TaskAccentFill = Color(0xFF416CD9)

/** True when the current Material theme is dark (its surface is dark), whatever decided it (system or setting). */
@Composable
@ReadOnlyComposable
internal fun isDarkTaskTheme(): Boolean = MaterialTheme.colorScheme.surface.luminance() < 0.5f

@Composable
@ReadOnlyComposable
internal fun taskPalette(): TaskPalette = if (isDarkTaskTheme()) DarkTaskPalette else LightTaskPalette

/** Accent colour of a status (icons, capsules): gray « À faire », blue « En cours », green « Terminée ». AA as small text. */
@Composable
@ReadOnlyComposable
fun statusTint(status: TaskStatus): Color {
    val palette = taskPalette()
    return when (status) {
        TaskStatus.TODO -> palette.gray
        TaskStatus.IN_PROGRESS -> palette.blue
        TaskStatus.DONE -> palette.green
    }
}

/** Accent colour of a priority (capsules): gray « Basse », orange « Moyenne », red « Haute ». AA as small text. */
@Composable
@ReadOnlyComposable
fun priorityTint(priority: TaskPriority): Color {
    val palette = taskPalette()
    return when (priority) {
        TaskPriority.LOW -> palette.gray
        TaskPriority.MEDIUM -> palette.orange
        TaskPriority.HIGH -> palette.red
    }
}

/** Red of overdue due dates, « En retard » and destructive hints. AA as small text. */
@Composable
@ReadOnlyComposable
fun overdueTint(): Color = taskPalette().red

/** Green of « Terminée le … ». AA as small text. */
@Composable
@ReadOnlyComposable
internal fun completedTint(): Color = taskPalette().green

/** Material icon of a status (the view models' `TaskStatus.iconName`): ○, half-filled circle, filled check. */
fun statusIcon(status: TaskStatus): ImageVector = when (status.iconName) {
    "RadioButtonUnchecked" -> Icons.Filled.RadioButtonUnchecked
    "Contrast" -> Icons.Filled.Contrast
    "CheckCircle" -> Icons.Filled.CheckCircle
    else -> Icons.Filled.RadioButtonUnchecked
}

/** Material icon of a priority (the view models' `TaskPriority.iconName`): ↓, –, !. */
fun priorityIcon(priority: TaskPriority): ImageVector = when (priority.iconName) {
    "ArrowDownward" -> Icons.Filled.ArrowDownward
    "Remove" -> Icons.Filled.Remove
    "PriorityHigh" -> Icons.Filled.PriorityHigh
    else -> Icons.Filled.Remove
}

/** Icon of a « Mes tâches » section header (iOS `DueBucket.tasksSystemImage`). */
fun dueBucketIcon(bucket: DueBucket): ImageVector = when (bucket) {
    DueBucket.OVERDUE -> Icons.Outlined.ErrorOutline
    DueBucket.TODAY -> Icons.Outlined.WbSunny
    DueBucket.THIS_WEEK -> Icons.Outlined.CalendarMonth
    DueBucket.LATER -> Icons.Outlined.EventRepeat
    DueBucket.NO_DUE_DATE -> Icons.Outlined.Inbox
    DueBucket.DONE -> Icons.Outlined.CheckCircle
}

// region Grouped surfaces (iOS inset-grouped lists: grey background, rounded cards)

/** Screen background behind the cards: light grey (light), near black (dark). */
@Composable
@ReadOnlyComposable
internal fun groupedBackgroundColor(): Color =
    if (isDarkTaskTheme()) MaterialTheme.colorScheme.surfaceContainerLowest else MaterialTheme.colorScheme.surfaceContainer

/** Card colour: white (light), dark grey (dark). */
@Composable
@ReadOnlyComposable
internal fun groupedCardColor(): Color =
    if (isDarkTaskTheme()) MaterialTheme.colorScheme.surfaceContainerHigh else MaterialTheme.colorScheme.surfaceContainerLowest

/** Shape of the whole card (`MaterialTheme.shapes.large`). */
@Composable
@ReadOnlyComposable
internal fun groupedCardShape(): CornerBasedShape = MaterialTheme.shapes.large

/** Shape of item [index] of [count] items forming one card: rounded top on the first, rounded bottom on the last. */
@Composable
@ReadOnlyComposable
internal fun groupedItemShape(index: Int, count: Int): CornerBasedShape {
    val shape = groupedCardShape()
    val isFirst = index == 0
    val isLast = index == count - 1
    return when {
        isFirst && isLast -> shape
        isFirst -> shape.copy(bottomStart = ZeroCornerSize, bottomEnd = ZeroCornerSize)
        isLast -> shape.copy(topStart = ZeroCornerSize, topEnd = ZeroCornerSize)
        else -> shape.copy(all = ZeroCornerSize)
    }
}

// endregion
