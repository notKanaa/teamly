package io.github.notkanaa.equipe.mocks

import io.github.notkanaa.equipe.core.AppError
import io.github.notkanaa.equipe.core.InputValidation
import io.github.notkanaa.equipe.core.Limits
import java.time.Instant
import java.util.UUID

/**
 * Server-side validation of docs/CONTRACTS.md §1: the shared rules of [InputValidation] (the Supabase adapters apply
 * the same ones before calling the server), plus the membership rule of assignees.
 */
internal object InputRules {
    fun trimmed(value: String): String = InputValidation.trimmed(value)

    fun displayName(raw: String): String = InputValidation.displayName(raw)

    fun groupName(raw: String): String = InputValidation.groupName(raw)

    fun title(raw: String): String = InputValidation.taskTitle(raw)

    /** Empty (after trimming) is stored as NULL. */
    fun details(raw: String): String? = InputValidation.taskDetails(raw)

    /** NULL or within [1970, 10000) UTC, else [AppError.InvalidInput] (SQL `invalid_due_at`). */
    fun dueDate(date: Instant?): Instant? = InputValidation.dueDate(date)

    /** ≤ 20 distinct users, all members of the group. */
    fun assignees(ids: Set<UUID>, groupId: UUID, data: BackendData) {
        if (ids.size > Limits.maxAssignees) throw AppError.TooManyAssignees
        if (!ids.all { data.isMember(it, groupId) }) throw AppError.AssigneeNotMember
    }

    /** Normalized e-mail (trimmed, lowercased) or [AppError.InvalidEmail]. */
    fun email(raw: String): String = InputValidation.email(raw)

    fun normalizedEmail(raw: String): String = InputValidation.normalizedEmail(raw)

    /** 8–72 UTF-8 bytes, like Supabase Auth. */
    fun password(value: String) {
        InputValidation.password(value)
    }
}
