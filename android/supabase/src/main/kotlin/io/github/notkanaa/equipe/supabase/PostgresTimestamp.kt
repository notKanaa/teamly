package io.github.notkanaa.equipe.supabase

import java.time.Instant

/**
 * `timestamptz` values as PostgREST exchanges them (docs/CONTRACTS.md §4.3). Port of PostgresTimestamp.swift.
 *
 * - Parsing accepts ISO-8601 with an offset (`Z`, `±HH`, `±HHMM`, `±HH:MM`, optional seconds) and **0 to 6**
 *   fractional digits (more are rounded to the microsecond), with a `T` or a space between date and time.
 * - Formatting always writes UTC with exactly 6 fractional digits (`2026-09-24T08:00:00.123456Z`): the server keeps
 *   microseconds, so a timestamp read from the server and sent back as a filter value (e.g. `assignments(since)`)
 *   designates exactly the same instant.
 *
 * Pure integer arithmetic (proleptic Gregorian calendar, H. Hinnant's algorithms), identical to the Swift client.
 */
internal object PostgresTimestamp {
    private const val MICROS_PER_SECOND = 1_000_000L
    private const val SECONDS_PER_DAY = 86_400L

    /** 0001-01-01T00:00:00Z and 9999-12-31T23:59:59.999999Z: formatted instants are clamped to 4-digit years. */
    private const val MIN_MICROS = -62_135_596_800L * MICROS_PER_SECOND
    private const val MAX_MICROS = 253_402_300_799L * MICROS_PER_SECOND + 999_999L

    // region Formatting

    /** UTC, 6 fractional digits, `Z` suffix. */
    fun format(instant: Instant): String = formatMicros(epochMicroseconds(instant))

    /** Whole microseconds since 1970, rounded to the nearest microsecond (half up), clamped to years 1–9999. */
    fun epochMicroseconds(instant: Instant): Long {
        val seconds = instant.epochSecond
        if (seconds < MIN_MICROS / MICROS_PER_SECOND) return MIN_MICROS
        if (seconds > MAX_MICROS / MICROS_PER_SECOND) return MAX_MICROS
        return (seconds * MICROS_PER_SECOND + (instant.nano + 500) / 1_000).coerceIn(MIN_MICROS, MAX_MICROS)
    }

    /** The instant of a number of microseconds since 1970. */
    fun instant(epochMicroseconds: Long): Instant = Instant.ofEpochSecond(
        Math.floorDiv(epochMicroseconds, MICROS_PER_SECOND),
        Math.floorMod(epochMicroseconds, MICROS_PER_SECOND) * 1_000,
    )

    private fun formatMicros(micros: Long): String {
        val seconds = Math.floorDiv(micros, MICROS_PER_SECOND)
        val fraction = micros - seconds * MICROS_PER_SECOND
        val days = Math.floorDiv(seconds, SECONDS_PER_DAY)
        val secondOfDay = seconds - days * SECONDS_PER_DAY
        val (year, month, day) = civil(days)
        val hour = secondOfDay / 3_600
        val minute = (secondOfDay % 3_600) / 60
        val second = secondOfDay % 60
        return pad(year, 4) + "-" + pad(month, 2) + "-" + pad(day, 2) + "T" + pad(hour, 2) + ":" + pad(minute, 2) +
            ":" + pad(second, 2) + "." + pad(fraction, 6) + "Z"
    }

    // endregion

    // region Parsing

    /** The instant of [text], or null when it is not a timestamp of the accepted forms. */
    fun parse(text: String): Instant? {
        val scanner = Scanner(text.toByteArray(Charsets.UTF_8))
        val year = scanner.number(4) ?: return null
        if (!scanner.skip('-')) return null
        val month = scanner.number(2) ?: return null
        if (!scanner.skip('-')) return null
        val day = scanner.number(2) ?: return null
        if (!(scanner.skip('T') || scanner.skip('t') || scanner.skip(' '))) return null
        val hour = scanner.number(2) ?: return null
        if (!scanner.skip(':')) return null
        val minute = scanner.number(2) ?: return null
        if (!scanner.skip(':')) return null
        val second = scanner.number(2) ?: return null
        if (month !in 1L..12L || day !in 1L..daysIn(month, year) || hour !in 0L..23L || minute !in 0L..59L ||
            second !in 0L..59L
        ) {
            return null
        }

        var micros = 0L
        if (scanner.skip('.')) {
            micros = scanner.fraction() ?: return null
        }

        val offset: Long
        if (scanner.skip('Z') || scanner.skip('z')) {
            offset = 0
        } else {
            val sign = scanner.sign() ?: return null
            val offsetHours = scanner.number(2) ?: return null
            if (offsetHours > 23) return null
            var offsetSeconds = offsetHours * 3_600
            scanner.skip(':')
            val offsetMinutes = scanner.number(2)
            if (offsetMinutes != null) {
                if (offsetMinutes > 59) return null
                offsetSeconds += offsetMinutes * 60
                scanner.skip(':')
                val offsetSecondsPart = scanner.number(2)
                if (offsetSecondsPart != null) {
                    if (offsetSecondsPart > 59) return null
                    offsetSeconds += offsetSecondsPart
                }
            }
            offset = sign * offsetSeconds
        }
        if (!scanner.isAtEnd) return null

        val days = daysFromCivil(year, month, day)
        val seconds = days * SECONDS_PER_DAY + hour * 3_600 + minute * 60 + second - offset
        return instant(seconds * MICROS_PER_SECOND + micros)
    }

    // endregion

    // region Calendar arithmetic (proleptic Gregorian, H. Hinnant's algorithms)

    private fun daysFromCivil(year: Long, month: Long, day: Long): Long {
        val y = if (month <= 2) year - 1 else year
        val era = Math.floorDiv(y, 400L)
        val yearOfEra = y - era * 400
        val monthIndex = if (month > 2) month - 3 else month + 9
        val dayOfYear = (153 * monthIndex + 2) / 5 + day - 1
        val dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
        return era * 146_097 + dayOfEra - 719_468
    }

    private fun civil(days: Long): Triple<Long, Long, Long> {
        val z = days + 719_468
        val era = Math.floorDiv(z, 146_097L)
        val dayOfEra = z - era * 146_097
        val yearOfEra = (dayOfEra - dayOfEra / 1_460 + dayOfEra / 36_524 - dayOfEra / 146_096) / 365
        val dayOfYear = dayOfEra - (365 * yearOfEra + yearOfEra / 4 - yearOfEra / 100)
        val monthIndex = (5 * dayOfYear + 2) / 153
        val day = dayOfYear - (153 * monthIndex + 2) / 5 + 1
        val month = if (monthIndex < 10) monthIndex + 3 else monthIndex - 9
        val year = yearOfEra + era * 400 + if (month <= 2) 1 else 0
        return Triple(year, month, day)
    }

    private fun daysIn(month: Long, year: Long): Long = when (month) {
        2L -> if ((year % 4 == 0L && year % 100 != 0L) || year % 400 == 0L) 29 else 28
        4L, 6L, 9L, 11L -> 30
        else -> 31
    }

    private fun pad(value: Long, width: Int): String {
        val digits = value.toString()
        return if (digits.length >= width) digits else "0".repeat(width - digits.length) + digits
    }

    // endregion

    /** Minimal ASCII scanner. */
    private class Scanner(private val bytes: ByteArray) {
        private var index = 0

        val isAtEnd: Boolean get() = index == bytes.size

        fun skip(char: Char): Boolean {
            if (index >= bytes.size || bytes[index] != char.code.toByte()) return false
            index += 1
            return true
        }

        /** Exactly [digits] ASCII digits. */
        fun number(digits: Int): Long? {
            if (index + digits > bytes.size) return null
            var value = 0L
            for (offset in 0 until digits) {
                val byte = bytes[index + offset]
                if (byte < '0'.code.toByte() || byte > '9'.code.toByte()) return null
                value = value * 10 + (byte - '0'.code.toByte())
            }
            index += digits
            return value
        }

        /** One or more digits after the decimal point, as microseconds (rounded half up beyond 6 digits). */
        fun fraction(): Long? {
            var micros = 0L
            var count = 0
            var roundUp = false
            while (index < bytes.size && bytes[index] >= '0'.code.toByte() && bytes[index] <= '9'.code.toByte()) {
                val digit = (bytes[index] - '0'.code.toByte()).toLong()
                if (count < 6) {
                    micros = micros * 10 + digit
                } else if (count == 6) {
                    roundUp = digit >= 5
                }
                count += 1
                index += 1
            }
            if (count == 0) return null
            for (unused in count until 6) {
                micros *= 10
            }
            return if (roundUp) micros + 1 else micros
        }

        fun sign(): Long? = when {
            skip('+') -> 1
            skip('-') -> -1
            else -> null
        }
    }
}
