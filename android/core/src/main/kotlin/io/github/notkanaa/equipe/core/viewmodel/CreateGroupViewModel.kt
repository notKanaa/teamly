package io.github.notkanaa.equipe.core.viewmodel

import io.github.notkanaa.equipe.core.AppError
import io.github.notkanaa.equipe.core.GroupSummary
import io.github.notkanaa.equipe.core.InputValidation
import io.github.notkanaa.equipe.core.Limits
import kotlin.coroutines.cancellation.CancellationException

// Port of TeamTasksCore/ViewModels/Groups/CreateGroupViewModel.swift.

/** State of the « Nouveau groupe » sheet. */
data class CreateGroupState(
    val name: String = "",
    val nameError: String? = null,
    val isSubmitting: Boolean = false,
    /** Set on success: dismiss and show it (`router.showGroup(group.id)`). */
    val createdGroup: GroupSummary? = null,
    override val error: ErrorState? = null,
) : ErrorHolder {
    val canSubmit: Boolean get() = InputValidation.trimmed(name).isNotEmpty() && !isSubmitting
}

/**
 * « Nouveau groupe » sheet. On success [CreateGroupState.createdGroup] is set: dismiss and show it
 * (`router.showGroup(group.id)`). The creator is the group's admin.
 */
class CreateGroupViewModel(
    val session: SessionModel,
) : ScreenModel<CreateGroupState>(CreateGroupState(), { state, error -> state.copy(error = error) }) {
    var name: String
        get() = current.name
        set(value) = update { it.copy(name = value, nameError = if (it.nameError != null) nameMessage(value) else null) }

    /** Creates the group. Returns it on success, null otherwise (`nameError` or `error` set). */
    suspend fun create(): GroupSummary? {
        if (current.isSubmitting) return null
        dismissError()
        val nameError = nameMessage(current.name)
        update { it.copy(nameError = nameError) }
        if (nameError != null) return null
        update { it.copy(isSubmitting = true) }
        try {
            val group = session.services.groups.createGroup(current.name)
            update { it.copy(createdGroup = group) }
            session.feed.bumpMemberships()
            return group
        } catch (error: CancellationException) {
            throw error
        } catch (error: Exception) {
            val appError = ErrorState.from(error)?.error ?: return null
            if (appError == AppError.InvalidName) {
                update { it.copy(nameError = appError.messageFR) }
            } else {
                present(appError)
            }
            return null
        } finally {
            update { it.copy(isSubmitting = false) }
        }
    }

    companion object {
        /** 60 (code points). */
        val MAX_NAME_LENGTH: Int = Limits.groupName.last

        fun nameMessage(name: String): String? = try {
            InputValidation.groupName(name)
            null
        } catch (error: AppError) {
            AppError.InvalidName.messageFR
        }
    }
}
