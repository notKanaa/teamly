package io.github.notkanaa.equipe.ui.components.tasks

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
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
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp

// Internal building blocks of the task screens: grouped cards (iOS inset-grouped lists), section headers and footers,
// loading / message views and the error alert.

/** Title above a card (« Description », « Statut »…), announced as a heading. */
@Composable
internal fun TaskSectionHeader(text: String, modifier: Modifier = Modifier, color: Color = MaterialTheme.colorScheme.onSurfaceVariant) {
    Text(
        text = text,
        modifier = modifier
            .fillMaxWidth()
            .padding(start = 16.dp, end = 16.dp, top = 20.dp, bottom = 8.dp)
            .semantics { heading() },
        style = MaterialTheme.typography.titleSmall,
        color = color,
    )
}

/** Small text under a card (explanations, « Créée par … »). */
@Composable
internal fun TaskSectionFooter(text: String, modifier: Modifier = Modifier, color: Color = MaterialTheme.colorScheme.onSurfaceVariant) {
    Text(
        text = text,
        modifier = modifier
            .fillMaxWidth()
            .padding(start = 16.dp, end = 16.dp, top = 6.dp),
        style = MaterialTheme.typography.bodySmall,
        color = color,
    )
}

/** A rounded card of the grouped list. */
@Composable
internal fun TaskSectionCard(modifier: Modifier = Modifier, content: @Composable ColumnScope.() -> Unit) {
    Column(
        modifier = modifier
            .fillMaxWidth()
            .clip(groupedCardShape())
            .background(groupedCardColor()),
        content = content,
    )
}

/**
 * Item [index] of [count] items that together form one card in a lazy list (rounded top on the first, rounded bottom on
 * the last), with a divider above every item but the first, indented by [dividerStartIndent].
 */
@Composable
internal fun GroupedCardItem(
    index: Int,
    count: Int,
    modifier: Modifier = Modifier,
    dividerStartIndent: Dp = 0.dp,
    content: @Composable ColumnScope.() -> Unit,
) {
    Column(
        modifier = modifier
            .fillMaxWidth()
            .clip(groupedItemShape(index, count))
            .background(groupedCardColor()),
    ) {
        if (index > 0) {
            HorizontalDivider(
                modifier = Modifier.padding(start = dividerStartIndent),
                color = MaterialTheme.colorScheme.outlineVariant,
            )
        }
        content()
    }
}

/** Divider between two rows of a [TaskSectionCard]. */
@Composable
internal fun TaskCardDivider(startIndent: Dp = 16.dp) {
    HorizontalDivider(modifier = Modifier.padding(start = startIndent), color = MaterialTheme.colorScheme.outlineVariant)
}

/** Centered spinner and « Chargement… » (first load). Scrollable so that pull-to-refresh works around it. */
@Composable
internal fun TaskLoadingView(modifier: Modifier = Modifier, text: String = "Chargement…") {
    CenteredScrollColumn(modifier, contentPadding = 32.dp) {
        CircularProgressIndicator()
        Spacer(Modifier.height(12.dp))
        Text(text, style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
    }
}

/**
 * Centered icon, title, message and optional actions (empty states, failed first loads; iOS `ContentUnavailableView`).
 * Scrollable so that pull-to-refresh works around it and large text never gets cut.
 */
@Composable
internal fun TaskMessageView(
    icon: ImageVector,
    title: String,
    message: String?,
    modifier: Modifier = Modifier,
    iconTint: Color = MaterialTheme.colorScheme.onSurfaceVariant,
    actions: @Composable ColumnScope.() -> Unit = {},
) {
    CenteredScrollColumn(modifier, contentPadding = 32.dp) {
        Icon(icon, contentDescription = null, tint = iconTint, modifier = Modifier.size(48.dp))
        Spacer(Modifier.height(16.dp))
        Text(
            text = title,
            modifier = Modifier.semantics { heading() },
            style = MaterialTheme.typography.titleLarge,
            color = MaterialTheme.colorScheme.onSurface,
            textAlign = TextAlign.Center,
        )
        if (message != null) {
            Spacer(Modifier.height(8.dp))
            Text(
                text = message,
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                textAlign = TextAlign.Center,
            )
        }
        Spacer(Modifier.height(20.dp))
        actions()
    }
}

/**
 * A vertically scrollable column filling its (bounded) parent whose content is centered while it fits: at least as
 * tall as the viewport, so `Arrangement.Center` works inside the scroll.
 */
@Composable
private fun CenteredScrollColumn(
    modifier: Modifier,
    contentPadding: Dp,
    content: @Composable ColumnScope.() -> Unit,
) {
    BoxWithConstraints(modifier.fillMaxSize()) {
        val viewportHeight = if (constraints.hasBoundedHeight) maxHeight else 0.dp
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .verticalScroll(rememberScrollState())
                .heightIn(min = viewportHeight)
                .padding(contentPadding),
            verticalArrangement = Arrangement.Center,
            horizontalAlignment = Alignment.CenterHorizontally,
            content = content,
        )
    }
}

/** Inline message with an icon (error under a field, warning banner). */
@Composable
internal fun TaskInlineMessage(icon: ImageVector, text: String, color: Color, modifier: Modifier = Modifier) {
    Row(modifier = modifier, verticalAlignment = Alignment.Top) {
        Icon(icon, contentDescription = null, tint = color, modifier = Modifier.padding(top = 1.dp).size(18.dp))
        Spacer(Modifier.width(6.dp))
        Text(text = text, style = MaterialTheme.typography.bodyMedium, color = color)
    }
}

/** The screens' error alert (« Erreur », message, « OK »). */
@Composable
internal fun TaskErrorAlert(message: String, onDismiss: () -> Unit) {
    AlertDialog(
        onDismissRequest = onDismiss,
        confirmButton = { TextButton(onClick = onDismiss) { Text("OK") } },
        title = { Text("Erreur") },
        text = { Text(message) },
    )
}
