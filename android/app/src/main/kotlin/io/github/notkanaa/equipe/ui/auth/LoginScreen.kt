package io.github.notkanaa.equipe.ui.auth

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.Email
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.autofill.ContentType
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import io.github.notkanaa.equipe.core.viewmodel.LoginViewModel
import io.github.notkanaa.equipe.ui.shell.ShellBrandHeader
import io.github.notkanaa.equipe.ui.shell.ShellErrorDialog
import io.github.notkanaa.equipe.ui.shell.ShellPrimaryButton
import io.github.notkanaa.equipe.ui.shell.rememberBoundText
import io.github.notkanaa.equipe.ui.theme.extendedColors
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.launch

/** Keyboard of the e-mail fields: e-mail layout, no autocorrection, no capitalization. */
internal fun emailKeyboard(imeAction: ImeAction): KeyboardOptions =
    KeyboardOptions(autoCorrectEnabled = false, keyboardType = KeyboardType.Email, imeAction = imeAction)

/**
 * « Connexion » (iOS `LoginView`). On success `AppModel` switches to the signed-in app by itself.
 *
 * @param actionScope where sign-in runs (it must not be cancelled when this screen leaves as the session opens).
 */
@Composable
internal fun LoginScreen(
    model: LoginViewModel,
    actionScope: CoroutineScope,
    onSignUp: () -> Unit,
    onForgotPassword: () -> Unit,
) {
    val state by model.state.collectAsStateWithLifecycle()
    val focusManager = LocalFocusManager.current
    val passwordFocus = remember { FocusRequester() }
    val email = rememberBoundText(model, state.email, { model.email }, { model.email = it })
    val password = rememberBoundText(model, state.password, { model.password }, { model.password = it })
    val linkColors = ButtonDefaults.textButtonColors(contentColor = MaterialTheme.extendedColors.accentText)

    fun signIn() {
        if (!model.state.value.canSubmit) return
        focusManager.clearFocus()
        actionScope.launch { model.signIn() }
    }

    Scaffold(containerColor = MaterialTheme.colorScheme.background) { padding ->
        AuthFormColumn(
            contentPadding = padding,
            modifier = Modifier.testTag(AuthTestTags.LOGIN_SCREEN),
            spacing = 32.dp,
        ) {
            ShellBrandHeader(
                subtitle = "Les tâches de votre groupe, partagées et à jour.",
                modifier = Modifier.padding(top = 24.dp),
            )

            Column(verticalArrangement = Arrangement.spacedBy(14.dp)) {
                AuthTextField(
                    text = email,
                    label = "Adresse e-mail",
                    icon = Icons.Outlined.Email,
                    testTag = AuthTestTags.EMAIL,
                    keyboardOptions = emailKeyboard(ImeAction.Next),
                    keyboardActions = KeyboardActions(onNext = { passwordFocus.requestFocus() }),
                    autofill = ContentType.Username + ContentType.EmailAddress,
                )
                AuthPasswordField(
                    text = password,
                    label = "Mot de passe",
                    testTag = AuthTestTags.PASSWORD,
                    imeAction = ImeAction.Go,
                    onImeAction = ::signIn,
                    focusRequester = passwordFocus,
                )
                Box(modifier = Modifier.fillMaxWidth(), contentAlignment = Alignment.CenterEnd) {
                    TextButton(
                        onClick = onForgotPassword,
                        enabled = !state.isSubmitting,
                        colors = linkColors,
                        modifier = Modifier.testTag(AuthTestTags.FORGOT_PASSWORD),
                    ) {
                        Text("Mot de passe oublié ?")
                    }
                }
            }

            ShellPrimaryButton(
                text = "Se connecter",
                onClick = ::signIn,
                enabled = state.canSubmit,
                isLoading = state.isSubmitting,
                modifier = Modifier.testTag(AuthTestTags.SIGN_IN),
            )

            Column(horizontalAlignment = Alignment.CenterHorizontally) {
                Text(
                    text = "Pas encore de compte ?",
                    style = MaterialTheme.typography.bodyLarge,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
                TextButton(
                    onClick = onSignUp,
                    enabled = !state.isSubmitting,
                    colors = linkColors,
                    modifier = Modifier.testTag(AuthTestTags.GO_TO_SIGN_UP),
                ) {
                    Text("Créer un compte", fontWeight = FontWeight.SemiBold)
                }
            }
        }
    }

    state.error?.let { error ->
        ShellErrorDialog(message = error.message, onDismiss = model::dismissError)
    }
}
