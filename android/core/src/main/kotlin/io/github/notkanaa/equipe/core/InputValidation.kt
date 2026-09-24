package io.github.notkanaa.equipe.core

import java.time.Instant

/**
 * Input rules of docs/CONTRACTS.md §1, shared by the mock backend and the Supabase adapters (port of
 * TeamTasksCore/Logic/InputValidation.swift).
 *
 * Adapters apply them before calling the server, so both backends answer the same even where the server alone
 * would not: Supabase Auth accepts a blank display name (the profile trigger falls back to the e-mail), does not
 * trim e-mails, and Postgres rejects U+0000 with a generic `22P05`.
 *
 * Every function works on code points (Unicode scalars), like Postgres and Swift, never on UTF-16 units.
 */
object InputValidation {
    /**
     * Code points trimmed at both ends of every text field: U+0009–U+000D, U+0020, U+0085, U+00A0, U+1680,
     * U+2000–U+200B, U+2028, U+2029, U+202F, U+205F, U+3000.
     *
     * An explicit list because every platform's "whitespace" differs (U+200B, U+0085, U+001C–U+001F…).
     * Must match the class of the SQL `private.clean_text`.
     */
    val trimmedCodePoints: Set<Int> = buildSet {
        addAll(0x09..0x0D)
        add(0x20)
        add(0x85)
        add(0xA0)
        add(0x1680)
        addAll(0x2000..0x200B)
        add(0x2028)
        add(0x2029)
        add(0x202F)
        add(0x205F)
        add(0x3000)
    }

    /** Supabase Auth hashes passwords with bcrypt, which reads at most 72 bytes. */
    const val passwordMaxBytes: Int = 72

    /** Supabase Auth refuses longer e-mail addresses. */
    const val emailMaxBytes: Int = 255

    // region Text fields

    /** [value] without the [trimmedCodePoints] at both ends (code point by code point, like the SQL regexp). */
    fun trimmed(value: String): String {
        var start = 0
        while (start < value.length) {
            val codePoint = value.codePointAt(start)
            if (codePoint !in trimmedCodePoints) break
            start += Character.charCount(codePoint)
        }
        var end = value.length
        while (end > start) {
            val codePoint = value.codePointBefore(end)
            if (codePoint !in trimmedCodePoints) break
            end -= Character.charCount(codePoint)
        }
        return value.substring(start, end)
    }

    /** Length as Postgres `char_length` counts it: code points. */
    fun length(value: String): Int = value.codePointLength()

    /** Trimmed display name (1–50) or [AppError.InvalidDisplayName]. */
    fun displayName(raw: String): String = text(raw, Limits.displayName, AppError.InvalidDisplayName)

    /** Trimmed group name (1–60) or [AppError.InvalidName]. */
    fun groupName(raw: String): String = text(raw, Limits.groupName, AppError.InvalidName)

    /** Trimmed task title (1–200) or [AppError.InvalidTitle]. */
    fun taskTitle(raw: String): String = text(raw, Limits.taskTitle, AppError.InvalidTitle)

    /** Trimmed task details (≤ 5000, null when empty) or [AppError.InvalidDetails]. */
    fun taskDetails(raw: String): String? {
        val value = text(raw, 0..Limits.taskDetailsMax, AppError.InvalidDetails)
        return value.ifEmpty { null }
    }

    /**
     * Accepted due dates (`tasks_due_at_range`): [1970-01-01, 10000-01-01) UTC. Excludes ±infinity and BC dates,
     * which PostgREST renders in forms no JSON decoder accepts.
     */
    val dueDateRange: OpenEndRange<Instant> = Instant.EPOCH..<Instant.ofEpochSecond(253_402_300_800L)

    /**
     * null (no due date) or a date inside [dueDateRange], else [AppError.InvalidInput] (SQL `invalid_due_at`).
     * Checked after the title and the details, before the assignees (same order as the SQL).
     */
    fun dueDate(date: Instant?): Instant? {
        if (date == null) return null
        if (date !in dueDateRange) throw AppError.InvalidInput
        return date
    }

    /** Postgres `text` cannot hold U+0000: such input gets the field's validation error. */
    private fun text(raw: String, lengths: IntRange, error: AppError): String {
        val value = trimmed(raw)
        if (length(value) !in lengths || value.indexOf('\u0000') >= 0) throw error
        return value
    }

    // endregion

    // region Auth

    /**
     * Trimmed and lowercased e-mail (Supabase Auth stores e-mails lowercased but does not trim them, so the app
     * normalizes every e-mail it sends to Auth).
     */
    fun normalizedEmail(raw: String): String = trimmed(raw).lowercase()

    /**
     * The normalized e-mail, or [AppError.InvalidEmail] unless it has the HTML5 syntax Supabase Auth checks: before
     * the `@`, one or more ASCII letters, digits or characters among .!#$%&'*+/=?^_{|}~- and the backtick; after it,
     * dot-separated labels of 1–63 ASCII letters, digits or hyphens, starting and ending with a letter or digit
     * (`user@localhost` is valid). At most 255 bytes.
     */
    fun email(raw: String): String {
        val value = trimmed(raw)
        if (utf8Length(value) > emailMaxBytes || !hasEmailSyntax(value)) throw AppError.InvalidEmail
        return value.lowercase()
    }

    /**
     * Password length in UTF-8 bytes, like Supabase Auth: at least [Limits.passwordMinLength]
     * ([AppError.WeakPassword]), at most [passwordMaxBytes] ([AppError.InvalidInput]).
     */
    fun password(value: String) {
        val bytes = utf8Length(value)
        if (bytes < Limits.passwordMinLength) throw AppError.WeakPassword
        if (bytes > passwordMaxBytes) throw AppError.InvalidInput
    }

    /** Normalized sign-up input (Swift returns the tuple `(email:, displayName:)`). */
    data class SignUpInput(val email: String, val displayName: String)

    /**
     * Sign-up input, checked in this order: e-mail, password, display name. Returns the normalized e-mail and the
     * trimmed display name.
     */
    fun signUp(email: String, password: String, displayName: String): SignUpInput {
        val normalizedEmail = email(email)
        password(password)
        val name = displayName(displayName)
        return SignUpInput(normalizedEmail, name)
    }

    private val emailLocalCodePoints: Set<Int> =
        "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.!#$%&'*+/=?^_`{|}~-".map { it.code }.toSet()

    private fun hasEmailSyntax(value: String): Boolean {
        val codePoints = value.codePoints().toArray()
        val at = codePoints.indexOf('@'.code)
        if (at <= 0) return false
        for (index in 0 until at) {
            if (codePoints[index] !in emailLocalCodePoints) return false
        }
        // Split the domain on "." keeping empty labels (Swift `omittingEmptySubsequences: false`).
        val labels = mutableListOf<List<Int>>()
        var current = mutableListOf<Int>()
        for (index in at + 1 until codePoints.size) {
            val codePoint = codePoints[index]
            if (codePoint == '.'.code) {
                labels.add(current)
                current = mutableListOf()
            } else {
                current.add(codePoint)
            }
        }
        labels.add(current)
        return labels.all { label ->
            label.size in 1..63 &&
                isAsciiAlphanumeric(label.first()) &&
                isAsciiAlphanumeric(label.last()) &&
                label.all { isAsciiAlphanumeric(it) || it == '-'.code }
        }
    }

    private fun isAsciiAlphanumeric(codePoint: Int): Boolean =
        codePoint in 'a'.code..'z'.code || codePoint in 'A'.code..'Z'.code || codePoint in '0'.code..'9'.code

    private fun utf8Length(value: String): Int = value.toByteArray(Charsets.UTF_8).size

    // endregion
}
