package io.github.notkanaa.equipe.ui.settings

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.RowScope
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.UnfoldMore
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.takeOrElse
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.role
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import io.github.notkanaa.equipe.ui.shell.exposeTestTags
import io.github.notkanaa.equipe.ui.theme.extendedColors

/** Horizontal padding of the rows inside a section card. */
private val RowPadding = 16.dp

/** Widest label of a label / value row: the rest of the row is left to the value. */
private val LabelMaxWidth = 160.dp

/**
 * A group of rows on a card, with an optional header above and footer below (a section of the iOS `Form`).
 * [footerColor] defaults to the secondary text colour.
 */
@Composable
internal fun SettingsSection(
    header: String?,
    modifier: Modifier = Modifier,
    footer: String? = null,
    footerColor: Color = Color.Unspecified,
    content: @Composable ColumnScope.() -> Unit,
) {
    Column(modifier = modifier.fillMaxWidth().padding(horizontal = 16.dp)) {
        if (header != null) {
            Text(
                text = header,
                style = MaterialTheme.typography.titleSmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier
                    .padding(start = RowPadding, end = RowPadding, bottom = 8.dp)
                    .semantics { heading() },
            )
        }
        Surface(
            shape = MaterialTheme.shapes.large,
            color = MaterialTheme.extendedColors.card,
            modifier = Modifier.fillMaxWidth(),
        ) {
            Column(content = content)
        }
        if (footer != null) {
            Text(
                text = footer,
                style = MaterialTheme.typography.bodySmall,
                color = footerColor.takeOrElse { MaterialTheme.colorScheme.onSurfaceVariant },
                modifier = Modifier.padding(start = RowPadding, end = RowPadding, top = 8.dp),
            )
        }
    }
}

/** Separator between two rows of a section (inset like iOS). */
@Composable
internal fun SettingsDivider() {
    HorizontalDivider(
        modifier = Modifier.padding(start = RowPadding),
        color = MaterialTheme.colorScheme.outlineVariant,
    )
}

/** The frame of a row: at least 56 dp high, icon + content in a row. */
@Composable
private fun SettingsRowFrame(
    modifier: Modifier = Modifier,
    icon: ImageVector? = null,
    iconTint: Color = MaterialTheme.colorScheme.primary,
    content: @Composable RowScope.() -> Unit,
) {
    Row(
        modifier = modifier
            .fillMaxWidth()
            .heightIn(min = 56.dp)
            .padding(horizontal = RowPadding, vertical = 12.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(16.dp),
    ) {
        if (icon != null) {
            Icon(icon, contentDescription = null, tint = iconTint)
        }
        content()
    }
}

/** A label and its read-only value (e-mail, version…); the value can be selected and copied. */
@Composable
internal fun SettingsValueRow(
    label: String,
    value: String,
    modifier: Modifier = Modifier,
    icon: ImageVector? = null,
    selectable: Boolean = false,
) {
    SettingsRowFrame(modifier = modifier.semantics(mergeDescendants = !selectable) {}, icon = icon) {
        // The label keeps its own width (wrapped past LabelMaxWidth at large font scales); the value takes the rest of
        // the row, right-aligned, and is shortened only when it really does not fit.
        Text(label, style = MaterialTheme.typography.bodyLarge, modifier = Modifier.widthIn(max = LabelMaxWidth))
        Box(modifier = Modifier.weight(1f), contentAlignment = Alignment.CenterEnd) {
            val text = @Composable {
                Text(
                    text = value,
                    style = MaterialTheme.typography.bodyLarge,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    textAlign = TextAlign.End,
                    maxLines = 1,
                    overflow = TextOverflow.MiddleEllipsis,
                )
            }
            if (selectable) SelectionContainer { text() } else text()
        }
    }
}

/** A label followed by arbitrary trailing content (e.g. a spinner while loading). */
@Composable
internal fun SettingsLabelRow(
    label: String,
    modifier: Modifier = Modifier,
    icon: ImageVector? = null,
    trailing: @Composable () -> Unit,
) {
    SettingsRowFrame(modifier = modifier, icon = icon) {
        Text(label, style = MaterialTheme.typography.bodyLarge, modifier = Modifier.weight(1f))
        trailing()
    }
}

/**
 * A button row: icon and label in the accent colour (red when [destructive]), a spinner at the end while
 * [isLoading].
 */
@Composable
internal fun SettingsActionRow(
    label: String,
    icon: ImageVector,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    enabled: Boolean = true,
    destructive: Boolean = false,
    isLoading: Boolean = false,
) {
    val baseColor = if (destructive) MaterialTheme.colorScheme.error else MaterialTheme.colorScheme.primary
    val color = if (enabled) baseColor else MaterialTheme.colorScheme.onSurface.copy(alpha = 0.38f)
    SettingsRowFrame(
        modifier = modifier
            .clickable(enabled = enabled, role = Role.Button, onClick = onClick)
            .semantics { if (isLoading) stateDescription = "En cours" },
        icon = icon,
        iconTint = color,
    ) {
        Text(label, style = MaterialTheme.typography.bodyLarge, color = color, modifier = Modifier.weight(1f))
        if (isLoading) {
            CircularProgressIndicator(
                modifier = Modifier
                    .size(20.dp)
                    .clearAndSetSemantics {},
                strokeWidth = 2.dp,
            )
        }
    }
}

/**
 * A choice among [options] (iOS menu picker): the row shows the current choice; a tap opens the list, the current
 * choice checked. Each option carries the tag `<testTag>.<optionKey>`.
 */
@Composable
internal fun <T> SettingsPickerRow(
    label: String,
    icon: ImageVector,
    selected: T,
    options: List<T>,
    optionLabel: (T) -> String,
    optionKey: (T) -> String,
    onSelect: (T) -> Unit,
    testTag: String,
    modifier: Modifier = Modifier,
) {
    var isExpanded by remember { mutableStateOf(false) }
    Box(modifier = modifier.fillMaxWidth()) {
        SettingsRowFrame(
            modifier = Modifier
                .clickable(role = Role.DropdownList) { isExpanded = true }
                .testTag(testTag)
                .semantics(mergeDescendants = true) { stateDescription = optionLabel(selected) },
            icon = icon,
        ) {
            Text(label, style = MaterialTheme.typography.bodyLarge, modifier = Modifier.weight(1f))
            Text(
                text = optionLabel(selected),
                style = MaterialTheme.typography.bodyLarge,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.clearAndSetSemantics {},
            )
            Icon(
                imageVector = Icons.Filled.UnfoldMore,
                contentDescription = null,
                tint = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
        Box(modifier = Modifier.align(Alignment.BottomEnd)) {
            DropdownMenu(
                expanded = isExpanded,
                onDismissRequest = { isExpanded = false },
                modifier = Modifier.exposeTestTags(),
            ) {
                for (option in options) {
                    val isSelected = option == selected
                    DropdownMenuItem(
                        text = { Text(optionLabel(option)) },
                        onClick = {
                            isExpanded = false
                            onSelect(option)
                        },
                        leadingIcon = {
                            if (isSelected) {
                                Icon(Icons.Filled.Check, contentDescription = null)
                            } else {
                                Box(modifier = Modifier.size(24.dp))
                            }
                        },
                        modifier = Modifier
                            .testTag("$testTag.${optionKey(option)}")
                            .semantics { if (isSelected) stateDescription = "Sélectionné" },
                    )
                }
            }
        }
    }
}
