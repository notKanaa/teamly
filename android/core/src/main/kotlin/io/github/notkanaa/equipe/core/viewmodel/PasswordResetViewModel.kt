package io.github.notkanaa.equipe.core.viewmodel

import io.github.notkanaa.equipe.core.AppError
import io.github.notkanaa.equipe.core.AppServices
import io.github.notkanaa.equipe.core.InputValidation
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.withContext
import java.util.UUID
import kotlin.coroutines.cancellation.CancellationException

// Port of TeamTasksCore/ViewModels/Auth/PasswordResetViewModel.swift.

/** Steps of the « Mot de passe oublié » flow. */
enum class PasswordResetStep {
    /** Enter the account's e-mail. */
    EMAIL,

    /** Enter the 6-digit code received by e-mail (with « Renvoyer le code »). */
    CODE,

    /** Choose the new password (the user is signed in with a recovery session). */
    NEW_PASSWORD,

    /** Password changed; the app opens. */
    DONE,
}

/** State of the « Mot de passe oublié » flow. */
data class PasswordResetState(
    val step: PasswordResetStep = PasswordResetStep.EMAIL,
    val email: String = "",
    /** Digits only, at most 6 (anything else typed or pasted is dropped). */
    val code: String = "",
    val newPassword: String = "",
    val passwordConfirmation: String = "",
    val isSubmitting: Boolean = false,
    /** Neutral information (« Si un compte existe… », « Un nouveau code… »). */
    val infoMessage: String? = null,
    override val error: ErrorState? = null,
) : ErrorHolder {
    /** « Mot de passe oublié » (e-mail and code steps), « Nouveau mot de passe » (new password and done steps). */
    val title: String
        get() = when (step) {
            PasswordResetStep.EMAIL, PasswordResetStep.CODE -> "Mot de passe oublié"
            PasswordResetStep.NEW_PASSWORD, PasswordResetStep.DONE -> "Nouveau mot de passe"
        }

    val canSendCode: Boolean get() = InputValidation.trimmed(email).isNotEmpty() && !isSubmitting

    val canVerifyCode: Boolean get() = code.length == PasswordResetViewModel.CODE_LENGTH && !isSubmitting

    val canUpdatePassword: Boolean
        get() = newPassword.isNotEmpty() && passwordConfirmation.isNotEmpty() && !isSubmitting
}

/**
 * « Mot de passe oublié » flow: e-mail → 6-digit code received by e-mail → new password.
 *
 * Create it with `AppModel.startPasswordReset(email)`: verifying the code signs the user in (recovery session), and the
 * `AppModel` then shows `AppPhase.PasswordRecovery(this)` instead of the app until the new password is set
 * (`isInPasswordRecovery`).
 */
class PasswordResetViewModel(
    private val services: AppServices,
    email: String = "",
    private val app: AppModel? = null,
) : ScreenModel<PasswordResetState>(PasswordResetState(email = email), { state, error -> state.copy(error = error) }) {
    /** Unique per flow (Swift `Identifiable`). */
    val id: UUID = UUID.randomUUID()

    var email: String
        get() = current.email
        set(value) = update { it.copy(email = value) }

    /** Digits only, at most 6: whatever is typed or pasted is sanitized ([sanitizedCode]). */
    var code: String
        get() = current.code
        set(value) = update { it.copy(code = sanitizedCode(value)) }

    var newPassword: String
        get() = current.newPassword
        set(value) = update { it.copy(newPassword = value) }

    var passwordConfirmation: String
        get() = current.passwordConfirmation
        set(value) = update { it.copy(passwordConfirmation = value) }

    // region Steps

    /**
     * Sends the code to the e-mail and moves to the code step. Unknown addresses succeed silently (no account
     * enumeration), hence the neutral message.
     */
    suspend fun sendCode(): Boolean {
        if (current.isSubmitting) return false
        dismissError()
        val address = try {
            InputValidation.email(current.email)
        } catch (error: AppError) {
            present(error)
            return false
        }
        update { it.copy(isSubmitting = true) }
        try {
            services.auth.sendPasswordReset(address)
            update {
                it.copy(
                    email = address,
                    code = "",
                    infoMessage = "Si un compte existe pour $address, un code à 6 chiffres vient d’y être envoyé.",
                    step = PasswordResetStep.CODE,
                )
            }
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

    /** Sends a new code (code step). */
    suspend fun resendCode(): Boolean {
        if (current.step != PasswordResetStep.CODE || current.isSubmitting) return false
        dismissError()
        update { it.copy(isSubmitting = true) }
        try {
            services.auth.sendPasswordReset(InputValidation.normalizedEmail(current.email))
            update { it.copy(code = "", infoMessage = RESENT_MESSAGE) }
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

    /**
     * Verifies the code; on success the user is signed in with a recovery session and the flow moves to the new
     * password step.
     */
    suspend fun verifyCode(): Boolean {
        if (current.step != PasswordResetStep.CODE || current.isSubmitting) return false
        dismissError()
        if (current.code.length != CODE_LENGTH) {
            present(INCOMPLETE_CODE_MESSAGE, AppError.OtpInvalid)
            return false
        }
        update { it.copy(isSubmitting = true) }
        try {
            app?.beginPasswordRecovery(this)
            try {
                services.auth.verifyRecoveryCode(InputValidation.normalizedEmail(current.email), current.code)
            } catch (error: Exception) {
                withContext(NonCancellable) { app?.cancelPasswordRecovery() }
                if (error is CancellationException) throw error
                present(error)
                return false
            }
            update { it.copy(infoMessage = null, step = PasswordResetStep.NEW_PASSWORD) }
            return true
        } finally {
            update { it.copy(isSubmitting = false) }
        }
    }

    /** Sets the new password, then the app opens. */
    suspend fun updatePassword(): Boolean {
        if (current.step != PasswordResetStep.NEW_PASSWORD || current.isSubmitting) return false
        dismissError()
        val message = SignUpViewModel.passwordMessage(current.newPassword)
        if (message != null) {
            present(message, AppError.WeakPassword)
            return false
        }
        if (current.newPassword != current.passwordConfirmation) {
            present(MISMATCH_MESSAGE, AppError.InvalidInput)
            return false
        }
        update { it.copy(isSubmitting = true) }
        try {
            services.auth.updatePassword(current.newPassword)
            update {
                it.copy(newPassword = "", passwordConfirmation = "", infoMessage = DONE_MESSAGE, step = PasswordResetStep.DONE)
            }
            app?.finishPasswordRecovery()
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

    /** Code step → e-mail step (to fix the address). */
    fun goBack() {
        if (current.step != PasswordResetStep.CODE) return
        update { it.copy(error = null, infoMessage = null, code = "", step = PasswordResetStep.EMAIL) }
    }

    /**
     * The recovery session ended before the new password was set (revoked, refresh refused): back to the e-mail step
     * (address kept) with an explanation, since the code was used up.
     */
    internal fun recoverySessionEnded() {
        if (current.step != PasswordResetStep.NEW_PASSWORD) return
        update {
            it.copy(newPassword = "", passwordConfirmation = "", code = "", infoMessage = null, step = PasswordResetStep.EMAIL)
        }
        present(RECOVERY_ENDED_MESSAGE, AppError.NotAuthenticated)
    }

    /**
     * Leaves the flow. At the new password step the recovery session is closed (local sign-out): the password was not
     * changed, so the login screen comes back. Otherwise the sheet is closed (`AppModel.passwordReset` becomes null).
     */
    suspend fun cancel() {
        dismissError()
        when (current.step) {
            PasswordResetStep.NEW_PASSWORD -> app?.abandonPasswordRecovery()
            PasswordResetStep.EMAIL, PasswordResetStep.CODE, PasswordResetStep.DONE -> {
                if (app != null && app.passwordReset === this) {
                    app.passwordReset = null
                }
            }
        }
    }

    // endregion

    override fun toString(): String = "PasswordResetViewModel(id=$id, step=${current.step})"

    companion object {
        const val CODE_LENGTH: Int = 6
        const val MISMATCH_MESSAGE: String = "Les mots de passe ne correspondent pas."
        const val INCOMPLETE_CODE_MESSAGE: String = "Saisissez les 6 chiffres du code reçu par e-mail."
        const val RESENT_MESSAGE: String = "Un nouveau code vient d’être envoyé."
        const val DONE_MESSAGE: String = "Votre mot de passe a été modifié."

        /** The recovery session ended before the new password was set. */
        const val RECOVERY_ENDED_MESSAGE: String =
            "La session de réinitialisation a expiré avant l’enregistrement du nouveau mot de passe. Demandez un nouveau code."

        /** Keeps the ASCII digits, at most [CODE_LENGTH]. */
        fun sanitizedCode(input: String): String {
            val builder = StringBuilder(CODE_LENGTH)
            for (character in input) {
                if (builder.length == CODE_LENGTH) break
                if (character in '0'..'9') builder.append(character)
            }
            return builder.toString()
        }
    }
}
