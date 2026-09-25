package io.github.notkanaa.equipe.navigation

import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.EnterTransition
import androidx.compose.animation.ExitTransition
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.togetherWith
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.material3.MaterialTheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.getValue
import androidx.compose.runtime.key
import androidx.compose.ui.Modifier
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.testTagsAsResourceId
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import io.github.notkanaa.equipe.config.AppContainer
import io.github.notkanaa.equipe.core.viewmodel.AppModel
import io.github.notkanaa.equipe.core.viewmodel.AppPhase
import io.github.notkanaa.equipe.ui.auth.AuthFlow
import io.github.notkanaa.equipe.ui.auth.PasswordResetScreen
import io.github.notkanaa.equipe.ui.shell.LocalMockBackend
import io.github.notkanaa.equipe.ui.shell.ShellConfigurationMissing
import io.github.notkanaa.equipe.ui.shell.ShellSplash
import io.github.notkanaa.equipe.ui.theme.EquipeTheme
import kotlinx.coroutines.CoroutineScope

/**
 * Content of the activity: the configured app ([EquipeRoot]) or « Configuration manquante », in [EquipeTheme]. Test
 * tags are exposed as resource ids for UI Automator (`testTagsAsResourceId`) from here down.
 */
@Composable
fun EquipeApp(container: AppContainer) {
    val launch by container.launches.collectAsStateWithLifecycle()
    EquipeTheme {
        Box(
            modifier = Modifier
                .fillMaxSize()
                .background(MaterialTheme.colorScheme.background)
                .semantics { testTagsAsResourceId = true },
        ) {
            when (val current = launch) {
                is AppContainer.Launch.Ready -> key(current) {
                    CompositionLocalProvider(LocalMockBackend provides current.environment.isMock) {
                        EquipeRoot(appModel = current.appModel, actionScope = current.scope)
                    }
                }
                is AppContainer.Launch.Misconfigured -> ShellConfigurationMissing(current.issue)
                null -> ShellSplash()
            }
        }
    }
}

/**
 * Follows `AppModel.phase` (iOS `RootView`): splash while the stored session is restored, the authentication screens,
 * the « Nouveau mot de passe » screen of a password recovery, or the signed-in tabs, one [MainShell] per session (so
 * nothing survives a change of account). Phases cross-fade.
 *
 * @param actionScope the app's main-thread scope, for the actions that must complete even if their screen goes away
 *   (sign-in, password reset, sign-out, account deletion…).
 */
@Composable
fun EquipeRoot(appModel: AppModel, actionScope: CoroutineScope) {
    val state by appModel.state.collectAsStateWithLifecycle()
    AnimatedContent(
        targetState = state.phase,
        contentKey = ::phaseKey,
        transitionSpec = {
            if (isPasswordRecoverySwitch(initialState, targetState)) {
                // The same « Mot de passe oublié » screen moves from over the login screen to full screen (or back):
                // no cross-fade, which would show (and focus) two copies of it.
                EnterTransition.None togetherWith ExitTransition.None
            } else {
                fadeIn(tween(PHASE_FADE_MILLIS)) togetherWith fadeOut(tween(PHASE_FADE_MILLIS))
            }
        },
        label = "phase",
    ) { phase ->
        when (phase) {
            AppPhase.Launching -> ShellSplash()
            AppPhase.SignedOut -> AuthFlow(appModel, actionScope)
            is AppPhase.PasswordRecovery -> PasswordResetScreen(phase.model, actionScope)
            is AppPhase.SignedIn -> MainShell(appModel, phase.session, actionScope)
        }
    }
}

private const val PHASE_FADE_MILLIS = 250

private fun isPasswordRecoverySwitch(initial: AppPhase, target: AppPhase): Boolean =
    (initial == AppPhase.SignedOut && target is AppPhase.PasswordRecovery) ||
        (initial is AppPhase.PasswordRecovery && target == AppPhase.SignedOut)

private fun phaseKey(phase: AppPhase): String = when (phase) {
    AppPhase.Launching -> "launching"
    AppPhase.SignedOut -> "signedOut"
    is AppPhase.PasswordRecovery -> "recovery/${phase.model.id}"
    is AppPhase.SignedIn -> "session/${phase.session.id}"
}
