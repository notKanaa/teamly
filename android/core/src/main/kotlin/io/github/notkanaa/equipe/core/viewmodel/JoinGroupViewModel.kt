package io.github.notkanaa.equipe.core.viewmodel

import io.github.notkanaa.equipe.core.AppError
import io.github.notkanaa.equipe.core.InviteCode
import io.github.notkanaa.equipe.core.JoinResult
import kotlin.coroutines.cancellation.CancellationException

// Port of TeamTasksCore/ViewModels/Groups/JoinGroupViewModel.swift.

/** State of the « Rejoindre un groupe » sheet. */
data class JoinGroupState(
    /** Live-formatted code (`ABCD-EFGH`). */
    val code: String = "",
    val isSubmitting: Boolean = false,
    /** Set on success: dismiss and show the group (`router.showGroup(result.groupId)`). */
    val result: JoinResult? = null,
    override val error: ErrorState? = null,
) : ErrorHolder {
    /** 8 characters typed. */
    val isCodeComplete: Boolean get() = InviteCode.normalize(code).length == InviteCode.length

    val canSubmit: Boolean get() = isCodeComplete && !isSubmitting

    /** « Vous avez rejoint « X ». » / « Vous faites déjà partie de « X ». » */
    val resultMessage: String?
        get() {
            val result = result ?: return null
            return if (result.alreadyMember) {
                "Vous faites déjà partie de « ${result.groupName} »."
            } else {
                "Vous avez rejoint « ${result.groupName} »."
            }
        }
}

/**
 * « Rejoindre un groupe » sheet. The code field is formatted live as `ABCD-EFGH` (uppercase, only letters and digits,
 * 8 characters at most). On success [JoinGroupState.result] is set: dismiss and show the group
 * (`router.showGroup(result.groupId)`); [JoinGroupState.resultMessage] says whether it was joined or already joined.
 */
class JoinGroupViewModel(
    val session: SessionModel,
    code: String = "",
) : ScreenModel<JoinGroupState>(JoinGroupState(code = format(code)), { state, error -> state.copy(error = error) }) {
    /** Live-formatted code: whatever is typed or pasted becomes `ABCD-EFGH`. */
    var code: String
        get() = current.code
        set(value) = update { it.copy(code = format(value)) }

    /**
     * Joins with the code. Invalid codes (checked locally, then by the server), too many attempts (« Réessayez dans une
     * heure ») and network errors are shown in `error`.
     */
    suspend fun join(): JoinResult? {
        if (current.isSubmitting) return null
        dismissError()
        if (!current.isCodeComplete) {
            present(INCOMPLETE_CODE_MESSAGE, AppError.InvalidCode)
            return null
        }
        val inviteCode = InviteCode.parse(current.code)
        if (inviteCode == null) {
            present(AppError.InvalidCode)
            return null
        }
        update { it.copy(isSubmitting = true) }
        try {
            val joined = session.services.groups.join(inviteCode)
            update { it.copy(result = joined) }
            session.feed.bumpMemberships()
            session.feed.bump(joined.groupId)
            session.feed.bumpMyTasks()
            return joined
        } catch (error: CancellationException) {
            throw error
        } catch (error: Exception) {
            present(error)
            return null
        } finally {
            update { it.copy(isSubmitting = false) }
        }
    }

    companion object {
        const val PLACEHOLDER: String = "ABCD-EFGH"
        const val INCOMPLETE_CODE_MESSAGE: String = "Le code contient 8 caractères, par exemple ABCD-EFGH."

        /** `abcd efgh` → `ABCD-EFGH`, `abcde` → `ABCD-E`; keeps at most 8 letters or digits. */
        fun format(input: String): String {
            val characters = InviteCode.normalize(input).take(InviteCode.length)
            val half = InviteCode.length / 2
            if (characters.length <= half) return characters
            return characters.substring(0, half) + "-" + characters.substring(half)
        }
    }
}
