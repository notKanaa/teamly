package io.github.notkanaa.equipe.ui.auth

import androidx.activity.compose.BackHandler
import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.togetherWith
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Verified
import androidx.compose.material.icons.outlined.Drafts
import androidx.compose.material.icons.outlined.Email
import androidx.compose.material.icons.outlined.Key
import androidx.compose.material.icons.outlined.LockReset
import androidx.compose.material.icons.outlined.Pin
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.CircularProgressIndicator
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
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.autofill.ContentType
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import io.github.notkanaa.equipe.core.viewmodel.PasswordResetState
import io.github.notkanaa.equipe.core.viewmodel.PasswordResetStep
import io.github.notkanaa.equipe.core.viewmodel.PasswordResetViewModel
import io.github.notkanaa.equipe.ui.shell.LocalMockBackend
import io.github.notkanaa.equipe.ui.shell.ShellErrorDialog
import io.github.notkanaa.equipe.ui.shell.ShellInfoBanner
import io.github.notkanaa.equipe.ui.shell.ShellPrimaryButton
import io.github.notkanaa.equipe.ui.shell.exposeTestTags
import io.github.notkanaa.equipe.ui.shell.rememberBoundText
import io.github.notkanaa.equipe.ui.shell.requestFocusIfAttached
import io.github.notkanaa.equipe.ui.theme.extendedColors
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.launch

/**
 * « Mot de passe oublié » (iOS `PasswordResetView`): e-mail → 6-digit code received by e-mail → new password.
 *
 * Shown over the login screen while `AppModel.passwordReset` is set; once the code is verified the user is signed in
 * with a recovery session and the root shows this same model full screen (`AppPhase.PasswordRecovery`) at the
 * « Nouveau mot de passe » step, until the password is changed or the recovery is abandoned (local sign-out).
 *
 * « Annuler » (close icon) leaves the flow, after a confirmation at the new password step. System back goes from the
 * code step back to the e-mail step, and cancels otherwise.
 *
 * @param actionScope where the steps run: verifying the code switches the root to the recovery screen, which removes
 *   this screen from the composition; the step must still complete.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun PasswordResetScreen(model: PasswordResetViewModel, actionScope: CoroutineScope, modifier: Modifier = Modifier) {
    val state by model.state.collectAsStateWithLifecycle()
    var isConfirmingAbandon by rememberSaveable { mutableStateOf(false) }

    fun cancel() {
        if (model.state.value.step == PasswordResetStep.NEW_PASSWORD) {
            isConfirmingAbandon = true
        } else {
            actionScope.launch { model.cancel() }
        }
    }

    BackHandler {
        val current = model.state.value
        when {
            current.isSubmitting || current.step == PasswordResetStep.DONE -> Unit
            current.step == PasswordResetStep.CODE -> model.goBack()
            else -> cancel()
        }
    }

    Scaffold(
        modifier = modifier,
        containerColor = MaterialTheme.colorScheme.background,
        topBar = {
            TopAppBar(
                title = { Text(state.title) },
                navigationIcon = {
                    if (state.step != PasswordResetStep.DONE) {
                        IconButton(
                            onClick = ::cancel,
                            enabled = !state.isSubmitting,
                            modifier = Modifier.testTag(AuthTestTags.RESET_CANCEL),
                        ) {
                            Icon(Icons.Filled.Close, contentDescription = "Annuler")
                        }
                    }
                },
                colors = TopAppBarDefaults.topAppBarColors(containerColor = MaterialTheme.colorScheme.background),
            )
        },
    ) { padding ->
        AuthFormColumn(contentPadding = padding, modifier = Modifier.testTag(AuthTestTags.RESET_SCREEN)) {
            StepHeader(state.step)

            val info = state.infoMessage
            if (info != null && state.step != PasswordResetStep.DONE) {
                ShellInfoBanner(message = info, modifier = Modifier.testTag(AuthTestTags.RESET_INFO))
            }

            AnimatedContent(
                targetState = state.step,
                transitionSpec = { fadeIn() togetherWith fadeOut() },
                label = "resetStep",
            ) { step ->
                when (step) {
                    PasswordResetStep.EMAIL -> EmailStep(model, state, actionScope)
                    PasswordResetStep.CODE -> CodeStep(model, state, actionScope)
                    PasswordResetStep.NEW_PASSWORD -> NewPasswordStep(model, state, actionScope)
                    PasswordResetStep.DONE -> DoneStep()
                }
            }
        }
    }

    if (isConfirmingAbandon) {
        AlertDialog(
            onDismissRequest = { isConfirmingAbandon = false },
            title = { Text("Abandonner le changement de mot de passe ?") },
            text = { Text("Votre mot de passe ne sera pas modifié et vous reviendrez à l’écran de connexion.") },
            confirmButton = {
                TextButton(
                    onClick = {
                        isConfirmingAbandon = false
                        actionScope.launch { model.cancel() }
                    },
                    colors = ButtonDefaults.textButtonColors(contentColor = MaterialTheme.colorScheme.error),
                    modifier = Modifier
                        .exposeTestTags()
                        .testTag(AuthTestTags.RESET_ABANDON_CONFIRM),
                ) {
                    Text("Abandonner")
                }
            },
            dismissButton = {
                TextButton(onClick = { isConfirmingAbandon = false }) {
                    Text("Continuer")
                }
            },
        )
    }

    state.error?.let { error ->
        ShellErrorDialog(message = error.message, onDismiss = model::dismissError)
    }
}

@Composable
private fun StepHeader(step: PasswordResetStep) {
    val (icon, text) = when (step) {
        PasswordResetStep.EMAIL -> Icons.Outlined.Key to
            "Saisissez l’adresse e-mail de votre compte : nous vous enverrons un code à 6 chiffres pour choisir " +
            "un nouveau mot de passe."
        PasswordResetStep.CODE -> Icons.Outlined.Drafts to
            "Saisissez le code à 6 chiffres reçu par e-mail. Pensez à vérifier vos courriers indésirables."
        PasswordResetStep.NEW_PASSWORD -> Icons.Outlined.LockReset to
            "Choisissez un nouveau mot de passe (8 caractères minimum)."
        PasswordResetStep.DONE -> Icons.Filled.Verified to PasswordResetViewModel.DONE_MESSAGE
    }
    val tint = if (step == PasswordResetStep.DONE) {
        MaterialTheme.extendedColors.success
    } else {
        MaterialTheme.colorScheme.primary
    }
    AuthStepHeader(icon = icon, text = text, tint = tint)
}

@Composable
private fun EmailStep(model: PasswordResetViewModel, state: PasswordResetState, actionScope: CoroutineScope) {
    val focusManager = LocalFocusManager.current
    val emailFocus = remember { FocusRequester() }
    val email = rememberBoundText(model, state.email, { model.email }, { model.email = it })

    fun sendCode() {
        if (!model.state.value.canSendCode) return
        focusManager.clearFocus()
        actionScope.launch { model.sendCode() }
    }

    LaunchedEffect(model) {
        if (model.email.isEmpty()) emailFocus.requestFocusIfAttached()
    }

    Column(verticalArrangement = Arrangement.spacedBy(20.dp)) {
        AuthTextField(
            text = email,
            label = "Adresse e-mail",
            icon = Icons.Outlined.Email,
            testTag = AuthTestTags.RESET_EMAIL,
            focusRequester = emailFocus,
            keyboardOptions = emailKeyboard(ImeAction.Send),
            keyboardActions = KeyboardActions(onSend = { sendCode() }),
            autofill = ContentType.Username + ContentType.EmailAddress,
        )
        ShellPrimaryButton(
            text = "Envoyer le code",
            onClick = ::sendCode,
            enabled = state.canSendCode,
            isLoading = state.isSubmitting,
            modifier = Modifier.testTag(AuthTestTags.RESET_SEND_CODE),
        )
    }
}

@Composable
private fun CodeStep(model: PasswordResetViewModel, state: PasswordResetState, actionScope: CoroutineScope) {
    val focusManager = LocalFocusManager.current
    val codeFocus = remember { FocusRequester() }
    val code = rememberBoundText(model, state.code, { model.code }, { model.code = it })

    fun verifyCode() {
        if (!model.state.value.canVerifyCode) return
        focusManager.clearFocus()
        actionScope.launch { model.verifyCode() }
    }

    LaunchedEffect(model) { codeFocus.requestFocusIfAttached() }

    Column(verticalArrangement = Arrangement.spacedBy(20.dp)) {
        AuthTextField(
            text = code,
            label = "Code à 6 chiffres",
            icon = Icons.Outlined.Pin,
            testTag = AuthTestTags.RESET_CODE,
            focusRequester = codeFocus,
            keyboardOptions = KeyboardOptions(
                autoCorrectEnabled = false,
                keyboardType = KeyboardType.NumberPassword,
                imeAction = ImeAction.Done,
            ),
            keyboardActions = KeyboardActions(onDone = { verifyCode() }),
            textStyle = MaterialTheme.typography.headlineSmall.copy(
                fontFamily = FontFamily.Monospace,
                textAlign = TextAlign.Center,
                letterSpacing = 6.sp,
            ),
            autofill = ContentType.SmsOtpCode,
            accessibilityLabel = "Code reçu par e-mail",
        )
        ShellPrimaryButton(
            text = "Valider le code",
            onClick = ::verifyCode,
            enabled = state.canVerifyCode,
            isLoading = state.isSubmitting,
            modifier = Modifier.testTag(AuthTestTags.RESET_VERIFY_CODE),
        )
        Column(modifier = Modifier.fillMaxWidth(), horizontalAlignment = Alignment.CenterHorizontally) {
            TextButton(
                onClick = { actionScope.launch { model.resendCode() } },
                enabled = !state.isSubmitting,
                colors = ButtonDefaults.textButtonColors(contentColor = MaterialTheme.extendedColors.accentText),
                modifier = Modifier.testTag(AuthTestTags.RESET_RESEND_CODE),
            ) {
                Text("Renvoyer le code")
            }
            TextButton(
                onClick = model::goBack,
                enabled = !state.isSubmitting,
                colors = ButtonDefaults.textButtonColors(contentColor = MaterialTheme.colorScheme.onSurfaceVariant),
                modifier = Modifier.testTag(AuthTestTags.RESET_CHANGE_EMAIL),
            ) {
                Text("Modifier l’adresse e-mail")
            }
        }
    }
}

@Composable
private fun NewPasswordStep(model: PasswordResetViewModel, state: PasswordResetState, actionScope: CoroutineScope) {
    val isMockBackend = LocalMockBackend.current
    val focusManager = LocalFocusManager.current
    val newPasswordFocus = remember { FocusRequester() }
    val confirmationFocus = remember { FocusRequester() }
    val newPassword = rememberBoundText(model, state.newPassword, { model.newPassword }, { model.newPassword = it })
    val confirmation = rememberBoundText(
        model,
        state.passwordConfirmation,
        { model.passwordConfirmation },
        { model.passwordConfirmation = it },
    )
    // Plain « password » on the mock backend: no « strong password » suggestion over the UI tests.
    val autofill = if (isMockBackend) ContentType.Password else ContentType.NewPassword

    fun updatePassword() {
        if (!model.state.value.canUpdatePassword) return
        focusManager.clearFocus()
        actionScope.launch { model.updatePassword() }
    }

    LaunchedEffect(model) { newPasswordFocus.requestFocusIfAttached() }

    Column(verticalArrangement = Arrangement.spacedBy(20.dp)) {
        Column(verticalArrangement = Arrangement.spacedBy(14.dp)) {
            AuthPasswordField(
                text = newPassword,
                label = "Nouveau mot de passe",
                testTag = AuthTestTags.NEW_PASSWORD,
                imeAction = ImeAction.Next,
                onImeAction = { confirmationFocus.requestFocus() },
                focusRequester = newPasswordFocus,
                autofill = autofill,
            )
            AuthPasswordField(
                text = confirmation,
                label = "Confirmez le mot de passe",
                testTag = AuthTestTags.NEW_PASSWORD_CONFIRMATION,
                imeAction = ImeAction.Done,
                onImeAction = ::updatePassword,
                focusRequester = confirmationFocus,
                autofill = autofill,
            )
        }
        ShellPrimaryButton(
            text = "Enregistrer le mot de passe",
            onClick = ::updatePassword,
            enabled = state.canUpdatePassword,
            isLoading = state.isSubmitting,
            modifier = Modifier.testTag(AuthTestTags.SAVE_NEW_PASSWORD),
        )
    }
}

/** The app opens right after this step; the spinner covers the transition. */
@Composable
private fun DoneStep() {
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .padding(top = 8.dp)
            .testTag(AuthTestTags.RESET_DONE),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        CircularProgressIndicator()
        Text(
            text = "Ouverture d’Équipe…",
            style = MaterialTheme.typography.bodyLarge,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
    }
}
