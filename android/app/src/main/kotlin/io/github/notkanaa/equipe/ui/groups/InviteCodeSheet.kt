@file:OptIn(ExperimentalMaterial3Api::class)

package io.github.notkanaa.equipe.ui.groups

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicText
import androidx.compose.foundation.text.TextAutoSize
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Autorenew
import androidx.compose.material.icons.filled.Groups
import androidx.compose.material.icons.filled.Lock
import androidx.compose.material.icons.filled.Share
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import io.github.notkanaa.equipe.core.viewmodel.MembersState
import io.github.notkanaa.equipe.core.viewmodel.MembersViewModel
import io.github.notkanaa.equipe.core.viewmodel.SessionModel
import kotlinx.coroutines.launch
import java.util.UUID

// Port of App/Sources/Features/Groups/InviteCodeSheet.swift.

/**
 * « Code d’invitation » bottom sheet (admins): the code in large monospaced type (spelled out by TalkBack),
 * « Partager le code » (Android share sheet with the view model's share text), « Générer un nouveau code » (with a
 * confirmation) and the validity footer. Closes itself when the group is gone.
 */
@Composable
internal fun InviteCodeSheet(groupId: UUID, session: SessionModel, onDismiss: () -> Unit) {
    val scope = rememberCoroutineScope()
    val model = remember(session, groupId) { MembersViewModel(session, groupId, scope) }
    val state by model.state.collectAsStateWithLifecycle()
    LaunchedEffect(model) { model.autoRefresh() }

    val sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)
    var isConfirmingRegeneration by rememberSaveable { mutableStateOf(false) }
    LaunchedEffect(state.isGone) {
        if (state.isGone) {
            sheetState.hide()
            onDismiss()
        }
    }

    ModalBottomSheet(onDismissRequest = onDismiss, sheetState = sheetState, modifier = Modifier.windowTestTags()) {
        SheetHeader(
            title = "Code d’invitation",
            trailing = {
                TextButton(
                    onClick = { hideThen(scope, sheetState, onDismiss) },
                    modifier = Modifier.testTag(GroupsTags.DONE),
                ) {
                    Text("Fermer")
                }
            },
        )
        val code = state.inviteCodeText
        when {
            code != null && state.canSeeInviteCode -> InviteCodeContent(
                state = state,
                code = code,
                onRegenerate = { isConfirmingRegeneration = true },
            )
            state.isGone -> SheetPlaceholder {
                ContentUnavailable(
                    icon = Icons.Filled.Groups,
                    title = GroupsText.GONE_TITLE,
                    message = MembersViewModel.GONE_MESSAGE,
                )
            }
            state.loadState.isLoaded -> SheetPlaceholder {
                ContentUnavailable(
                    icon = Icons.Filled.Lock,
                    title = "Code réservé aux admins",
                    message = "Seuls les admins du groupe peuvent voir et partager le code d’invitation.",
                )
            }
            else -> SheetPlaceholder {
                LoadStateView(state.loadState, onRetry = { scope.launch { model.reload() } })
            }
        }
    }

    if (isConfirmingRegeneration) {
        RegenerateCodeDialog(
            confirmTag = GroupsTags.REGENERATE_CONFIRM,
            onConfirm = { session.scope.launch { model.regenerateInviteCode() } },
            onDismiss = { isConfirmingRegeneration = false },
        )
    }
    ErrorAlert(state.error, model::dismissError)
}

@Composable
private fun InviteCodeContent(state: MembersState, code: String, onRegenerate: () -> Unit) {
    val context = LocalContext.current
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .verticalScroll(rememberScrollState())
            .padding(start = 24.dp, end = 24.dp, top = 8.dp, bottom = 24.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(20.dp),
    ) {
        Text(
            text = "Partagez ce code avec les personnes à inviter dans « ${state.groupName} ». " +
                "Elles le saisiront dans « Rejoindre ».",
            style = MaterialTheme.typography.bodyMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            textAlign = TextAlign.Center,
        )
        BigInviteCode(code)
        state.shareText?.let { text ->
            Button(
                onClick = { shareText(context, text) },
                modifier = Modifier
                    .fillMaxWidth()
                    .heightIn(min = 52.dp)
                    .testTag(GroupsTags.SHARE_CODE),
            ) {
                Icon(Icons.Filled.Share, contentDescription = null, modifier = Modifier.size(ButtonDefaults.IconSize))
                Text("Partager le code", modifier = Modifier.padding(start = ButtonDefaults.IconSpacing))
            }
        }
        OutlinedButton(
            onClick = onRegenerate,
            enabled = !state.isRegeneratingCode,
            modifier = Modifier
                .fillMaxWidth()
                .heightIn(min = 52.dp)
                .testTag(GroupsTags.REGENERATE_CODE),
        ) {
            if (state.isRegeneratingCode) {
                RowSpinner(contentDescription = "Génération d’un nouveau code")
            } else {
                Icon(Icons.Filled.Autorenew, contentDescription = null, modifier = Modifier.size(ButtonDefaults.IconSize))
                Text("Générer un nouveau code", modifier = Modifier.padding(start = ButtonDefaults.IconSpacing))
            }
        }
        Text(
            text = "Le code reste valable jusqu’à ce qu’un admin en génère un nouveau.",
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            textAlign = TextAlign.Center,
        )
    }
}

/**
 * The code in 44 sp bold monospaced type on one line (shrunk to fit at large font scales), selectable, on a light
 * accent tint. TalkBack spells it out character by character.
 */
@Composable
private fun BigInviteCode(code: String) {
    SelectionContainer {
        BasicText(
            text = code,
            style = TextStyle(
                color = MaterialTheme.colorScheme.onSurface,
                fontFamily = FontFamily.Monospace,
                fontWeight = FontWeight.Bold,
                fontSize = 44.sp,
                textAlign = TextAlign.Center,
            ),
            maxLines = 1,
            softWrap = false,
            autoSize = TextAutoSize.StepBased(minFontSize = 20.sp, maxFontSize = 44.sp),
            modifier = Modifier
                .fillMaxWidth()
                .clip(RoundedCornerShape(20.dp))
                .background(MaterialTheme.colorScheme.primary.copy(alpha = 0.12f))
                .padding(horizontal = 12.dp, vertical = 20.dp)
                .testTag(GroupsTags.INVITE_CODE)
                .semantics { contentDescription = GroupsText.spelledOut(code) },
        )
    }
}

/** « Générer un nouveau code ? » (the invite sheet and the « Membres » screen). */
@Composable
internal fun RegenerateCodeDialog(confirmTag: String, onConfirm: () -> Unit, onDismiss: () -> Unit) {
    ConfirmationDialog(
        title = "Générer un nouveau code ?",
        message = "L’ancien code ne fonctionnera plus. Les membres actuels restent dans le groupe.",
        confirmLabel = "Générer un nouveau code",
        confirmTag = confirmTag,
        onConfirm = onConfirm,
        onDismiss = onDismiss,
    )
}

/** Placeholder area of a sheet (loading, reserved to admins, gone). */
@Composable
private fun SheetPlaceholder(content: @Composable () -> Unit) {
    Box(
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = 32.dp, vertical = 48.dp),
        contentAlignment = Alignment.Center,
    ) {
        content()
    }
}
