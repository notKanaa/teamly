package io.github.notkanaa.equipe.core

import java.text.Normalizer
import java.util.Locale
import java.util.UUID

// The backend (Postgres `char_length`, regexps) and the Swift clients work on Unicode scalars (code points), while
// Kotlin strings are UTF-16: these helpers keep the Android client consistent with them.

/**
 * Swift's `UUID.uuidString`: the upper-case form. Every tie-break "by id" of the contract (docs/CONTRACTS.md §4.3,
 * sorted `assigneeIds`) compares this string. (`UUID.compareTo` compares signed longs: never use it for ordering.)
 */
val UUID.uuidString: String get() = toString().uppercase(Locale.ROOT)

/** Orders UUIDs by [uuidString], like the Swift implementations. */
val UuidStringOrder: Comparator<UUID> = Comparator { lhs, rhs -> lhs.uuidString.compareTo(rhs.uuidString) }

/** Number of code points (Unicode scalars), like Postgres `char_length` and Swift `unicodeScalars.count`. */
fun String.codePointLength(): Int = codePointCount(0, length)

/**
 * Compares two strings code point by code point (Kotlin's `compareTo` compares UTF-16 units, which orders
 * characters above U+FFFF before U+E000–U+FFFF).
 */
fun compareCodePoints(lhs: String, rhs: String): Int {
    var i = 0
    var j = 0
    while (i < lhs.length && j < rhs.length) {
        val left = lhs.codePointAt(i)
        val right = rhs.codePointAt(j)
        if (left != right) return left.compareTo(right)
        i += Character.charCount(left)
        j += Character.charCount(right)
    }
    return when {
        i < lhs.length -> 1
        j < rhs.length -> -1
        else -> 0
    }
}

/**
 * Swift `String` order: canonically equivalent strings are equal, the others are ordered by the code points of
 * their NFC form.
 */
fun compareLikeSwift(lhs: String, rhs: String): Int = compareCodePoints(nfc(lhs), nfc(rhs))

internal fun nfc(value: String): String = Normalizer.normalize(value, Normalizer.Form.NFC)
