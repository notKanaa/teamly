package io.github.notkanaa.equipe.ui.settings

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.consumeWindowInsets
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.Logout
import androidx.compose.material.icons.automirrored.filled.OpenInNew
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material.icons.filled.Warning
import androidx.compose.material.icons.outlined.Alarm
import androidx.compose.material.icons.outlined.CloudOff
import androidx.compose.material.icons.outlined.ContentCopy
import androidx.compose.material.icons.outlined.Delete
import androidx.compose.material.icons.outlined.Download
import androidx.compose.material.icons.outlined.Notifications
import androidx.compose.material.icons.outlined.NotificationsActive
import androidx.compose.material.icons.outlined.NotificationsOff
import androidx.compose.material.icons.outlined.Save
import androidx.compose.material.icons.outlined.Settings
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.LargeTopAppBar
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TextField
import androidx.compose.material3.TextFieldDefaults
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.material3.pulltorefresh.PullToRefreshBox
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
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.input.nestedscroll.nestedScroll
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardCapitalization
import androidx.compose.ui.unit.dp
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.compose.LifecycleEventEffect
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import io.github.notkanaa.equipe.BuildConfig
import io.github.notkanaa.equipe.core.NotificationAuthorization
import io.github.notkanaa.equipe.core.viewmodel.LoadState
import io.github.notkanaa.equipe.core.viewmodel.SessionModel
import io.github.notkanaa.equipe.core.viewmodel.SettingsState
import io.github.notkanaa.equipe.core.viewmodel.SettingsViewModel
import io.github.notkanaa.equipe.ui.shell.ShellErrorDialog
import io.github.notkanaa.equipe.ui.shell.StepNumber
import io.github.notkanaa.equipe.ui.shell.exposeTestTags
import io.github.notkanaa.equipe.ui.shell.rememberBoundText
import io.github.notkanaa.equipe.ui.theme.extendedColors
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

/** Test tags of « Réglages » (same identifiers as iOS `AccessibilityID.Settings`). */
object SettingsTestTags {
    const val SIGN_OUT: String = "settings.signOut"
    const val DELETE_ACCOUNT: String = "settings.deleteAccount"

    /** Shown when the profile could not be loaded (the rest of the screen stays usable). */
    const val RETRY: String = "settings.retry"
    const val EMAIL: String = "settings.email"
    const val DISPLAY_NAME_FIELD: String = "settings.displayName"
    const val SAVE_DISPLAY_NAME: String = "settings.saveDisplayName"

    /** The lead time row; its options are `settings.leadTime.<rawValue>` (e.g. `settings.leadTime.oneDay`). */
    const val LEAD_TIME_PICKER: String = "settings.leadTime"
    const val NOTIFICATION_STATUS: String = "settings.notificationStatus"
    const val REQUEST_NOTIFICATIONS: String = "settings.requestNotifications"
    const val OPEN_SYSTEM_SETTINGS: String = "settings.openSystemSettings"
    const val ENABLE_PUSH: String = "settings.enablePush"
    const val DISABLE_PUSH: String = "settings.disablePush"
    const val CONFIRM_DISABLE_PUSH: String = "settings.confirmDisablePush"
    const val PUSH_TOPIC: String = "settings.pushTopic"
    const val COPY_PUSH_TOPIC: String = "settings.copyPushTopic"
    const val OPEN_NTFY: String = "settings.openNtfy"
    const val INSTALL_NTFY: String = "settings.installNtfy"

    /** Confirmation dialog button of « Se déconnecter ». */
    const val CONFIRM_SIGN_OUT: String = "settings.confirmSignOut"

    /** « Supprimer le compte » dialog: typed « SUPPRIMER » field, final button and cancel. */
    const val DELETE_CONFIRMATION_FIELD: String = "settings.deleteConfirmation"
    const val CONFIRM_DELETE_ACCOUNT: String = "settings.confirmDeleteAccount"
    const val CANCEL_DELETE_ACCOUNT: String = "settings.cancelDeleteAccount"
    const val VERSION: String = "settings.version"
}

/**
 * « Réglages » (iOS `SettingsView`): profile (display name), reminder lead time, notification permission, optional
 * ntfy push, sign-out and account deletion. Sign-out and deletion end the session: `AppModel` then shows the login
 * screen. Sections that do not need the profile stay usable when it cannot be loaded, so that signing out always
 * works.
 *
 * @param actionScope where the changes run (the app's scope): they complete even if the tab is left meanwhile.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun SettingsScreen(session: SessionModel, actionScope: CoroutineScope) {
    val scope = rememberCoroutineScope()
    val model = remember(session) { SettingsViewModel(session, scope) }
    val state by model.state.collectAsStateWithLifecycle()
    val context = LocalContext.current

    var isConfirmingSignOut by rememberSaveable { mutableStateOf(false) }
    var isConfirmingPushDisable by rememberSaveable { mutableStateOf(false) }
    var isShowingDeleteAccount by rememberSaveable { mutableStateOf(false) }
    var isRefreshing by remember { mutableStateOf(false) }

    LaunchedEffect(model) { model.autoRefresh() }
    // The permission may have been changed in the system settings meanwhile.
    LifecycleEventEffect(Lifecycle.Event.ON_RESUME) {
        scope.launch { model.refreshNotificationStatus() }
    }

    val scrollBehavior = TopAppBarDefaults.exitUntilCollapsedScrollBehavior()
    Scaffold(
        containerColor = MaterialTheme.colorScheme.background,
        topBar = {
            LargeTopAppBar(
                title = { Text("Réglages") },
                scrollBehavior = scrollBehavior,
                colors = TopAppBarDefaults.topAppBarColors(containerColor = MaterialTheme.colorScheme.background),
            )
        },
    ) { padding ->
        PullToRefreshBox(
            isRefreshing = isRefreshing,
            onRefresh = {
                scope.launch {
                    isRefreshing = true
                    try {
                        model.reload()
                    } finally {
                        isRefreshing = false
                    }
                }
            },
            modifier = Modifier
                .padding(padding)
                .consumeWindowInsets(padding),
        ) {
            Column(
                modifier = Modifier
                    .fillMaxSize()
                    // Nearer than the pull-to-refresh: pulling down first expands the large title.
                    .nestedScroll(scrollBehavior.nestedScrollConnection)
                    .verticalScroll(rememberScrollState())
                    .imePadding()
                    .padding(top = 8.dp, bottom = 32.dp),
                verticalArrangement = Arrangement.spacedBy(28.dp),
            ) {
                state.loadState.failureMessage?.let { message ->
                    LoadFailedSection(message, onRetry = { scope.launch { model.reload() } })
                }
                ProfileSection(model, state, actionScope)
                RemindersSection(model, state, actionScope)
                NotificationsSection(
                    state = state,
                    onRequest = { actionScope.launch { model.requestNotifications() } },
                    onOpenSystemSettings = { SettingsActions.openNotificationSettings(context) },
                )
                PushSection(
                    state = state,
                    onEnable = { actionScope.launch { model.enablePush() } },
                    onDisable = { isConfirmingPushDisable = true },
                )
                AccountSection(
                    state = state,
                    onSignOut = { isConfirmingSignOut = true },
                    onDeleteAccount = {
                        model.deleteConfirmation = ""
                        isShowingDeleteAccount = true
                    },
                )
                AboutSection()
            }
        }
    }

    if (isConfirmingSignOut) {
        ConfirmationDialog(
            title = "Se déconnecter ?",
            message = "Les rappels programmés sur cet appareil seront supprimés. Vous pourrez vous reconnecter à " +
                "tout moment.",
            confirmLabel = "Se déconnecter",
            confirmTestTag = SettingsTestTags.CONFIRM_SIGN_OUT,
            onConfirm = {
                isConfirmingSignOut = false
                actionScope.launch { model.signOut() }
            },
            onDismiss = { isConfirmingSignOut = false },
        )
    }

    if (isConfirmingPushDisable) {
        ConfirmationDialog(
            title = "Désactiver les notifications push ?",
            message = "Votre sujet ntfy sera supprimé. Si vous les réactivez, il faudra vous abonner au nouveau " +
                "sujet dans ntfy.",
            confirmLabel = "Désactiver",
            confirmTestTag = SettingsTestTags.CONFIRM_DISABLE_PUSH,
            onConfirm = {
                isConfirmingPushDisable = false
                actionScope.launch { model.disablePush() }
            },
            onDismiss = { isConfirmingPushDisable = false },
        )
    }

    if (isShowingDeleteAccount) {
        DeleteAccountDialog(
            model = model,
            state = state,
            onDelete = { actionScope.launch { model.deleteAccount() } },
            onClose = {
                model.deleteConfirmation = ""
                model.dismissError()
                isShowingDeleteAccount = false
            },
        )
    } else {
        state.error?.let { error ->
            ShellErrorDialog(message = error.message, onDismiss = model::dismissError)
        }
    }
}

// region Sections

@Composable
private fun LoadFailedSection(message: String, onRetry: () -> Unit) {
    SettingsSection(header = null) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(16.dp)
                .semantics(mergeDescendants = true) {},
            horizontalArrangement = Arrangement.spacedBy(16.dp),
        ) {
            Icon(Icons.Outlined.CloudOff, contentDescription = null, tint = MaterialTheme.colorScheme.onSurfaceVariant)
            Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
                Text("Profil indisponible", style = MaterialTheme.typography.titleMedium)
                Text(
                    text = message,
                    style = MaterialTheme.typography.bodyMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
        }
        SettingsDivider()
        SettingsActionRow(
            label = "Réessayer",
            icon = Icons.Filled.Refresh,
            onClick = onRetry,
            modifier = Modifier.testTag(SettingsTestTags.RETRY),
        )
    }
}

@Composable
private fun ProfileSection(model: SettingsViewModel, state: SettingsState, actionScope: CoroutineScope) {
    val focusManager = LocalFocusManager.current
    val displayName = rememberBoundText(model, state.displayName, { model.displayName }, { model.displayName = it })

    fun saveDisplayName() {
        if (!model.state.value.canSaveDisplayName) return
        focusManager.clearFocus()
        actionScope.launch { model.saveDisplayName() }
    }

    val nameError = state.displayNameError
    SettingsSection(
        header = "Profil",
        footer = nameError ?: "Votre nom est visible par les membres de vos groupes.",
        footerColor = if (nameError != null) MaterialTheme.colorScheme.error else Color.Unspecified,
    ) {
        SettingsValueRow(
            label = "E-mail",
            value = state.email ?: "—",
            selectable = true,
            modifier = Modifier.testTag(SettingsTestTags.EMAIL),
        )
        SettingsDivider()
        if (state.profile == null) {
            SettingsLabelRow(label = "Nom affiché") {
                if (state.loadState == LoadState.Loading || state.loadState == LoadState.Idle) {
                    CircularProgressIndicator(
                        modifier = Modifier
                            .size(20.dp)
                            .semantics { contentDescription = "Chargement" },
                        strokeWidth = 2.dp,
                    )
                } else {
                    Text("—", color = MaterialTheme.colorScheme.onSurfaceVariant)
                }
            }
        } else {
            val cardColor = MaterialTheme.extendedColors.card
            TextField(
                value = displayName.value,
                onValueChange = displayName::onValueChange,
                label = { Text("Nom affiché") },
                isError = nameError != null,
                singleLine = true,
                keyboardOptions = KeyboardOptions(
                    capitalization = KeyboardCapitalization.Words,
                    imeAction = ImeAction.Done,
                ),
                keyboardActions = KeyboardActions(onDone = { saveDisplayName() }),
                colors = TextFieldDefaults.colors(
                    focusedContainerColor = cardColor,
                    unfocusedContainerColor = cardColor,
                    errorContainerColor = cardColor,
                    disabledContainerColor = cardColor,
                    focusedIndicatorColor = Color.Transparent,
                    unfocusedIndicatorColor = Color.Transparent,
                    errorIndicatorColor = Color.Transparent,
                    disabledIndicatorColor = Color.Transparent,
                ),
                modifier = Modifier
                    .fillMaxWidth()
                    .testTag(SettingsTestTags.DISPLAY_NAME_FIELD),
            )
            if (state.canSaveDisplayName || state.isSavingName) {
                SettingsDivider()
                SettingsActionRow(
                    label = "Enregistrer le nom",
                    icon = Icons.Outlined.Save,
                    onClick = ::saveDisplayName,
                    enabled = state.canSaveDisplayName,
                    isLoading = state.isSavingName,
                    modifier = Modifier.testTag(SettingsTestTags.SAVE_DISPLAY_NAME),
                )
            }
        }
    }
}

@Composable
private fun RemindersSection(model: SettingsViewModel, state: SettingsState, actionScope: CoroutineScope) {
    SettingsSection(header = "Rappels d’échéance", footer = remindersFooter(state)) {
        SettingsPickerRow(
            label = "Rappel",
            icon = Icons.Outlined.Alarm,
            selected = state.leadTime,
            options = state.leadTimeOptions,
            optionLabel = { it.label },
            optionKey = { it.rawValue },
            // Persists the choice at once, then synchronizes the reminders (completes even if the tab is left).
            onSelect = { choice -> actionScope.launch { model.setLeadTime(choice) } },
            testTag = SettingsTestTags.LEAD_TIME_PICKER,
        )
    }
}

private fun remindersFooter(state: SettingsState): String {
    if (!state.leadTime.isEnabled) return "Aucun rappel d’échéance ne sera programmé sur cet appareil."
    val base = "Pour chaque tâche qui vous est assignée et qui a une échéance, un rappel est programmé sur cet " +
        "appareil."
    return if (state.notificationStatus == NotificationAuthorization.DENIED) {
        "$base Les notifications étant refusées, les rappels ne s’afficheront pas."
    } else {
        base
    }
}

@Composable
private fun NotificationsSection(state: SettingsState, onRequest: () -> Unit, onOpenSystemSettings: () -> Unit) {
    SettingsSection(header = "Notifications", footer = state.notificationHint) {
        SettingsValueRow(
            label = "Autorisation",
            value = state.notificationStatusText,
            icon = Icons.Outlined.Notifications,
            modifier = Modifier.testTag(SettingsTestTags.NOTIFICATION_STATUS),
        )
        if (state.canRequestNotifications) {
            SettingsDivider()
            SettingsActionRow(
                label = "Autoriser les notifications",
                icon = Icons.Outlined.NotificationsActive,
                onClick = onRequest,
                modifier = Modifier.testTag(SettingsTestTags.REQUEST_NOTIFICATIONS),
            )
        } else if (state.notificationStatus == NotificationAuthorization.DENIED) {
            SettingsDivider()
            SettingsActionRow(
                label = "Ouvrir les paramètres de notification",
                icon = Icons.Outlined.Settings,
                onClick = onOpenSystemSettings,
                modifier = Modifier.testTag(SettingsTestTags.OPEN_SYSTEM_SETTINGS),
            )
        }
    }
}

@Composable
private fun PushSection(state: SettingsState, onEnable: () -> Unit, onDisable: () -> Unit) {
    val context = LocalContext.current
    var didCopyTopic by remember { mutableStateOf(false) }
    LaunchedEffect(didCopyTopic) {
        if (didCopyTopic) {
            delay(2_000)
            didCopyTopic = false
        }
    }

    val topic = state.pushTopic
    SettingsSection(
        header = "Notifications push (ntfy)",
        footer = if (state.isPushEnabled) {
            SettingsViewModel.PUSH_PRIVACY_NOTE
        } else {
            SettingsViewModel.PUSH_DISABLED_EXPLANATION
        },
    ) {
        if (topic == null) {
            SettingsActionRow(
                label = "Activer les notifications push",
                icon = Icons.Outlined.NotificationsActive,
                onClick = onEnable,
                enabled = !state.isUpdatingPush && state.loadState.isLoaded,
                isLoading = state.isUpdatingPush,
                modifier = Modifier.testTag(SettingsTestTags.ENABLE_PUSH),
            )
        } else {
            EnabledPushRows(
                state = state,
                topic = topic,
                didCopyTopic = didCopyTopic,
                onCopy = {
                    SettingsActions.copySensitive(context, "Sujet ntfy", topic)
                    didCopyTopic = true
                },
                onDisable = onDisable,
            )
        }
    }
}

/** Push enabled: how to subscribe in ntfy, the topic, and the actions on it. */
@Composable
private fun EnabledPushRows(
    state: SettingsState,
    topic: String,
    didCopyTopic: Boolean,
    onCopy: () -> Unit,
    onDisable: () -> Unit,
) {
    val context = LocalContext.current
    Column {
        SettingsViewModel.PUSH_INSTRUCTION_STEPS.forEachIndexed { index, step ->
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(horizontal = 16.dp, vertical = 12.dp)
                    .semantics(mergeDescendants = true) {},
                horizontalArrangement = Arrangement.spacedBy(16.dp),
            ) {
                StepNumber(index + 1)
                Text(step, style = MaterialTheme.typography.bodyLarge)
            }
            SettingsDivider()
        }

        Column(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 16.dp, vertical = 12.dp)
                .testTag(SettingsTestTags.PUSH_TOPIC),
            verticalArrangement = Arrangement.spacedBy(4.dp),
        ) {
            Text(
                text = "Votre sujet ntfy",
                style = MaterialTheme.typography.labelMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
            SelectionContainer {
                Text(
                    text = topic,
                    style = MaterialTheme.typography.bodyLarge.copy(fontFamily = FontFamily.Monospace),
                    // Spelled out character by character by TalkBack, to be typed elsewhere.
                    modifier = Modifier.semantics { contentDescription = topic.toList().joinToString(" ") },
                )
            }
        }
        SettingsDivider()
        SettingsActionRow(
            label = if (didCopyTopic) "Sujet copié" else "Copier le sujet",
            icon = if (didCopyTopic) Icons.Filled.Check else Icons.Outlined.ContentCopy,
            onClick = onCopy,
            modifier = Modifier.testTag(SettingsTestTags.COPY_PUSH_TOPIC),
        )
        state.ntfyAppUrl?.let { appUrl ->
            SettingsDivider()
            SettingsActionRow(
                label = "Ouvrir dans ntfy",
                icon = Icons.AutoMirrored.Filled.OpenInNew,
                onClick = { SettingsActions.openNtfy(context, appUrl) },
                modifier = Modifier.testTag(SettingsTestTags.OPEN_NTFY),
            )
        }
        SettingsDivider()
        SettingsActionRow(
            label = "Installer ntfy (Play Store)",
            icon = Icons.Outlined.Download,
            onClick = { SettingsActions.openNtfyStorePage(context) },
            modifier = Modifier.testTag(SettingsTestTags.INSTALL_NTFY),
        )
        SettingsDivider()
        SettingsActionRow(
            label = "Désactiver les notifications push",
            icon = Icons.Outlined.NotificationsOff,
            onClick = onDisable,
            enabled = !state.isUpdatingPush,
            destructive = true,
            isLoading = state.isUpdatingPush,
            modifier = Modifier.testTag(SettingsTestTags.DISABLE_PUSH),
        )
    }
}

@Composable
private fun AccountSection(state: SettingsState, onSignOut: () -> Unit, onDeleteAccount: () -> Unit) {
    val isBusy = state.isSigningOut || state.isDeletingAccount
    SettingsSection(
        header = "Compte",
        footer = "La suppression du compte efface définitivement votre profil et vos assignations.",
    ) {
        SettingsActionRow(
            label = "Se déconnecter",
            icon = Icons.AutoMirrored.Filled.Logout,
            onClick = onSignOut,
            enabled = !isBusy,
            isLoading = state.isSigningOut,
            modifier = Modifier.testTag(SettingsTestTags.SIGN_OUT),
        )
        SettingsDivider()
        SettingsActionRow(
            label = "Supprimer mon compte",
            icon = Icons.Outlined.Delete,
            onClick = onDeleteAccount,
            enabled = !isBusy,
            destructive = true,
            modifier = Modifier.testTag(SettingsTestTags.DELETE_ACCOUNT),
        )
    }
}

@Composable
private fun AboutSection() {
    SettingsSection(header = null, footer = "Équipe — les tâches de votre groupe.") {
        SettingsValueRow(
            label = "Version",
            value = "${BuildConfig.VERSION_NAME} (${BuildConfig.VERSION_CODE})",
            modifier = Modifier.testTag(SettingsTestTags.VERSION),
        )
    }
}

// endregion

// region Dialogs

@Composable
private fun ConfirmationDialog(
    title: String,
    message: String,
    confirmLabel: String,
    confirmTestTag: String,
    onConfirm: () -> Unit,
    onDismiss: () -> Unit,
) {
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(title) },
        text = { Text(message) },
        confirmButton = {
            TextButton(
                onClick = onConfirm,
                colors = ButtonDefaults.textButtonColors(contentColor = MaterialTheme.colorScheme.error),
                modifier = Modifier
                    .exposeTestTags()
                    .testTag(confirmTestTag),
            ) {
                Text(confirmLabel)
            }
        },
        dismissButton = {
            TextButton(onClick = onDismiss) {
                Text("Annuler")
            }
        },
    )
}

/**
 * « Supprimer le compte » (iOS `SettingsDeleteAccountView`): explains what is deleted and requires typing
 * « SUPPRIMER ». Shows the errors of the deletion itself. On success the session ends and the login screen replaces
 * the app.
 */
@Composable
private fun DeleteAccountDialog(
    model: SettingsViewModel,
    state: SettingsState,
    onDelete: () -> Unit,
    onClose: () -> Unit,
) {
    val confirmation = rememberBoundText(
        model,
        state.deleteConfirmation,
        { model.deleteConfirmation },
        { model.deleteConfirmation = it },
    )
    val word = SettingsViewModel.DELETE_CONFIRMATION_WORD

    fun delete() {
        if (model.state.value.canDeleteAccount) onDelete()
    }

    AlertDialog(
        onDismissRequest = { if (!state.isDeletingAccount) onClose() },
        icon = { Icon(Icons.Filled.Warning, contentDescription = null, tint = MaterialTheme.colorScheme.error) },
        title = { Text("Supprimer le compte") },
        text = {
            Column(
                modifier = Modifier
                    .exposeTestTags()
                    .verticalScroll(rememberScrollState()),
                verticalArrangement = Arrangement.spacedBy(16.dp),
            ) {
                Text(SettingsViewModel.DELETE_ACCOUNT_WARNING, style = MaterialTheme.typography.bodyMedium)
                TextField(
                    value = confirmation.value,
                    onValueChange = confirmation::onValueChange,
                    label = { Text("Confirmation") },
                    placeholder = { Text(word) },
                    singleLine = true,
                    enabled = !state.isDeletingAccount,
                    keyboardOptions = KeyboardOptions(
                        capitalization = KeyboardCapitalization.Characters,
                        autoCorrectEnabled = false,
                        imeAction = ImeAction.Done,
                    ),
                    keyboardActions = KeyboardActions(onDone = { delete() }),
                    modifier = Modifier
                        .fillMaxWidth()
                        .testTag(SettingsTestTags.DELETE_CONFIRMATION_FIELD)
                        .semantics { contentDescription = "Tapez $word pour confirmer" },
                )
                Text(
                    text = "Tapez « $word » en majuscules pour confirmer.",
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
                state.error?.let { error ->
                    Row(
                        horizontalArrangement = Arrangement.spacedBy(8.dp),
                        verticalAlignment = Alignment.Top,
                    ) {
                        Icon(
                            imageVector = Icons.Filled.Warning,
                            contentDescription = null,
                            tint = MaterialTheme.colorScheme.error,
                            modifier = Modifier.size(18.dp),
                        )
                        Text(
                            text = error.message,
                            style = MaterialTheme.typography.bodyMedium,
                            color = MaterialTheme.colorScheme.error,
                        )
                    }
                }
            }
        },
        confirmButton = {
            TextButton(
                onClick = ::delete,
                enabled = state.canDeleteAccount,
                colors = ButtonDefaults.textButtonColors(contentColor = MaterialTheme.colorScheme.error),
                modifier = Modifier
                    .exposeTestTags()
                    .testTag(SettingsTestTags.CONFIRM_DELETE_ACCOUNT),
            ) {
                if (state.isDeletingAccount) {
                    CircularProgressIndicator(
                        modifier = Modifier
                            .size(18.dp)
                            .clearAndSetSemantics { contentDescription = "Suppression en cours" },
                        strokeWidth = 2.dp,
                        color = MaterialTheme.colorScheme.error,
                    )
                } else {
                    Text("Supprimer définitivement mon compte", fontWeight = FontWeight.SemiBold)
                }
            }
        },
        dismissButton = {
            TextButton(
                onClick = onClose,
                enabled = !state.isDeletingAccount,
                modifier = Modifier
                    .exposeTestTags()
                    .testTag(SettingsTestTags.CANCEL_DELETE_ACCOUNT),
            ) {
                Text("Annuler")
            }
        },
    )
}

// endregion
