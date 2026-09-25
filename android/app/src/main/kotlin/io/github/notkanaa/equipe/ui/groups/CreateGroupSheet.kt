@file:OptIn(ExperimentalMaterial3Api::class)

package io.github.notkanaa.equipe.ui.groups

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.RowScope
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.text.input.TextFieldLineLimits
import androidx.compose.foundation.text.input.rememberTextFieldState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.ErrorOutline
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.SheetState
import androidx.compose.material3.SheetValue
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.snapshotFlow
import androidx.compose.runtime.withFrameNanos
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.liveRegion
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardCapitalization
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import io.github.notkanaa.equipe.core.GroupSummary
import io.github.notkanaa.equipe.core.InputValidation
import io.github.notkanaa.equipe.core.viewmodel.CreateGroupViewModel
import io.github.notkanaa.equipe.core.viewmodel.SessionModel
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.launch

// Port of App/Sources/Features/Groups/CreateGroupSheet.swift and CreateGroupNameCounter.swift.

/**
 * « Nouveau groupe » bottom sheet: the name with a live « n/60 » counter measured like the validation, « Annuler » /
 * « Créer ». The creator becomes the group's admin; on success the sheet closes and [onCreated] is called (the
 * presenter shows the group). The sheet cannot be dismissed while the group is being created.
 */
@Composable
internal fun CreateGroupSheet(
    session: SessionModel,
    onDismiss: () -> Unit,
    onCreated: (GroupSummary) -> Unit,
) {
    val model = remember(session) { CreateGroupViewModel(session) }
    val state by model.state.collectAsStateWithLifecycle()
    val nameField = rememberTextFieldState()
    LaunchedEffect(nameField) { snapshotFlow { nameField.text.toString() }.collect { model.name = it } }

    val isSubmitting by rememberUpdatedState(state.isSubmitting)
    val sheetState = rememberModalBottomSheetState(
        skipPartiallyExpanded = true,
        confirmValueChange = { value -> value != SheetValue.Hidden || !isSubmitting },
    )
    val scope = rememberCoroutineScope()
    val focusRequester = remember { FocusRequester() }

    fun submit() {
        model.name = nameField.text.toString()
        if (!model.state.value.canSubmit) return
        // The creation completes even if the screen goes away.
        session.scope.launch { model.create() }
    }

    val created = state.createdGroup
    LaunchedEffect(created) {
        if (created != null) {
            sheetState.hide()
            onCreated(created)
        }
    }
    LaunchedEffect(focusRequester) { focusWhenAttached(focusRequester) }

    ModalBottomSheet(onDismissRequest = onDismiss, sheetState = sheetState, modifier = Modifier.windowTestTags()) {
        SheetHeader(
            title = "Nouveau groupe",
            leading = {
                TextButton(
                    onClick = { hideThen(scope, sheetState, onDismiss) },
                    enabled = !state.isSubmitting,
                    modifier = Modifier.testTag(GroupsTags.CANCEL),
                ) {
                    Text("Annuler")
                }
            },
            trailing = {
                if (state.isSubmitting) {
                    SpinnerBox(contentDescription = "Création du groupe")
                } else {
                    TextButton(
                        onClick = { submit() },
                        enabled = state.canSubmit,
                        modifier = Modifier.testTag(GroupsTags.SAVE),
                    ) {
                        Text("Créer")
                    }
                }
            },
        )
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .verticalScroll(rememberScrollState())
                .padding(start = 16.dp, end = 16.dp, top = 8.dp, bottom = 24.dp),
            verticalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            OutlinedTextField(
                state = nameField,
                enabled = !state.isSubmitting,
                label = { Text("Nom du groupe") },
                isError = state.nameError != null,
                lineLimits = TextFieldLineLimits.SingleLine,
                keyboardOptions = KeyboardOptions(
                    capitalization = KeyboardCapitalization.Sentences,
                    imeAction = ImeAction.Done,
                ),
                onKeyboardAction = { submit() },
                modifier = Modifier
                    .fillMaxWidth()
                    .focusRequester(focusRequester)
                    .testTag(GroupsTags.NAME_FIELD),
            )
            state.nameError?.let { NameError(it) }
            NameFooter(name = nameField.text.toString())
        }
    }

    ErrorAlert(state.error, model::dismissError)
}

/** Validation message under a name field (red, announced by TalkBack). */
@Composable
internal fun NameError(message: String) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = 16.dp)
            .testTag(GroupsTags.NAME_ERROR)
            .semantics(mergeDescendants = true) { liveRegion = LiveRegionMode.Polite },
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        Icon(
            imageVector = Icons.Outlined.ErrorOutline,
            contentDescription = null,
            tint = MaterialTheme.colorScheme.error,
            modifier = Modifier.size(18.dp),
        )
        Text(text = message, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.error)
    }
}

/**
 * Explanation and « n/60 » counter. Measured like the validation (code points of the trimmed name, docs/CONTRACTS.md
 * §1), so the counter turns red exactly when « Créer » would refuse the name.
 */
@Composable
private fun NameFooter(name: String) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = 16.dp),
        horizontalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Text(
            text = "Par exemple « Coloc’ », « Famille » ou « Projet asso ». " +
                "Vous serez admin du groupe et pourrez inviter d’autres personnes.",
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            modifier = Modifier.weight(1f),
        )
        NameCounter(name)
    }
}

/** « 15/60 » (red above the limit); TalkBack reads « 15 caractères sur 60 ». */
@Composable
internal fun NameCounter(name: String, modifier: Modifier = Modifier) {
    val length = NameLength.of(name)
    val max = CreateGroupViewModel.MAX_NAME_LENGTH
    Text(
        text = "$length/$max",
        style = MaterialTheme.typography.bodySmall.merge(TabularNumbers),
        color = if (length > max) MaterialTheme.colorScheme.error else MaterialTheme.colorScheme.onSurfaceVariant,
        modifier = modifier.clearAndSetSemantics { contentDescription = "$length caractères sur $max" },
    )
}

/** Length of a group name as the validation measures it: code points of the trimmed name. */
internal object NameLength {
    fun of(name: String): Int = InputValidation.length(InputValidation.trimmed(name))
}

/**
 * Header of the sheets, like the iOS navigation bar of a sheet: [leading] (« Annuler »), the centered title,
 * [trailing] (« Créer », a spinner…).
 */
@Composable
internal fun SheetHeader(
    title: String,
    leading: @Composable RowScope.() -> Unit = {},
    trailing: @Composable RowScope.() -> Unit = {},
) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .heightIn(min = 56.dp)
            .padding(horizontal = 8.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Row(Modifier.widthIn(min = 72.dp), verticalAlignment = Alignment.CenterVertically, content = leading)
        Text(
            text = title,
            style = MaterialTheme.typography.titleMedium,
            textAlign = TextAlign.Center,
            modifier = Modifier
                .weight(1f)
                .padding(horizontal = 4.dp)
                .semantics { heading() },
        )
        Row(
            Modifier.widthIn(min = 72.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.End,
            content = trailing,
        )
    }
}

/** Hides the sheet with its animation, then calls [then] (M3 pattern for buttons that close a sheet). */
internal fun hideThen(scope: CoroutineScope, sheetState: SheetState, then: () -> Unit) {
    scope.launch { sheetState.hide() }.invokeOnCompletion {
        if (!sheetState.isVisible) then()
    }
}

/**
 * Focuses a field of a sheet once it is attached (shows the keyboard, like the iOS `@FocusState` set on appear): the
 * sheet's content is laid out a few frames after the sheet is composed.
 */
internal suspend fun focusWhenAttached(focusRequester: FocusRequester) {
    repeat(10) {
        withFrameNanos { }
        val focused = try {
            focusRequester.requestFocus()
        } catch (error: IllegalStateException) {
            false // Not attached yet.
        }
        if (focused) return
    }
}

/** A box of at least 48 dp for a trailing spinner (keeps the header height stable). */
@Composable
internal fun SpinnerBox(contentDescription: String) {
    Box(Modifier.size(48.dp), contentAlignment = Alignment.Center) { RowSpinner(contentDescription) }
}
