package io.github.notkanaa.equipe.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test
import java.time.Instant

/** Port of Logic/InputValidationTests.swift (+ due dates). */
class InputValidationTest {
    private fun scalar(codePoint: Int): String = String(Character.toChars(codePoint))

    /** The pinned trim list (docs/CONTRACTS.md §1), the same on every platform. */
    private val pinned: List<Int> = listOf(0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x20, 0x85, 0xA0, 0x1680) +
        (0x2000..0x200B) + listOf(0x2028, 0x2029, 0x202F, 0x205F, 0x3000)

    @Test
    fun trimsExactlyThePinnedCodePoints() {
        val found = (1..0x3000).filter { value ->
            val s = scalar(value)
            InputValidation.trimmed("${s}x$s") == "x"
        }
        assertEquals(pinned, found)
        for (value in listOf(0x1C, 0x1D, 0x1E, 0x1F, 0x180E, 0xFEFF)) {
            val text = scalar(value) + "x"
            assertEquals("U+${Integer.toHexString(value)} is not trimmed", text, InputValidation.trimmed(text))
        }
    }

    @Test
    fun trimsCodePointsNotGraphemes() {
        // A combining accent after a space stays (like the SQL regexp, which works on code points).
        assertEquals("́x", InputValidation.trimmed(" ́x "))
        assertEquals("Titre", InputValidation.trimmed("　​ Titre \n\t"))
        assertEquals("", InputValidation.trimmed(" \n "))
        assertEquals("", InputValidation.trimmed(""))
    }

    @Test
    fun textFieldLimitsCountUnicodeScalars() {
        assertEquals("Zoé", InputValidation.displayName("  Zoé  "))
        assertEquals(50, InputValidation.displayName("é".repeat(50)).length)
        assertThrowsAppError(AppError.InvalidDisplayName) { InputValidation.displayName("é".repeat(51)) }
        assertThrowsAppError(AppError.InvalidDisplayName) { InputValidation.displayName(" ​ ") }
        assertThrowsAppError(AppError.InvalidName) { InputValidation.groupName("x".repeat(61)) }
        assertEquals(60, InputValidation.groupName("x".repeat(60)).length)
        assertThrowsAppError(AppError.InvalidTitle) { InputValidation.taskTitle("") }
        assertThrowsAppError(AppError.InvalidTitle) { InputValidation.taskTitle("x".repeat(201)) }
        assertNull(InputValidation.taskDetails("   "))
        assertEquals("d", InputValidation.taskDetails(" d "))
        assertThrowsAppError(AppError.InvalidDetails) { InputValidation.taskDetails("x".repeat(5001)) }
    }

    /** Lengths are code points, not UTF-16 units: 50 emoji (100 UTF-16 units) are a valid display name. */
    @Test
    fun lengthsCountCodePointsNotUtf16Units() {
        val emoji = "😀"
        assertEquals(1, InputValidation.length(emoji))
        assertEquals(emoji.repeat(50), InputValidation.displayName(emoji.repeat(50)))
        assertThrowsAppError(AppError.InvalidDisplayName) { InputValidation.displayName(emoji.repeat(51)) }
    }

    /** Postgres `text` cannot hold U+0000. */
    @Test
    fun nulIsRejectedWithTheFieldsError() {
        assertThrowsAppError(AppError.InvalidDisplayName) { InputValidation.displayName("a\u0000") }
        assertThrowsAppError(AppError.InvalidName) { InputValidation.groupName("a\u0000") }
        assertThrowsAppError(AppError.InvalidTitle) { InputValidation.taskTitle("a\u0000b") }
        assertThrowsAppError(AppError.InvalidDetails) { InputValidation.taskDetails("\u0000") }
    }

    @Test
    fun passwordsAreMeasuredInUTF8Bytes() {
        InputValidation.password("éééé") // 8 bytes
        InputValidation.password("😀😀") // 8 bytes
        InputValidation.password("a".repeat(72))
        assertThrowsAppError(AppError.WeakPassword) { InputValidation.password("abc1234") }
        assertThrowsAppError(AppError.WeakPassword) { InputValidation.password("ééé1") }
        assertThrowsAppError(AppError.InvalidInput) { InputValidation.password("a".repeat(73)) }
    }

    @Test
    fun emailsAreNormalizedAndCheckedLikeSupabaseAuth() {
        assertEquals("zoe.leroy@example.com", InputValidation.email("  Zoe.Leroy@Example.COM "))
        assertEquals("a@b.fr", InputValidation.normalizedEmail(" A@B.fr\n"))
        for (valid in listOf("user@localhost", ".x@example.com", "a..b@example.com", "o'neil+tag@sub-domain.example.fr", "1@2.3")) {
            assertEquals(valid, valid.lowercase(), InputValidation.email(valid))
        }
        val label63 = "a".repeat(63)
        assertEquals("x@$label63.fr", InputValidation.email("x@$label63.fr"))
        val invalid = listOf(
            "", "x", "x@", "@x.fr", "x@@x.fr", "x@y@z.fr", "x y@z.fr", "ü@x.fr", "x@exämple.fr", "x@-x.fr",
            "x@x-.fr", "x@x..fr", "x@.x.fr", "x@x.fr.", "x@${label63}a.fr", "x@x_y.fr", "a".repeat(251) + "@x.fr",
        )
        for (email in invalid) {
            assertThrowsAppError(AppError.InvalidEmail, email) { InputValidation.email(email) }
        }
    }

    @Test
    fun signUpChecksEmailThenPasswordThenName() {
        assertThrowsAppError(AppError.InvalidEmail) {
            InputValidation.signUp(email = "x", password = "court", displayName = "")
        }
        assertThrowsAppError(AppError.WeakPassword) {
            InputValidation.signUp(email = "a@b.fr", password = "court", displayName = "")
        }
        assertThrowsAppError(AppError.InvalidDisplayName) {
            InputValidation.signUp(email = "a@b.fr", password = "motdepasse", displayName = " ")
        }
        val input = InputValidation.signUp(email = " A@B.fr ", password = "motdepasse", displayName = " Zoé ")
        assertEquals("a@b.fr", input.email)
        assertEquals("Zoé", input.displayName)
    }

    /** `tasks_due_at_range`: [1970-01-01, 10000-01-01) UTC. */
    @Test
    fun dueDatesMustBeInTheSqlRange() {
        assertNull(InputValidation.dueDate(null))
        assertEquals(Instant.EPOCH, InputValidation.dueDate(Instant.EPOCH))
        val lastNanosecond = Instant.parse("9999-12-31T23:59:59.999999999Z")
        assertEquals(lastNanosecond, InputValidation.dueDate(lastNanosecond))
        assertThrowsAppError(AppError.InvalidInput) { InputValidation.dueDate(Instant.ofEpochSecond(253_402_300_800L)) }
        assertThrowsAppError(AppError.InvalidInput) { InputValidation.dueDate(Instant.ofEpochSecond(-1)) }
    }
}
