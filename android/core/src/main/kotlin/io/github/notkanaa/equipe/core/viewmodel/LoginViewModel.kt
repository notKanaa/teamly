package io.github.notkanaa.equipe.core.viewmodel

import io.github.notkanaa.equipe.core.AppError
import io.github.notkanaa.equipe.core.AppServices
import io.github.notkanaa.equipe.core.InputValidation
import kotlin.coroutines.cancellation.CancellationException

// Port of TeamTasksCore/ViewModels/Auth/LoginViewModel.swift.

/** State of the « Connexion » screen. */
data class LoginState(
    val email: String = "",
    val password: String = "",
    val isSubmitting: Boolean = false,
    override val error: ErrorState? = null,
) : ErrorHolder {
    /** Both fields filled and no request in progress. */
    val canSubmit: Boolean
        get() = InputValidation.trimmed(email).isNotEmpty() && password.isNotEmpty() && !isSubmitting
}

/**
 * « Connexion » screen. On success `AuthService.authStates()` emits the new session and `AppModel` switches to the
 * signed-in app: the screen has nothing else to do.
 */
class LoginViewModel(
    private val services: AppServices,
    email: String = "",
) : ScreenModel<LoginState>(LoginState(email = email), { state, error -> state.copy(error = error) }) {
    var email: String
        get() = current.email
        set(value) = update { it.copy(email = value) }

    var password: String
        get() = current.password
        set(value) = update { it.copy(password = value) }

    /** Signs in. Returns true on success (the password field is then cleared). */
    suspend fun signIn(): Boolean {
        if (current.isSubmitting) return false
        dismissError()
        if (current.password.isEmpty()) {
            present(MISSING_PASSWORD_MESSAGE)
            return false
        }
        val normalizedEmail = try {
            InputValidation.email(current.email)
        } catch (error: AppError) {
            present(error)
            return false
        }
        update { it.copy(isSubmitting = true) }
        try {
            services.auth.signIn(normalizedEmail, current.password)
            update { it.copy(password = "") }
            return true
        } catch (error: CancellationException) {
            throw error
        } catch (error: Exception) {
            present(error)
            return false
        } finally {
            update { it.copy(isSubmitting = false) }
        }
    }

    companion object {
        const val MISSING_PASSWORD_MESSAGE: String = "Saisissez votre mot de passe."
    }
}
