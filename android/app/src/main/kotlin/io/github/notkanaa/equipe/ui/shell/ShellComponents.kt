package io.github.notkanaa.equipe.ui.shell

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Info
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.LocalContentColor
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.Stable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.semantics.testTagsAsResourceId
import androidx.compose.ui.text.TextRange
import androidx.compose.ui.text.input.TextFieldValue
import androidx.compose.ui.unit.dp

/** True when the app runs on the in-memory mock backend (UI tests): screens avoid system overlays such as autofill. */
val LocalMockBackend = staticCompositionLocalOf { false }

/** Test tags of the shell (same identifiers as iOS `AccessibilityID.Shell`). */
object ShellTestTags {
    /** Splash screen shown while the stored session is restored. */
    const val SPLASH: String = "shell.splash"

    /** « Configuration manquante » screen. */
    const val CONFIGURATION_MISSING: String = "shell.configurationMissing"
}

/** Maximum width of the form columns (large screens). */
internal val FormMaxWidth = 480.dp

/**
 * Exposes the test tags of a separate window (dialog, popup, bottom sheet) as resource ids for UI Automator: the flag
 * set on the activity's root does not cross window boundaries.
 */
fun Modifier.exposeTestTags(): Modifier = semantics { testTagsAsResourceId = true }

/**
 * Moves the focus (and the keyboard) to this field from an effect. A field that is not attached yet (a screen leaving
 * or not laid out) keeps the focus where it is instead of throwing.
 */
internal fun FocusRequester.requestFocusIfAttached() {
    try {
        requestFocus()
    } catch (error: IllegalStateException) {
        // Not attached to a focusable node (yet): nothing to focus.
    }
}

/** The « Erreur » alert of a view model's error (iOS `shellErrorAlert`). Dismissing it clears the error. */
@Composable
fun ShellErrorDialog(message: String, onDismiss: () -> Unit) {
    AlertDialog(
        onDismissRequest = onDismiss,
        confirmButton = {
            TextButton(onClick = onDismiss, modifier = Modifier.exposeTestTags()) {
                Text("OK")
            }
        },
        title = { Text("Erreur") },
        text = { Text(message) },
    )
}

/**
 * Full-width primary action button that shows a spinner while its action runs (iOS `ShellPrimaryButtonLabel` with the
 * prominent style). Disabled while [isLoading].
 */
@Composable
fun ShellPrimaryButton(
    text: String,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    enabled: Boolean = true,
    isLoading: Boolean = false,
) {
    Button(
        onClick = onClick,
        enabled = enabled && !isLoading,
        modifier = modifier
            .fillMaxWidth()
            .heightIn(min = 52.dp)
            .semantics { if (isLoading) stateDescription = "En cours" },
    ) {
        Box(contentAlignment = Alignment.Center) {
            Text(
                text = text,
                style = MaterialTheme.typography.titleMedium,
                modifier = Modifier.alpha(if (isLoading) 0f else 1f),
            )
            if (isLoading) {
                CircularProgressIndicator(
                    modifier = Modifier
                        .size(22.dp)
                        .clearAndSetSemantics {},
                    color = LocalContentColor.current,
                    strokeWidth = 2.5.dp,
                )
            }
        }
    }
}

/** Neutral information banner (« Si un compte existe… », « Un nouveau code… »). */
@Composable
fun ShellInfoBanner(message: String, modifier: Modifier = Modifier, icon: ImageVector = Icons.Filled.Info) {
    Row(
        modifier = modifier
            .fillMaxWidth()
            .background(MaterialTheme.colorScheme.primaryContainer, RoundedCornerShape(12.dp))
            .padding(14.dp)
            .semantics(mergeDescendants = true) {},
        horizontalArrangement = Arrangement.spacedBy(12.dp),
        verticalAlignment = Alignment.Top,
    ) {
        Icon(icon, contentDescription = null, tint = MaterialTheme.colorScheme.onPrimaryContainer)
        Text(
            text = message,
            style = MaterialTheme.typography.bodyMedium,
            color = MaterialTheme.colorScheme.onPrimaryContainer,
        )
    }
}

/**
 * The text of a field bound to a view-model property (`model.email`, `model.code`…).
 *
 * The field edits a local value that is written to the model at every change and read back right away (the model may
 * sanitize it, e.g. the 6-digit code): typing never waits for the model's StateFlow to be collected, which would drop
 * characters and move the cursor. When the model changes the value itself (password cleared, name loaded), the field
 * follows (see [rememberBoundText]).
 */
@Stable
class BoundText internal constructor(
    initial: String,
    private val read: () -> String,
    private val write: (String) -> Unit,
) {
    var value: TextFieldValue by mutableStateOf(TextFieldValue(initial, TextRange(initial.length)))
        private set

    /** `onValueChange` of the field. */
    fun onValueChange(newValue: TextFieldValue) {
        if (newValue.text != read()) write(newValue.text)
        val stored = read()
        value = if (stored == newValue.text) newValue else TextFieldValue(stored, TextRange(stored.length))
    }

    /** Follows a change made by the model itself. */
    internal fun sync() {
        val stored = read()
        if (stored != value.text) value = TextFieldValue(stored, TextRange(stored.length))
    }
}

/**
 * Remembers a [BoundText] for one property of the model [key]. [observed] is the property as collected from the model's
 * state (it only triggers the synchronization); [read] and [write] access the model directly.
 */
@Composable
fun rememberBoundText(key: Any, observed: String, read: () -> String, write: (String) -> Unit): BoundText {
    val currentRead by rememberUpdatedState(read)
    val currentWrite by rememberUpdatedState(write)
    val bound = remember(key) { BoundText(read(), { currentRead() }, { currentWrite(it) }) }
    LaunchedEffect(bound, observed) { bound.sync() }
    return bound
}
