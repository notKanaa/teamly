package io.github.notkanaa.equipe.core.viewmodel

import io.github.notkanaa.equipe.core.AppError
import io.github.notkanaa.equipe.core.InputValidation
import io.github.notkanaa.equipe.core.NotificationAuthorization
import io.github.notkanaa.equipe.core.UserProfile
import io.github.notkanaa.equipe.core.logic.ReminderLeadTime
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.async
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.collectLatest
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.map
import kotlin.coroutines.cancellation.CancellationException

// Port of TeamTasksCore/ViewModels/Settings/SettingsViewModel.swift.

/** State of the « Réglages » tab. */
data class SettingsState(
    /** E-mail of the account. */
    val email: String?,
    /** Reminder lead time (persisted). */
    val leadTime: ReminderLeadTime,
    val profile: UserProfile? = null,
    /** Editable display name (filled by the first load). */
    val displayName: String = "",
    val displayNameError: String? = null,
    val isSavingName: Boolean = false,
    /** The ntfy topic when push is enabled. */
    val pushTopic: String? = null,
    val isUpdatingPush: Boolean = false,
    /** null until loaded. */
    val notificationStatus: NotificationAuthorization? = null,
    /** What the user typed in the deletion confirmation field. */
    val deleteConfirmation: String = "",
    val isSigningOut: Boolean = false,
    val isDeletingAccount: Boolean = false,
    val loadState: LoadState = LoadState.Idle,
    override val error: ErrorState? = null,
) : ErrorHolder {
    val canSaveDisplayName: Boolean
        get() {
            val trimmed = InputValidation.trimmed(displayName)
            return trimmed.isNotEmpty() && trimmed != profile?.displayName && !isSavingName
        }

    val leadTimeOptions: List<ReminderLeadTime> get() = ReminderLeadTime.entries.toList()

    val isPushEnabled: Boolean get() = pushTopic != null

    /** Web address of the topic (also what the ntfy app subscribes to), e.g. `https://ntfy.sh/equipe-…`. */
    val pushTopicUrl: String? get() = pushTopic?.let { "${SettingsViewModel.NTFY_SERVER}/$it" }

    /** Opens (subscribes to) the topic in the ntfy app when installed: `ntfy://ntfy.sh/<topic>`. */
    val ntfyAppUrl: String? get() = pushTopic?.let { "ntfy://ntfy.sh/$it" }

    /** « Activées », « Refusées », « Pas encore demandées », « … » (not loaded). */
    val notificationStatusText: String
        get() = when (notificationStatus) {
            NotificationAuthorization.AUTHORIZED -> "Activées"
            NotificationAuthorization.DENIED -> "Refusées"
            NotificationAuthorization.NOT_DETERMINED -> "Pas encore demandées"
            null -> "…"
        }

    /** Shown when refused (the permission can only be changed in the system settings) or not yet asked. */
    val notificationHint: String?
        get() = when (notificationStatus) {
            NotificationAuthorization.DENIED ->
                "Pour recevoir les rappels et les nouvelles tâches, autorisez les notifications d’Équipe dans les " +
                    "Paramètres du téléphone."
            NotificationAuthorization.NOT_DETERMINED ->
                "Autorisez les notifications pour recevoir les rappels d’échéance et les nouvelles tâches."
            NotificationAuthorization.AUTHORIZED, null -> null
        }

    val canRequestNotifications: Boolean get() = notificationStatus == NotificationAuthorization.NOT_DETERMINED

    /** True once « SUPPRIMER » is typed exactly. */
    val canDeleteAccount: Boolean
        get() = deleteConfirmation == SettingsViewModel.DELETE_CONFIRMATION_WORD && !isDeletingAccount
}

/**
 * « Réglages » tab: display name, reminder lead time, optional ntfy push, notification permission, sign-out and account
 * deletion (only after typing « SUPPRIMER »).
 *
 * Screen: `LaunchedEffect(model) { model.autoRefresh() }`. Sign-out and deletion end the session through
 * `AuthService.authStates()`: `AppModel` then shows the login screen.
 */
class SettingsViewModel(
    val session: SessionModel,
    scope: CoroutineScope,
) : ScreenModel<SettingsState>(
    SettingsState(email = session.user.email, leadTime = ReminderLeadTime.load(session.platform.store)),
    { state, error -> state.copy(error = error) },
) {
    private val runner = LoadRunner(scope)
    private val background = BackgroundWork(scope)
    private var loadedRevision: Int? = null
    private var fetchingRevision: Int? = null

    /** Editable display name. */
    var displayName: String
        get() = current.displayName
        set(value) = update {
            it.copy(
                displayName = value,
                displayNameError = if (it.displayNameError != null) SignUpViewModel.displayNameMessage(value) else null,
            )
        }

    /** What the user typed in the deletion confirmation field. */
    var deleteConfirmation: String
        get() = current.deleteConfirmation
        set(value) = update { it.copy(deleteConfirmation = value) }

    /** Picker binding: persists the choice and resynchronizes the reminders in the background. */
    var leadTime: ReminderLeadTime
        get() = current.leadTime
        set(value) {
            if (value == current.leadTime) return
            store(value)
            background.start { session.synchronizeReminders() }
        }

    // region Loading

    /** Changes when the profile may have changed on another device (a display-name update is a memberships signal). */
    val refreshKey: RefreshKey get() = RefreshKey(session.feed.membershipsRevision.value)

    /** [refreshKey] as a flow: the current value first, then every change. */
    val refreshKeys: Flow<RefreshKey> = session.feed.membershipsRevision.map { RefreshKey(it) }.distinctUntilChanged()

    val needsRefresh: Boolean
        get() = current.loadState != LoadState.Loaded || loadedRevision != refreshKey.revision

    suspend fun load() {
        if (!needsRefresh) return
        val upToDate = runner.isRunning && fetchingRevision == refreshKey.revision
        runner.run(rerunIfRunning = !upToDate) { fetch() }
    }

    suspend fun reload() {
        runner.run(rerunIfRunning = true) { fetch() }
    }

    /** Loads now, then again whenever [refreshKey] changes. Never returns: run it in a `LaunchedEffect`. */
    suspend fun autoRefresh() {
        refreshKeys.collectLatest { load() }
    }

    private suspend fun fetch() {
        val revision = refreshKey.revision
        fetchingRevision = revision
        try {
            update { it.copy(loadState = startedLoad(it.loadState)) }
            val status = session.platform.notifications.authorizationStatus()
            update { it.copy(notificationStatus = status) }
            val profiles = session.services.profiles
            val push = session.services.push
            val (profile, topic) = coroutineScope {
                val profileRequest = async { profiles.myProfile() }
                val topicRequest = async { push.currentTopic() }
                profileRequest.await() to topicRequest.await()
            }
            loadedRevision = revision
            update {
                // Keep a name being edited; follow the server otherwise.
                val keepEdited = it.profile != null && it.displayName != it.profile.displayName
                it.copy(
                    displayName = if (keepEdited) it.displayName else profile.displayName,
                    profile = profile,
                    pushTopic = topic,
                    email = session.user.email,
                    loadState = LoadState.Loaded,
                )
            }
        } catch (error: CancellationException) {
            update { it.copy(loadState = cancelledLoad(it.loadState)) }
            throw error
        } catch (error: Exception) {
            update {
                val failure = loadFailure(it.loadState, it.error, error)
                it.copy(loadState = failure.loadState, error = failure.error)
            }
        } finally {
            fetchingRevision = null
        }
    }

    // endregion

    // region Display name

    suspend fun saveDisplayName(): Boolean {
        if (current.isSavingName) return false
        dismissError()
        val message = SignUpViewModel.displayNameMessage(current.displayName)
        update { it.copy(displayNameError = message) }
        if (message != null) return false
        update { it.copy(isSavingName = true) }
        try {
            val updated = session.services.profiles.updateDisplayName(current.displayName)
            update { it.copy(profile = updated, displayName = updated.displayName) }
            // Names appear on every group screen.
            session.feed.bumpAll()
            return true
        } catch (error: CancellationException) {
            throw error
        } catch (error: Exception) {
            if (present(error) == AppError.InvalidDisplayName) {
                update { it.copy(displayNameError = AppError.InvalidDisplayName.messageFR, error = null) }
            }
            return false
        } finally {
            update { it.copy(isSavingName = false) }
        }
    }

    // endregion

    // region Reminders

    /**
     * Persists the lead time and resynchronizes the reminders (awaited). Returns false when « Mes tâches » could not be
     * loaded (the reminders then keep their previous schedule until the next synchronization).
     */
    suspend fun setLeadTime(value: ReminderLeadTime): Boolean {
        store(value)
        return session.synchronizeReminders()
    }

    private fun store(value: ReminderLeadTime) {
        update { it.copy(leadTime = value) }
        value.save(session.platform.store)
    }

    /** Waits for the background work started by the [leadTime] setter (tests). */
    internal suspend fun waitForBackgroundWork() {
        background.waitForAll()
    }

    // endregion

    // region Push (ntfy)

    suspend fun enablePush(): Boolean {
        if (current.isUpdatingPush) return false
        update { it.copy(error = null, isUpdatingPush = true) }
        try {
            val topic = session.services.push.enable()
            update { it.copy(pushTopic = topic) }
            return true
        } catch (error: CancellationException) {
            throw error
        } catch (error: Exception) {
            present(error)
            return false
        } finally {
            update { it.copy(isUpdatingPush = false) }
        }
    }

    suspend fun disablePush(): Boolean {
        if (current.isUpdatingPush) return false
        update { it.copy(error = null, isUpdatingPush = true) }
        try {
            session.services.push.disable()
            update { it.copy(pushTopic = null) }
            return true
        } catch (error: CancellationException) {
            throw error
        } catch (error: Exception) {
            present(error)
            return false
        } finally {
            update { it.copy(isUpdatingPush = false) }
        }
    }

    /** Switch helper. */
    suspend fun setPushEnabled(enabled: Boolean): Boolean = if (enabled) enablePush() else disablePush()

    // endregion

    // region Notification permission

    suspend fun refreshNotificationStatus() {
        val status = session.platform.notifications.authorizationStatus()
        update { it.copy(notificationStatus = status) }
    }

    /** Asks the system for the permission (only possible once); when granted, reminders and catch-up run. */
    suspend fun requestNotifications(): Boolean {
        val status = session.requestNotificationAuthorizationIfNeeded()
        update { it.copy(notificationStatus = status) }
        return status == NotificationAuthorization.AUTHORIZED
    }

    // endregion

    // region Session

    suspend fun signOut(): Boolean {
        if (current.isSigningOut) return false
        update { it.copy(error = null, isSigningOut = true) }
        try {
            session.services.auth.signOut()
            return true
        } catch (error: CancellationException) {
            throw error
        } catch (error: Exception) {
            present(error)
            return false
        } finally {
            update { it.copy(isSigningOut = false) }
        }
    }

    /** Deletes the account (only when « SUPPRIMER » was typed exactly). */
    suspend fun deleteAccount(): Boolean {
        if (current.deleteConfirmation != DELETE_CONFIRMATION_WORD) {
            present(DELETE_CONFIRMATION_REQUIRED_MESSAGE, AppError.InvalidInput)
            return false
        }
        if (current.isDeletingAccount) return false
        update { it.copy(error = null, isDeletingAccount = true) }
        try {
            session.services.auth.deleteAccount()
            session.platform.store.set(MyTasksViewModel.lastSeenKey(session.userId), null)
            update { it.copy(deleteConfirmation = "") }
            return true
        } catch (error: CancellationException) {
            throw error
        } catch (error: Exception) {
            present(error)
            return false
        } finally {
            update { it.copy(isDeletingAccount = false) }
        }
    }

    // endregion

    companion object {
        const val DELETE_CONFIRMATION_WORD: String = "SUPPRIMER"

        const val DELETE_CONFIRMATION_REQUIRED_MESSAGE: String = "Tapez « SUPPRIMER » pour confirmer."

        const val DELETE_ACCOUNT_WARNING: String =
            "Votre compte, votre profil et vos assignations seront supprimés définitivement. Les groupes dont vous " +
                "êtes le seul membre seront supprimés avec leurs tâches ; dans les autres, le membre le plus ancien " +
                "deviendra admin si vous étiez le seul admin. Tapez « SUPPRIMER » pour confirmer."

        const val NTFY_SERVER: String = "https://ntfy.sh"

        /** Google Play page of the free ntfy app (Android addition). */
        const val NTFY_PLAY_STORE_URL: String = "https://play.google.com/store/apps/details?id=io.heckel.ntfy"

        /** Steps shown when push is enabled (the first one names the Android store instead of the App Store). */
        val PUSH_INSTRUCTION_STEPS: List<String> = listOf(
            "Installez l’application gratuite « ntfy » depuis le Play Store (ou F-Droid).",
            "Dans ntfy, touchez « + » puis abonnez-vous au sujet ci-dessous (serveur ntfy.sh).",
            "Une notification vous prévient quand une tâche vous est assignée, même quand Équipe est fermée.",
        )

        const val PUSH_PRIVACY_NOTE: String =
            "Gardez ce sujet secret : toute personne qui le connaît peut voir quand une tâche vous est assignée " +
                "(le titre de la tâche n’est jamais envoyé)."

        const val PUSH_DISABLED_EXPLANATION: String =
            "Recevez une notification quand une tâche vous est assignée, même quand Équipe est fermée, grâce à " +
                "l’application gratuite ntfy."
    }
}
