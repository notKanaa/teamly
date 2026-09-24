package io.github.notkanaa.equipe.core.viewmodel

import io.github.notkanaa.equipe.core.AppServices
import io.github.notkanaa.equipe.core.AuthState
import io.github.notkanaa.equipe.core.AuthUser
import io.github.notkanaa.equipe.core.PlatformServices
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlin.coroutines.cancellation.CancellationException

// Port of TeamTasksCore/ViewModels/App/AppModel.swift.

/** What the root screen shows. */
sealed interface AppPhase {
    /** The stored session is being restored (splash screen). */
    data object Launching : AppPhase

    /** Authentication screens (login, sign-up, « Mot de passe oublié »). */
    data object SignedOut : AppPhase

    /** The signed-in app (tabs) for this session (equality: same session instance). */
    data class SignedIn(override val session: SessionModel) : AppPhase

    /**
     * A recovery code was verified (the user is technically signed in) but the new password is not set yet: show this
     * view model's « Nouveau mot de passe » step, full screen.
     */
    data class PasswordRecovery(val model: PasswordResetViewModel) : AppPhase

    /** The session of [SignedIn], null otherwise. */
    val session: SessionModel? get() = (this as? SignedIn)?.session
}

/** State of [AppModel]. */
data class AppState(
    val phase: AppPhase = AppPhase.Launching,
    /**
     * True from the verification of a recovery code until the new password is set (or the recovery is abandoned).
     * While true, a signed-in auth state shows [AppPhase.PasswordRecovery] instead of the app.
     */
    val isInPasswordRecovery: Boolean = false,
    /** The « Mot de passe oublié » flow presented from the signed-out screens (as a dialog/sheet), null when none. */
    val passwordReset: PasswordResetViewModel? = null,
) {
    /** The signed-in session, null in the other phases. */
    val session: SessionModel? get() = phase.session
}

/**
 * Root model of the app: follows `AuthService.authStates()` and owns ONE [SessionModel] per signed-in user (created and
 * started on sign-in, stopped on sign-out or user change, docs/CONTRACTS.md §7). Auth transitions run one at a time, in
 * order, in [scope] (never interrupted by the cancellation of a caller).
 *
 * Android: create it once per process with a main-thread scope (e.g. `CoroutineScope(SupervisorJob() +
 * Dispatchers.Main.immediate)` or an activity-independent holder), call [start] at launch, `when (state.phase)` in the
 * root composable, and forward app events to [handleForeground], [handleBackgroundRefresh],
 * [handleSignificantTimeChange] and [open] / `router.open(…)`.
 */
class AppModel(
    val services: AppServices,
    val platform: PlatformServices,
    private val scope: CoroutineScope,
    /** Navigation of the signed-in app (kept across sessions: deep links received while signed out wait in it). */
    val router: Router = Router(),
    private val sessionConfiguration: SessionModel.Configuration = SessionModel.Configuration(),
) {
    private val mutableState = MutableStateFlow(AppState())

    val state: StateFlow<AppState> = mutableState.asStateFlow()

    /** `state.value.phase`. */
    val phase: AppPhase get() = mutableState.value.phase

    /** The signed-in session, null in the other phases. */
    val session: SessionModel? get() = phase.session

    /** `state.value.isInPasswordRecovery`. */
    val isInPasswordRecovery: Boolean get() = mutableState.value.isInPasswordRecovery

    /** The « Mot de passe oublié » flow presented from the signed-out screens; set it to null when the sheet closes. */
    var passwordReset: PasswordResetViewModel?
        get() = mutableState.value.passwordReset
        set(value) = mutableState.update { it.copy(passwordReset = value) }

    private var authJob: Job? = null
    private var transitionTail: Job? = null
    private var latestAuthState: AuthState = AuthState.Unknown
    private var activeSession: SessionModel? = null

    /** The flow whose recovery code was verified (kept even if the sheet cleared [passwordReset]). */
    private var recoveryModel: PasswordResetViewModel? = null

    // region Lifecycle

    /** Starts following the auth state (idempotent; call at launch). The first state resolves `Launching`. */
    fun start() {
        if (authJob != null) return
        val states = services.auth.authStates()
        authJob = scope.launch {
            states.collect { state -> serialized { apply(state) } }
        }
    }

    /** Stops following the auth state and ends the session (tests, previews). */
    suspend fun shutdown() {
        authJob?.cancel()
        authJob = null
        serialized { endSession(AppPhase.SignedOut) }
    }

    // endregion

    // region App events

    /** The app came back to the foreground: reload every screen, catch up on assignments, synchronize reminders. */
    suspend fun handleForeground() {
        activeSession?.handleForeground()
    }

    /**
     * Background refresh (WorkManager). Works even when the process was started in the background and nothing called
     * [start]: the stored session is restored first.
     */
    suspend fun handleBackgroundRefresh() {
        start()
        if (activeSession == null && phase == AppPhase.Launching && !isInPasswordRecovery) {
            val user = currentUser()
            if (user != null) {
                serialized {
                    if (activeSession == null && phase == AppPhase.Launching && !isInPasswordRecovery) {
                        latestAuthState = AuthState.SignedIn(user)
                        enterSession(user)
                    }
                }
            }
        }
        activeSession?.handleBackgroundRefresh()
    }

    /** Significant time change (midnight, time zone, clock): refresh date-dependent content and reminders. */
    suspend fun handleSignificantTimeChange() {
        activeSession?.handleSignificantTimeChange()
    }

    /** Opens an `equipe://` URL (applied when a session is active). Returns false when it is not ours. */
    fun open(url: String): Boolean = router.open(url)

    // endregion

    // region View model factories

    fun makeLoginViewModel(email: String = ""): LoginViewModel = LoginViewModel(services, email)

    fun makeSignUpViewModel(): SignUpViewModel = SignUpViewModel(services)

    /** Starts a « Mot de passe oublié » flow and stores it in [passwordReset] (present it as a sheet/dialog). */
    fun startPasswordReset(email: String = ""): PasswordResetViewModel {
        val model = PasswordResetViewModel(services, email, this)
        passwordReset = model
        return model
    }

    // endregion

    // region Password recovery (called by PasswordResetViewModel)

    /** Called right before verifying a recovery code: the sign-in that follows must not open the app. */
    internal fun beginPasswordRecovery(model: PasswordResetViewModel) {
        recoveryModel = model
        mutableState.update { it.copy(isInPasswordRecovery = true) }
    }

    /** The code was refused: back to normal. */
    internal suspend fun cancelPasswordRecovery() {
        if (!isInPasswordRecovery) return
        recoveryModel = null
        mutableState.update { it.copy(isInPasswordRecovery = false) }
        reapplyLatestState()
    }

    /** The new password is set: open the app. */
    internal suspend fun finishPasswordRecovery() {
        recoveryModel = null
        mutableState.update { it.copy(isInPasswordRecovery = false, passwordReset = null) }
        reapplyLatestState()
    }

    /**
     * The user gave up at the « Nouveau mot de passe » step: sign out (local) and back to the login screen. Runs in
     * [scope]: the screen leaving (which cancels its coroutines) must not interrupt it.
     */
    internal suspend fun abandonPasswordRecovery() {
        scope.launch {
            val signedOut = try {
                services.auth.signOut()
                true
            } catch (error: CancellationException) {
                throw error
            } catch (error: Exception) {
                false
            }
            // The SignedOut state may still be on its way through authStates(): apply it now rather than reopening the
            // app on the stale signed-in state (the later SignedOut is then a no-op).
            if (signedOut) latestAuthState = AuthState.SignedOut
            recoveryModel = null
            mutableState.update { it.copy(isInPasswordRecovery = false, passwordReset = null) }
            reapplyLatestState()
        }.join()
    }

    // endregion

    // region Transitions

    /** Runs auth transitions one at a time, in call order, in [scope] (they await the previous session's teardown). */
    private suspend fun serialized(body: suspend () -> Unit) {
        val previous = transitionTail
        val job = scope.launch(start = CoroutineStart.LAZY) {
            previous?.join()
            body()
        }
        transitionTail = job
        job.start()
        job.join()
    }

    private suspend fun reapplyLatestState() {
        serialized { apply(latestAuthState) }
    }

    private suspend fun apply(state: AuthState) {
        latestAuthState = state
        when (state) {
            // Not restored yet: stay on the splash screen; never undo a resolved state.
            AuthState.Unknown -> Unit
            AuthState.SignedOut -> {
                val recovery = recoveryModel
                if (isInPasswordRecovery && recovery != null && phase is AppPhase.PasswordRecovery) {
                    // The recovery session ended by itself (revoked, refresh refused): the new password can no longer be
                    // set. The flow starts over at the e-mail step, with an explanation, instead of reopening on a dead
                    // session.
                    recoveryModel = null
                    mutableState.update { it.copy(isInPasswordRecovery = false) }
                    recovery.recoverySessionEnded()
                    passwordReset = recovery
                }
                endSession(AppPhase.SignedOut)
            }
            is AuthState.SignedIn -> enterSession(state.user)
        }
    }

    private suspend fun enterSession(user: AuthUser) {
        val current = activeSession
        if (current != null && current.userId == user.id) {
            current.update(user)
            setPhase(AppPhase.SignedIn(current))
            return
        }
        if (current != null) {
            endSession(AppPhase.Launching)
        }
        val recovery = recoveryModel
        if (isInPasswordRecovery && recovery != null) {
            setPhase(AppPhase.PasswordRecovery(recovery))
            return
        }
        val session = SessionModel(user, services, platform, scope, sessionConfiguration)
        activeSession = session
        setPhase(AppPhase.SignedIn(session))
        session.start()
        router.activate()
    }

    /**
     * Switches the UI first, then tears the previous session down (awaited, so that the next session never overlaps
     * it).
     */
    private suspend fun endSession(nextPhase: AppPhase) {
        val ending = activeSession
        activeSession = null
        setPhase(nextPhase)
        if (ending != null) {
            router.deactivate()
        }
        ending?.stop()
    }

    private fun setPhase(phase: AppPhase) {
        mutableState.update { it.copy(phase = phase) }
    }

    private suspend fun currentUser(): AuthUser? = try {
        services.auth.currentUser()
    } catch (error: CancellationException) {
        throw error
    } catch (error: Exception) {
        null
    }

    // endregion
}
