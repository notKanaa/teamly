package io.github.notkanaa.equipe.supabase

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.long
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Test
import java.time.Instant
import kotlin.random.Random

/** `timestamptz` parsing (0 to 6 fractional digits, any offset) and formatting (UTC, 6 digits): §4.3. */
class TimestampTest {
    private val cases: JsonObject = Json.parseToJsonElement(Fixture.text("timestamps")).jsonObject

    @Test
    fun parsesExactMicroseconds() {
        val valid = cases.getValue("valid").jsonArray
        assertEquals(16, valid.size)
        for (example in valid.map { it.jsonObject }) {
            val text = example.getValue("text").jsonPrimitive.content
            val instant = PostgresTimestamp.parse(text)
            assertNotNull(text, instant)
            instant!!
            assertEquals(text, example.getValue("epochMicroseconds").jsonPrimitive.long, PostgresTimestamp.epochMicroseconds(instant))
            assertEquals(text, example.getValue("formatted").jsonPrimitive.content, PostgresTimestamp.format(instant))
        }
    }

    @Test
    fun rejectsMalformedTimestamps() {
        val invalid = cases.getValue("invalid").jsonArray.map { it.jsonPrimitive.content }
        assertEquals(12, invalid.size)
        for (text in invalid) {
            assertNull(text, PostgresTimestamp.parse(text))
        }
    }

    @Test
    fun formatsWholeSecondsWithSixDigits() {
        assertEquals("1970-01-01T00:00:00.000000Z", PostgresTimestamp.format(Instant.EPOCH))
        // The contract scenarios' Fixed.dueA and Fixed.dueB.
        assertEquals("2031-01-01T00:00:00.000000Z", PostgresTimestamp.format(Instant.ofEpochSecond(1_924_992_000)))
        assertEquals("2031-03-01T00:30:00.000000Z", PostgresTimestamp.format(Instant.ofEpochSecond(1_930_091_400)))
    }

    @Test
    fun wholeSecondDatesRoundTripExactly() {
        assertEquals(Instant.ofEpochSecond(1_924_992_000), PostgresTimestamp.parse("2031-01-01T00:00:00+00:00"))
    }

    @Test
    fun roundsToTheNearestMicrosecond() {
        assertEquals("2026-09-13T23:52:26.123457Z", PostgresTimestamp.format(Instant.ofEpochSecond(1_789_343_546, 123_456_600)))
        assertEquals("2026-09-13T23:52:26.123456Z", PostgresTimestamp.format(Instant.ofEpochSecond(1_789_343_546, 123_456_499)))
        assertEquals("2026-09-13T23:52:27.000000Z", PostgresTimestamp.format(Instant.ofEpochSecond(1_789_343_546, 999_999_500)))
    }

    /** A timestamp read from the server and sent back as a filter designates the same instant (`assignments(since)`). */
    @Test
    fun microsecondsSurviveARoundTrip() {
        val random = Random(2026)
        repeat(2_000) {
            // 1970 … 2100
            val micros = random.nextLong(0, 4_102_444_800_000_000)
            val text = PostgresTimestamp.format(PostgresTimestamp.instant(micros))
            val parsed = PostgresTimestamp.parse(text)!!
            assertEquals(text, micros, PostgresTimestamp.epochMicroseconds(parsed))
            assertEquals(text, PostgresTimestamp.format(parsed))
        }
    }

    @Test
    fun decoderAcceptsEveryPrecision() {
        val row = RestDecoding.decode(Fixture.bytes("task_fractional_digits")) { TaskRow.decode(it.asObject("task")) }
        assertEquals("2026-09-24T00:24:04.300000Z", PostgresTimestamp.format(row.createdAt))
        assertEquals("2026-09-24T00:24:04.385320Z", PostgresTimestamp.format(row.updatedAt))
        assertEquals("2026-09-24T00:24:04.385321Z", row.completedAt?.let(PostgresTimestamp::format))
        assertEquals(Instant.ofEpochSecond(1_930_134_600), row.dueAt)
        assertNull(row.createdBy)
    }

    @Test
    fun extremeInstantsAreClampedToFourDigitYears() {
        assertEquals("9999-12-31T23:59:59.999999Z", PostgresTimestamp.format(Instant.MAX))
        assertEquals("0001-01-01T00:00:00.000000Z", PostgresTimestamp.format(Instant.MIN))
    }
}
