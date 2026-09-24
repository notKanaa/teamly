package io.github.notkanaa.equipe.core

/**
 * Maps backend (PostgREST / Postgres) errors to [AppError].
 * Server convention (see docs/CONTRACTS.md §4.2): business errors use SQLSTATE `P0001` with the error code as the
 * message (e.g. `last_admin`); permission errors use SQLSTATE `42501`.
 */
object BackendErrorMapper {
    /** Business error codes raised by the SQL functions/triggers (exception message). */
    val messageCodes: Map<String, AppError> = mapOf(
        "not_authenticated" to AppError.NotAuthenticated,
        "invalid_display_name" to AppError.InvalidDisplayName,
        "invalid_name" to AppError.InvalidName,
        "invalid_title" to AppError.InvalidTitle,
        "invalid_details" to AppError.InvalidDetails,
        "invalid_due_at" to AppError.InvalidInput,
        "invalid_input" to AppError.InvalidInput,
        "invalid_code" to AppError.InvalidCode,
        "rate_limited" to AppError.RateLimited,
        "forbidden" to AppError.Forbidden,
        "forbidden_fields" to AppError.ForbiddenFields,
        "immutable_field" to AppError.Forbidden,
        "last_admin" to AppError.LastAdmin,
        "not_member" to AppError.NotMember,
        "cannot_remove_self" to AppError.CannotRemoveSelf,
        "assignee_not_member" to AppError.AssigneeNotMember,
        "too_many_assignees" to AppError.TooManyAssignees,
        "task_not_found" to AppError.NotFound,
        "group_not_found" to AppError.NotFound,
    )

    /**
     * Maps by message first, then SQLSTATE, then HTTP status.
     *
     * @param code SQLSTATE or PostgREST code (e.g. `P0001`, `42501`, `PGRST116`).
     * @param message error message (business code for `P0001`).
     * @param httpStatus HTTP status if known.
     */
    fun map(code: String?, message: String?, httpStatus: Int? = null): AppError {
        if (message != null) {
            messageCodes[trimWhitespacesAndNewlines(message)]?.let { return it }
        }
        // PostgREST answers a request without a valid session (anon role) with HTTP 401 + 42501.
        // Our own 42501 errors ('forbidden', 'forbidden_fields') are HTTP 403 and matched above.
        if (code == "42501" && httpStatus == 401) return AppError.NotAuthenticated
        when (code) {
            "42501" -> return AppError.Forbidden
            "23505" -> return AppError.Conflict
            "23514", "22001", "22P02", "22P05", "23502" -> return AppError.InvalidInput
            "23503" -> return AppError.NotFound
            "PGRST116" -> return AppError.NotFound
            "PGRST301", "PGRST302" -> return AppError.NotAuthenticated
        }
        when (httpStatus) {
            401 -> return AppError.NotAuthenticated
            403 -> return AppError.Forbidden
            404 -> return AppError.NotFound
            409 -> return AppError.Conflict
        }
        return AppError.Unknown(listOfNotNull(code, message).joinToString(" "))
    }

    /** Foundation's `trimmingCharacters(in: .whitespacesAndNewlines)`: Unicode Z* separators, U+0009–U+000D, U+0085. */
    private fun trimWhitespacesAndNewlines(value: String): String {
        fun isWhitespace(codePoint: Int): Boolean = codePoint in 0x09..0x0D || codePoint == 0x85 ||
            when (Character.getType(codePoint).toByte()) {
                Character.SPACE_SEPARATOR, Character.LINE_SEPARATOR, Character.PARAGRAPH_SEPARATOR -> true
                else -> false
            }
        var start = 0
        while (start < value.length) {
            val codePoint = value.codePointAt(start)
            if (!isWhitespace(codePoint)) break
            start += Character.charCount(codePoint)
        }
        var end = value.length
        while (end > start) {
            val codePoint = value.codePointBefore(end)
            if (!isWhitespace(codePoint)) break
            end -= Character.charCount(codePoint)
        }
        return value.substring(start, end)
    }
}
