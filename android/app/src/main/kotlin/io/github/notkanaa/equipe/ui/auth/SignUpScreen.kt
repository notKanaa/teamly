package io.github.notkanaa.equipe.ui.auth

import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.togetherWith
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.outlined.Email
import androidx.compose.material.icons.outlined.MarkEmailUnread
import androidx.compose.material.icons.outlined.Person
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.autofill.ContentType
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardCapitalization
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import io.github.notkanaa.equipe.core.viewmodel.SignUpViewModel
import io.github.notkanaa.equipe.ui.shell.LocalMockBackend
import io.github.notkanaa.equipe.ui.shell.ShellErrorDialog
import io.github.notkanaa.equipe.ui.shell.ShellPrimaryButton
import io.github.notkanaa.equipe.ui.shell.rememberBoundText
import io.github.notkanaa.equipe.ui.shell.requestFocusIfAttached
import io.github.notkanaa.equipe.ui.theme.extendedColors
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.launch

/**
 * « Créer un compte » (iOS `SignUpView`). Each field shows its own message; on success the session opens (`AppModel`
 * switches to the app), or, when the project requires e-mail confirmation, a message invites to confirm, then sign in.
 *
 * @param onBack back arrow and system back (the e-mail is not carried over, like iOS).
 * @param onBackToLogin « Se connecter » / « Retour à la connexion »: back to the login screen with this e-mail.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun SignUpScreen(
    model: SignUpViewModel,
    actionScope: CoroutineScope,
    onBack: () -> Unit,
    onBackToLogin: (String) -> Unit,
) {
    val state by model.state.collectAsStateWithLifecycle()

    Scaffold(
        containerColor = MaterialTheme.colorScheme.background,
        topBar = {
            TopAppBar(
                title = { Text("Créer un compte") },
                navigationIcon = {
                    IconButton(onClick = onBack) {
                        Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = "Retour")
                    }
                },
                colors = TopAppBarDefaults.topAppBarColors(containerColor = MaterialTheme.colorScheme.background),
            )
        },
    ) { padding ->
        AuthFormColumn(contentPadding = padding, modifier = Modifier.testTag(AuthTestTags.SIGN_UP_SCREEN)) {
            AnimatedContent(
                targetState = state.needsEmailConfirmation,
                transitionSpec = { fadeIn() togetherWith fadeOut() },
                label = "signUp",
            ) { needsConfirmation ->
                if (needsConfirmation) {
                    ConfirmationContent(onBackToLogin = { onBackToLogin(model.email) })
                } else {
                    SignUpForm(model = model, actionScope = actionScope, onBackToLogin = onBackToLogin)
                }
            }
        }
    }

    state.error?.let { error ->
        ShellErrorDialog(message = error.message, onDismiss = model::dismissError)
    }
}

@Composable
private fun SignUpForm(model: SignUpViewModel, actionScope: CoroutineScope, onBackToLogin: (String) -> Unit) {
    val state by model.state.collectAsStateWithLifecycle()
    val isMockBackend = LocalMockBackend.current
    val focusManager = LocalFocusManager.current
    val nameFocus = remember { FocusRequester() }
    val emailFocus = remember { FocusRequester() }
    val passwordFocus = remember { FocusRequester() }
    val displayName = rememberBoundText(model, state.displayName, { model.displayName }, { model.displayName = it })
    val email = rememberBoundText(model, state.email, { model.email }, { model.email = it })
    val password = rememberBoundText(model, state.password, { model.password }, { model.password = it })

    fun signUp() {
        if (!model.state.value.canSubmit) return
        focusManager.clearFocus()
        actionScope.launch { model.signUp() }
    }

    LaunchedEffect(model) {
        if (model.displayName.isEmpty()) nameFocus.requestFocusIfAttached()
    }

    Column(verticalArrangement = Arrangement.spacedBy(24.dp)) {
        Text(
            text = "Rejoignez vos groupes et suivez les tâches qui vous sont confiées.",
            style = MaterialTheme.typography.bodyLarge,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            textAlign = TextAlign.Center,
            modifier = Modifier.fillMaxWidth(),
        )

        Column(verticalArrangement = Arrangement.spacedBy(14.dp)) {
            AuthTextField(
                text = displayName,
                label = "Votre nom",
                icon = Icons.Outlined.Person,
                testTag = AuthTestTags.DISPLAY_NAME,
                errorMessage = state.displayNameError,
                focusRequester = nameFocus,
                keyboardOptions = KeyboardOptions(
                    capitalization = KeyboardCapitalization.Words,
                    keyboardType = KeyboardType.Text,
                    imeAction = ImeAction.Next,
                ),
                keyboardActions = KeyboardActions(onNext = { emailFocus.requestFocus() }),
                autofill = ContentType.PersonFullName,
            )
            AuthTextField(
                text = email,
                label = "Adresse e-mail",
                icon = Icons.Outlined.Email,
                testTag = AuthTestTags.EMAIL,
                errorMessage = state.emailError,
                focusRequester = emailFocus,
                keyboardOptions = emailKeyboard(ImeAction.Next),
                keyboardActions = KeyboardActions(onNext = { passwordFocus.requestFocus() }),
                autofill = ContentType.NewUsername + ContentType.EmailAddress,
            )
            AuthPasswordField(
                text = password,
                label = "Mot de passe",
                testTag = AuthTestTags.PASSWORD,
                imeAction = ImeAction.Done,
                onImeAction = ::signUp,
                errorMessage = state.passwordError,
                hint = "8 caractères minimum.",
                focusRequester = passwordFocus,
                // Plain « password » on the mock backend: no « strong password » suggestion over the UI tests.
                autofill = if (isMockBackend) ContentType.Password else ContentType.NewPassword,
            )
        }

        ShellPrimaryButton(
            text = "Créer mon compte",
            onClick = ::signUp,
            enabled = state.canSubmit,
            isLoading = state.isSubmitting,
            modifier = Modifier.testTag(AuthTestTags.SIGN_UP),
        )

        Column(modifier = Modifier.fillMaxWidth(), horizontalAlignment = Alignment.CenterHorizontally) {
            Text(
                text = "Déjà un compte ?",
                style = MaterialTheme.typography.bodyLarge,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
            TextButton(
                onClick = { onBackToLogin(model.email) },
                enabled = !state.isSubmitting,
                colors = ButtonDefaults.textButtonColors(contentColor = MaterialTheme.extendedColors.accentText),
                modifier = Modifier.testTag(AuthTestTags.GO_TO_SIGN_IN),
            ) {
                Text("Se connecter", fontWeight = FontWeight.SemiBold)
            }
        }
    }
}

/** The project requires e-mail confirmation: « Vérifiez vos e-mails », then back to the login screen. */
@Composable
private fun ConfirmationContent(onBackToLogin: () -> Unit) {
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .padding(top = 32.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(20.dp),
    ) {
        Icon(
            imageVector = Icons.Outlined.MarkEmailUnread,
            contentDescription = null,
            tint = MaterialTheme.colorScheme.primary,
            modifier = Modifier.size(56.dp),
        )
        Text(
            text = "Vérifiez vos e-mails",
            style = MaterialTheme.typography.headlineSmall,
            modifier = Modifier.semantics { heading() },
        )
        Text(
            text = SignUpViewModel.CONFIRMATION_REQUIRED_MESSAGE,
            style = MaterialTheme.typography.bodyLarge,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            textAlign = TextAlign.Center,
            modifier = Modifier.testTag(AuthTestTags.SIGN_UP_CONFIRMATION),
        )
        ShellPrimaryButton(
            text = "Retour à la connexion",
            onClick = onBackToLogin,
            modifier = Modifier.testTag(AuthTestTags.BACK_TO_SIGN_IN),
        )
    }
}
