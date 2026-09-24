package io.github.notkanaa.equipe.core.viewmodel

import io.github.notkanaa.equipe.core.AppError
import io.github.notkanaa.equipe.core.AppServices
import io.github.notkanaa.equipe.core.InputValidation
import io.github.notkanaa.equipe.core.SignUpOutcome
import kotlin.coroutines.cancellation.CancellationException

// Port of TeamTasksCore/ViewModels/Auth/SignUpViewModel.swift.

/** State of the « Créer un compte » screen. */
data class SignUpState(
    val displayName: String = "",
    val email: String = "",
    val password: String = "",
    val displayNameError: String? = null,
    val emailError: String? = null,
    val passwordError: String? = null,
    val isSubmitting: Boolean = false,
    /**
     * Set when the project requires e-mail confirmation ([SignUpOutcome.CONFIRMATION_REQUIRED]): show
     * [SignUpViewModel.CONFIRMATION_REQUIRED_MESSAGE] and go back to the login screen.
     */
    val needsEmailConfirmation: Boolean = false,
    override val error: ErrorState? = null,
) : ErrorHolder {
    /** Every field filled and no request in progress (the rules themselves are checked on submit). */
    val canSubmit: Boolean
        get() = InputValidation.trimmed(displayName).isNotEmpty() &&
            InputValidation.trimmed(email).isNotEmpty() &&
            password.isNotEmpty() &&
            !isSubmitting
}

/**
 * « Créer un compte » screen. Fields are validated on the client with the rules of `InputValidation.signUp`
 * (docs/CONTRACTS.md §1) before calling the server; each field shows its own message. After a first failed submission,
 * a field's message updates live while it is corrected.
 */
class SignUpViewModel(
    private val services: AppServices,
) : ScreenModel<SignUpState>(SignUpState(), { state, error -> state.copy(error = error) }) {
    var displayName: String
        get() = current.displayName
        set(value) = update {
            it.copy(displayName = value, displayNameError = if (it.displayNameError != null) displayNameMessage(value) else null)
        }

    var email: String
        get() = current.email
        set(value) = update { it.copy(email = value, emailError = if (it.emailError != null) emailMessage(value) else null) }

    var password: String
        get() = current.password
        set(value) = update {
            it.copy(password = value, passwordError = if (it.passwordError != null) passwordMessage(value) else null)
        }

    /** Checks every field and sets its message. Returns true when all are valid. */
    fun validate(): Boolean {
        val state = current
        val emailError = emailMessage(state.email)
        val passwordError = passwordMessage(state.password)
        val displayNameError = displayNameMessage(state.displayName)
        update { it.copy(emailError = emailError, passwordError = passwordError, displayNameError = displayNameError) }
        return emailError == null && passwordError == null && displayNameError == null
    }

    /**
     * Creates the account. Returns true on success: the session opens (`AppModel` switches to the app) or
     * [SignUpState.needsEmailConfirmation] becomes true.
     */
    suspend fun signUp(): Boolean {
        if (current.isSubmitting) return false
        dismissError()
        if (!validate()) return false
        update { it.copy(isSubmitting = true) }
        try {
            val state = current
            val outcome = services.auth.signUp(state.email, state.password, state.displayName)
            update {
                it.copy(password = "", needsEmailConfirmation = outcome == SignUpOutcome.CONFIRMATION_REQUIRED)
            }
            return true
        } catch (error: CancellationException) {
            throw error
        } catch (error: Exception) {
            val appError = ErrorState.from(error)?.error ?: return false
            when (appError) {
                AppError.InvalidEmail, AppError.EmailAlreadyUsed -> update { it.copy(emailError = appError.messageFR) }
                AppError.WeakPassword -> update { it.copy(passwordError = appError.messageFR) }
                AppError.InvalidDisplayName -> update { it.copy(displayNameError = appError.messageFR) }
                else -> present(appError)
            }
            return false
        } finally {
            update { it.copy(isSubmitting = false) }
        }
    }

    companion object {
        const val PASSWORD_TOO_LONG_MESSAGE: String = "Mot de passe trop long (72 caractères maximum)."
        const val CONFIRMATION_REQUIRED_MESSAGE: String =
            "Compte créé. Confirmez votre adresse e-mail grâce au lien reçu, puis connectez-vous."

        // region Field rules (InputValidation, docs/CONTRACTS.md §1)

        fun emailMessage(email: String): String? = try {
            InputValidation.email(email)
            null
        } catch (error: AppError) {
            AppError.InvalidEmail.messageFR
        }

        fun passwordMessage(password: String): String? = try {
            InputValidation.password(password)
            null
        } catch (error: AppError) {
            if (error == AppError.WeakPassword) AppError.WeakPassword.messageFR else PASSWORD_TOO_LONG_MESSAGE
        }

        fun displayNameMessage(name: String): String? = try {
            InputValidation.displayName(name)
            null
        } catch (error: AppError) {
            AppError.InvalidDisplayName.messageFR
        }

        // endregion
    }
}
