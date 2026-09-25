package io.github.notkanaa.equipe.ui.auth

import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.consumeWindowInsets
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Error
import androidx.compose.material.icons.outlined.Lock
import androidx.compose.material.icons.outlined.Visibility
import androidx.compose.material.icons.outlined.VisibilityOff
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.LocalTextStyle
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextField
import androidx.compose.material3.TextFieldDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.autofill.ContentType
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.contentType
import androidx.compose.ui.semantics.error
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.text.input.VisualTransformation
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import io.github.notkanaa.equipe.ui.shell.BoundText
import io.github.notkanaa.equipe.ui.shell.FormMaxWidth
import io.github.notkanaa.equipe.ui.shell.LocalMockBackend
import io.github.notkanaa.equipe.ui.theme.extendedColors

/** Test tags of the authentication screens (same identifiers as iOS `AccessibilityID.Auth`). */
object AuthTestTags {
    const val EMAIL: String = "auth.email"
    const val PASSWORD: String = "auth.password"
    const val DISPLAY_NAME: String = "auth.displayName"
    const val SIGN_IN: String = "auth.signIn"
    const val SIGN_UP: String = "auth.signUp"
    const val GO_TO_SIGN_UP: String = "auth.goToSignUp"
    const val FORGOT_PASSWORD: String = "auth.forgotPassword"

    /** Containers of the login and sign-up screens. */
    const val LOGIN_SCREEN: String = "auth.loginScreen"
    const val SIGN_UP_SCREEN: String = "auth.signUpScreen"

    /** Sign-up screen: « Déjà un compte ? Se connecter ». */
    const val GO_TO_SIGN_IN: String = "auth.goToSignIn"

    /** Sign-up screen: message shown when the e-mail must be confirmed, and its « Retour à la connexion » button. */
    const val SIGN_UP_CONFIRMATION: String = "auth.signUpConfirmation"
    const val BACK_TO_SIGN_IN: String = "auth.backToSignIn"

    // « Mot de passe oublié » flow and « Nouveau mot de passe » (password recovery).
    const val RESET_SCREEN: String = "auth.reset.screen"
    const val RESET_EMAIL: String = "auth.reset.email"
    const val RESET_SEND_CODE: String = "auth.reset.sendCode"
    const val RESET_INFO: String = "auth.reset.info"
    const val RESET_CODE: String = "auth.reset.code"
    const val RESET_VERIFY_CODE: String = "auth.reset.verifyCode"
    const val RESET_RESEND_CODE: String = "auth.reset.resendCode"
    const val RESET_CHANGE_EMAIL: String = "auth.reset.changeEmail"
    const val NEW_PASSWORD: String = "auth.reset.newPassword"
    const val NEW_PASSWORD_CONFIRMATION: String = "auth.reset.newPasswordConfirmation"
    const val SAVE_NEW_PASSWORD: String = "auth.reset.saveNewPassword"
    const val RESET_CANCEL: String = "auth.reset.cancel"
    const val RESET_DONE: String = "auth.reset.done"
    const val RESET_ABANDON_CONFIRM: String = "auth.reset.abandonConfirm"
}

/**
 * Scrollable column of an authentication screen inside a Scaffold: [contentPadding] is the Scaffold's inner padding
 * (consumed, so that the keyboard padding does not count the navigation bar twice); the content is centered, at most
 * [FormMaxWidth] wide, and stays above the keyboard. [modifier] carries the screen's test tag.
 */
@Composable
internal fun AuthFormColumn(
    contentPadding: PaddingValues,
    modifier: Modifier = Modifier,
    spacing: Dp = 24.dp,
    content: @Composable ColumnScope.() -> Unit,
) {
    Column(
        modifier = Modifier
            .fillMaxSize()
            .padding(contentPadding)
            .consumeWindowInsets(contentPadding)
            .imePadding()
            .verticalScroll(rememberScrollState()),
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Column(
            modifier = modifier
                .widthIn(max = FormMaxWidth)
                .fillMaxWidth()
                .padding(24.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(spacing),
            content = content,
        )
    }
}

/**
 * Rounded field on a card-coloured background with a leading icon and its own message below (iOS `AuthFieldStyle`):
 * an error in red with an icon (also announced by TalkBack), or a neutral [hint].
 *
 * @param autofill what the field holds for the autofill services (ignored on the mock backend: no autofill overlay
 *   during UI tests).
 * @param accessibilityLabel read instead of the label (e.g. « Code reçu par e-mail »).
 */
@Composable
internal fun AuthTextField(
    text: BoundText,
    label: String,
    icon: ImageVector,
    testTag: String,
    modifier: Modifier = Modifier,
    errorMessage: String? = null,
    hint: String? = null,
    focusRequester: FocusRequester? = null,
    keyboardOptions: KeyboardOptions = KeyboardOptions.Default,
    keyboardActions: KeyboardActions = KeyboardActions.Default,
    visualTransformation: VisualTransformation = VisualTransformation.None,
    trailingIcon: (@Composable () -> Unit)? = null,
    textStyle: TextStyle = LocalTextStyle.current,
    autofill: ContentType? = null,
    accessibilityLabel: String? = null,
    enabled: Boolean = true,
) {
    val isMockBackend = LocalMockBackend.current
    val shape = RoundedCornerShape(12.dp)
    val errorColor = MaterialTheme.colorScheme.error
    val containerColor = MaterialTheme.extendedColors.card
    Column(modifier = modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(6.dp)) {
        TextField(
            value = text.value,
            onValueChange = text::onValueChange,
            modifier = Modifier
                .fillMaxWidth()
                .then(if (focusRequester != null) Modifier.focusRequester(focusRequester) else Modifier)
                .then(if (errorMessage != null) Modifier.border(1.dp, errorColor, shape) else Modifier)
                .testTag(testTag)
                .semantics {
                    if (autofill != null && !isMockBackend) this.contentType = autofill
                    if (accessibilityLabel != null) this.contentDescription = accessibilityLabel
                    if (errorMessage != null) this.error(errorMessage)
                },
            enabled = enabled,
            textStyle = textStyle,
            label = { Text(label) },
            leadingIcon = { Icon(icon, contentDescription = null) },
            trailingIcon = trailingIcon,
            isError = errorMessage != null,
            visualTransformation = visualTransformation,
            keyboardOptions = keyboardOptions,
            keyboardActions = keyboardActions,
            singleLine = true,
            shape = shape,
            colors = TextFieldDefaults.colors(
                focusedContainerColor = containerColor,
                unfocusedContainerColor = containerColor,
                disabledContainerColor = containerColor,
                errorContainerColor = containerColor,
                focusedIndicatorColor = Color.Transparent,
                unfocusedIndicatorColor = Color.Transparent,
                disabledIndicatorColor = Color.Transparent,
                errorIndicatorColor = Color.Transparent,
            ),
        )
        if (errorMessage != null) {
            Row(
                modifier = Modifier
                    .padding(start = 4.dp)
                    // Announced with the field (semantics error).
                    .clearAndSetSemantics {},
                horizontalArrangement = Arrangement.spacedBy(6.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Icon(Icons.Filled.Error, contentDescription = null, tint = errorColor, modifier = Modifier.size(16.dp))
                Text(errorMessage, style = MaterialTheme.typography.bodySmall, color = errorColor)
            }
        } else if (hint != null) {
            Text(
                text = hint,
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.padding(start = 4.dp),
            )
        }
    }
}

/** Password field with a « show / hide » button (48 dp), styled like the other authentication fields. */
@Composable
internal fun AuthPasswordField(
    text: BoundText,
    label: String,
    testTag: String,
    imeAction: ImeAction,
    onImeAction: () -> Unit,
    modifier: Modifier = Modifier,
    errorMessage: String? = null,
    hint: String? = null,
    focusRequester: FocusRequester? = null,
    autofill: ContentType = ContentType.Password,
) {
    var isRevealed by rememberSaveable { mutableStateOf(false) }
    AuthTextField(
        text = text,
        label = label,
        icon = Icons.Outlined.Lock,
        testTag = testTag,
        modifier = modifier,
        errorMessage = errorMessage,
        hint = hint,
        focusRequester = focusRequester,
        keyboardOptions = KeyboardOptions(
            autoCorrectEnabled = false,
            keyboardType = KeyboardType.Password,
            imeAction = imeAction,
        ),
        keyboardActions = KeyboardActions(onAny = { onImeAction() }),
        visualTransformation = if (isRevealed) VisualTransformation.None else PasswordVisualTransformation(),
        trailingIcon = {
            IconButton(onClick = { isRevealed = !isRevealed }) {
                Icon(
                    imageVector = if (isRevealed) Icons.Outlined.VisibilityOff else Icons.Outlined.Visibility,
                    contentDescription = if (isRevealed) "Masquer le mot de passe" else "Afficher le mot de passe",
                )
            }
        },
        autofill = autofill,
    )
}

/** Header of the password reset steps and of the sign-up confirmation: a large icon above a centered text. */
@Composable
internal fun AuthStepHeader(icon: ImageVector, text: String, tint: Color, modifier: Modifier = Modifier) {
    Column(
        modifier = modifier.fillMaxWidth(),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Icon(icon, contentDescription = null, tint = tint, modifier = Modifier.size(52.dp))
        Text(
            text = text,
            style = MaterialTheme.typography.bodyLarge,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            textAlign = TextAlign.Center,
        )
    }
}

