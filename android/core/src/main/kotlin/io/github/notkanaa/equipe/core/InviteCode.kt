package io.github.notkanaa.equipe.core

/**
 * 8-character group invite code using an unambiguous alphabet (no 0/O/1/I).
 * Must stay in sync with `private.generate_invite_code()` and the `group_invites.code` check constraint.
 *
 * Built with [parse] (Swift's failable `InviteCode(_:)`); equality is on [value].
 */
class InviteCode private constructor(
    /** Normalized value, e.g. `ABCDEFGH`. */
    val value: String,
) {
    /** Display form, e.g. `ABCD-EFGH`. */
    val formatted: String get() = value.substring(0, length / 2) + "-" + value.substring(length / 2)

    override fun toString(): String = formatted

    override fun equals(other: Any?): Boolean = other is InviteCode && other.value == value

    override fun hashCode(): Int = value.hashCode()

    companion object {
        const val ALPHABET: String = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"

        /** The 32 characters of a code. */
        val alphabet: Set<Char> = ALPHABET.toSet()

        const val length: Int = 8

        /** Accepts user input such as `abcd-efgh` or ` ABCD EFGH `. Returns null if it cannot be a valid code. */
        fun parse(input: String): InviteCode? {
            val normalized = normalize(input)
            if (normalized.length != length || !normalized.all { it in alphabet }) return null
            return InviteCode(normalized)
        }

        /**
         * Uppercases (full case mapping: `ß` → `SS`), then keeps only the code points A–Z and 0–9 (same rule as the
         * SQL `join_group_by_code`, which works per code point: "ĹYLAS234" → "LYLAS234").
         */
        fun normalize(input: String): String {
            val builder = StringBuilder()
            input.uppercase().codePoints().forEach { codePoint ->
                if (codePoint in 'A'.code..'Z'.code || codePoint in '0'.code..'9'.code) {
                    builder.appendCodePoint(codePoint)
                }
            }
            return builder.toString()
        }
    }
}
