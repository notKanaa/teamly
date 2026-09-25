@file:OptIn(ExperimentalMaterial3Api::class)

package io.github.notkanaa.equipe.ui.groups

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.text.input.InputTransformation
import androidx.compose.foundation.text.input.OutputTransformation
import androidx.compose.foundation.text.input.TextFieldBuffer
import androidx.compose.foundation.text.input.TextFieldLineLimits
import androidx.compose.foundation.text.input.delete
import androidx.compose.foundation.text.input.insert
import androidx.compose.foundation.text.input.rememberTextFieldState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowForward
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedTextField
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
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardCapitalization
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import io.github.notkanaa.equipe.core.InviteCode
import io.github.notkanaa.equipe.core.JoinResult
import io.github.notkanaa.equipe.core.viewmodel.JoinGroupViewModel
import io.github.notkanaa.equipe.core.viewmodel.SessionModel
import kotlinx.coroutines.launch
import java.util.UUID

// Port of App/Sources/Features/Groups/JoinGroupSheet.swift.

/**
 * « Rejoindre un groupe » bottom sheet. The code is formatted live as `ABCD-EFGH` (only letters and digits, upper
 * case, 8 at most: the field holds `JoinGroupViewModel.code` without its dash and displays the dash). Invalid codes,
 * too many attempts and network errors are shown in the error alert; after a join the sheet says whether the group
 * was joined or already joined, and « Ouvrir le groupe » closes it and calls [onOpenGroup].
 */
@Composable
internal fun JoinGroupSheet(
    session: SessionModel,
    onDismiss: () -> Unit,
    onOpenGroup: (UUID) -> Unit,
    initialCode: String = "",
) {
    val model = remember(session) { JoinGroupViewModel(session, initialCode) }
    val state by model.state.collectAsStateWithLifecycle()
    val codeField = rememberTextFieldState(initialText = InviteCode.normalize(model.code).take(InviteCode.length))
    LaunchedEffect(codeField) { snapshotFlow { codeField.text.toString() }.collect { model.code = it } }

    val isSubmitting by rememberUpdatedState(state.isSubmitting)
    val sheetState = rememberModalBottomSheetState(
        skipPartiallyExpanded = true,
        confirmValueChange = { value -> value != SheetValue.Hidden || !isSubmitting },
    )
    val scope = rememberCoroutineScope()
    val focusRequester = remember { FocusRequester() }
    val focusManager = LocalFocusManager.current

    fun submit() {
        model.code = codeField.text.toString()
        if (!model.state.value.canSubmit) return
        focusManager.clearFocus()
        // The join completes even if the screen goes away.
        session.scope.launch { model.join() }
    }

    LaunchedEffect(focusRequester) { focusWhenAttached(focusRequester) }

    ModalBottomSheet(onDismissRequest = onDismiss, sheetState = sheetState, modifier = Modifier.windowTestTags()) {
        val result = state.result
        SheetHeader(
            title = "Rejoindre un groupe",
            leading = {
                TextButton(
                    onClick = { hideThen(scope, sheetState, onDismiss) },
                    enabled = !state.isSubmitting,
                    modifier = Modifier.testTag(GroupsTags.CANCEL),
                ) {
                    Text(if (result == null) "Annuler" else "Fermer")
                }
            },
            trailing = {
                when {
                    state.isSubmitting -> SpinnerBox(contentDescription = "Vérification du code")
                    result == null -> TextButton(
                        onClick = { submit() },
                        enabled = state.canSubmit,
                        modifier = Modifier.testTag(GroupsTags.SAVE),
                    ) {
                        Text("Rejoindre")
                    }
                    else -> Unit
                }
            },
        )
        if (result != null) {
            JoinResultView(
                result = result,
                message = state.resultMessage.orEmpty(),
                onOpen = { hideThen(scope, sheetState) { onOpenGroup(result.groupId) } },
            )
        } else {
            Column(
                modifier = Modifier
                    .fillMaxWidth()
                    .verticalScroll(rememberScrollState())
                    .padding(start = 16.dp, end = 16.dp, top = 8.dp, bottom = 24.dp),
                verticalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                val codeStyle = MaterialTheme.typography.titleLarge.copy(
                    fontFamily = FontFamily.Monospace,
                    fontWeight = FontWeight.SemiBold,
                    textAlign = TextAlign.Center,
                )
                OutlinedTextField(
                    state = codeField,
                    enabled = !state.isSubmitting,
                    textStyle = codeStyle,
                    label = { Text("Code d’invitation") },
                    placeholder = {
                        Text(
                            text = JoinGroupViewModel.PLACEHOLDER,
                            style = codeStyle,
                            modifier = Modifier.fillMaxWidth(),
                        )
                    },
                    inputTransformation = InviteCodeInput,
                    outputTransformation = InviteCodeDisplay,
                    lineLimits = TextFieldLineLimits.SingleLine,
                    keyboardOptions = KeyboardOptions(
                        capitalization = KeyboardCapitalization.Characters,
                        autoCorrectEnabled = false,
                        keyboardType = KeyboardType.Ascii,
                        imeAction = ImeAction.Go,
                    ),
                    onKeyboardAction = { submit() },
                    modifier = Modifier
                        .fillMaxWidth()
                        .focusRequester(focusRequester)
                        .testTag(GroupsTags.CODE_FIELD),
                )
                Text(
                    text = "Demandez le code à un admin du groupe : 8 lettres ou chiffres, par exemple " +
                        "${JoinGroupViewModel.PLACEHOLDER}.",
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.padding(horizontal = 16.dp),
                )
            }
        }
    }

    ErrorAlert(state.error, model::dismissError)
}

/** « Bienvenue ! » / « Déjà membre », the view model's message and « Ouvrir le groupe ». */
@Composable
private fun JoinResultView(result: JoinResult, message: String, onOpen: () -> Unit) {
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .verticalScroll(rememberScrollState())
            .padding(horizontal = 24.dp, vertical = 24.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        ContentUnavailable(
            icon = Icons.Filled.CheckCircle,
            iconTint = GroupsColors.success,
            title = if (result.alreadyMember) "Déjà membre" else "Bienvenue !",
            message = message,
            messageModifier = Modifier.testTag(GroupsTags.JOIN_RESULT),
        ) {
            Button(onClick = onOpen, modifier = Modifier.testTag(GroupsTags.OPEN_GROUP)) {
                Icon(
                    Icons.AutoMirrored.Filled.ArrowForward,
                    contentDescription = null,
                    modifier = Modifier.size(ButtonDefaults.IconSize),
                )
                Text("Ouvrir le groupe", modifier = Modifier.padding(start = ButtonDefaults.IconSpacing))
            }
        }
    }
}

/**
 * Keeps what `InviteCode.normalize` keeps (letters A–Z upper-cased, digits 0–9), 8 characters at most, editing
 * character by character so that the cursor stays where the user types.
 */
private object InviteCodeInput : InputTransformation {
    override fun TextFieldBuffer.transformInput() {
        var index = 0
        while (index < length) {
            val character = charAt(index)
            val upper = character.uppercaseChar()
            if (upper in 'A'..'Z' || upper in '0'..'9') {
                if (upper != character) replace(index, index + 1, upper.toString())
                index++
            } else {
                delete(index, index + 1)
            }
        }
        if (length > InviteCode.length) delete(InviteCode.length, length)
    }
}

/** Shows the dash of `ABCD-EFGH` (display only: the field holds the 8 characters, `JoinGroupViewModel.format`). */
private object InviteCodeDisplay : OutputTransformation {
    override fun TextFieldBuffer.transformOutput() {
        val half = InviteCode.length / 2
        if (length > half) insert(half, "-")
    }
}
