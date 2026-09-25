package io.github.notkanaa.equipe.ui.auth

import androidx.activity.compose.BackHandler
import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.slideInHorizontally
import androidx.compose.animation.slideInVertically
import androidx.compose.animation.slideOutHorizontally
import androidx.compose.animation.slideOutVertically
import androidx.compose.animation.togetherWith
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.key
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import io.github.notkanaa.equipe.core.viewmodel.AppModel
import io.github.notkanaa.equipe.core.viewmodel.PasswordResetViewModel
import io.github.notkanaa.equipe.core.viewmodel.SignUpViewModel
import kotlinx.coroutines.CoroutineScope

/**
 * Signed-out screens (iOS `AuthFlowView`): « Connexion » (root), « Créer un compte » (pushed) and the « Mot de passe
 * oublié » flow of `AppModel.passwordReset`, which slides up over them.
 *
 * @param actionScope the app's scope: sign-in, sign-up and the reset steps complete even when the session opens.
 */
@Composable
fun AuthFlow(appModel: AppModel, actionScope: CoroutineScope) {
    val appState by appModel.state.collectAsStateWithLifecycle()
    val login = remember(appModel) { appModel.makeLoginViewModel() }
    var signUp by remember(appModel) { mutableStateOf<SignUpViewModel?>(null) }

    // The reset flow stays drawn while it slides away (AppModel.passwordReset is already null then).
    val passwordReset = appState.passwordReset
    var shownReset by remember { mutableStateOf<PasswordResetViewModel?>(null) }
    if (passwordReset != null) shownReset = passwordReset

    fun backToLogin(email: String) {
        val trimmed = email.trim()
        if (trimmed.isNotEmpty()) login.email = trimmed
        signUp = null
    }

    BackHandler(enabled = signUp != null && passwordReset == null) { signUp = null }

    Box(modifier = Modifier.fillMaxSize()) {
        AnimatedContent(
            targetState = signUp,
            contentKey = { it != null },
            transitionSpec = {
                if (targetState != null) {
                    (slideInHorizontally(tween(PUSH_MILLIS)) { it } + fadeIn(tween(PUSH_MILLIS))) togetherWith
                        (slideOutHorizontally(tween(PUSH_MILLIS)) { -it / 4 } + fadeOut(tween(PUSH_MILLIS)))
                } else {
                    (slideInHorizontally(tween(PUSH_MILLIS)) { -it / 4 } + fadeIn(tween(PUSH_MILLIS))) togetherWith
                        (slideOutHorizontally(tween(PUSH_MILLIS)) { it } + fadeOut(tween(PUSH_MILLIS)))
                }
            },
            label = "auth",
        ) { signUpModel ->
            if (signUpModel == null) {
                LoginScreen(
                    model = login,
                    actionScope = actionScope,
                    onSignUp = { signUp = appModel.makeSignUpViewModel() },
                    onForgotPassword = { appModel.startPasswordReset(login.email) },
                )
            } else {
                SignUpScreen(
                    model = signUpModel,
                    actionScope = actionScope,
                    onBack = { signUp = null },
                    onBackToLogin = ::backToLogin,
                )
            }
        }

        AnimatedVisibility(
            visible = passwordReset != null,
            enter = slideInVertically(tween(PUSH_MILLIS)) { it } + fadeIn(tween(PUSH_MILLIS)),
            exit = slideOutVertically(tween(PUSH_MILLIS)) { it } + fadeOut(tween(PUSH_MILLIS)),
        ) {
            shownReset?.let { model ->
                // One composition per flow: nothing (fields, dialogs) carries over to the next « Mot de passe oublié ».
                key(model.id) {
                    PasswordResetScreen(model = model, actionScope = actionScope)
                }
            }
        }
    }
}

private const val PUSH_MILLIS = 300
