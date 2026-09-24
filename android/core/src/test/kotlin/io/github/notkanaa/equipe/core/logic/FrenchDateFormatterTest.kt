package io.github.notkanaa.equipe.core.logic

import io.github.notkanaa.equipe.core.AppCalendar
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Test
import java.time.DayOfWeek
import java.time.Duration
import java.time.LocalDate
import java.time.Month
import java.time.ZoneId
import java.time.format.TextStyle
import java.util.Locale
import io.github.notkanaa.equipe.core.logic.LogicFixtures as F

/** Port of Logic/FrenchDateFormatterTests.swift. */
class FrenchDateFormatterTest {
    private val formatter = FrenchDateFormatter(F.paris)

    @Test
    fun frenchCalendarStartsWeeksOnMonday() {
        val calendar = AppCalendar.frenchGregorian(F.paris)
        assertEquals(DayOfWeek.MONDAY, calendar.weekFields.firstDayOfWeek)
        assertEquals(4, calendar.weekFields.minimalDaysInFirstWeek)
        assertEquals(F.paris, calendar.zone)
        assertEquals(calendar, formatter.calendar)
        assertEquals(formatter, FrenchDateFormatter.of(calendar))
    }

    @Test
    fun timeIsZeroPadded24Hour() {
        assertEquals("08:05", formatter.time(F.date(2026, 9, 24, 8, 5)))
        assertEquals("20:00", formatter.time(F.date(2026, 9, 24, 20, 0)))
        assertEquals("00:00", formatter.time(F.date(2026, 9, 24, 0, 0)))
        assertEquals("23:59", formatter.time(F.date(2026, 9, 24, 23, 59)))
    }

    @Test
    fun timeUsesTheInjectedTimeZone() {
        val utc = FrenchDateFormatter(ZoneId.of("UTC"))
        val date = F.date(2026, 7, 1, 20, 0) // 18:00 UTC (CEST = UTC+2)
        assertEquals("18:00", utc.time(date))
        assertEquals("20:00", formatter.time(date))
    }

    @Test
    fun fullDayNames() {
        assertEquals("jeudi 24 septembre", formatter.day(F.date(2026, 9, 24), includeYear = false))
        assertEquals("mardi 1er septembre", formatter.day(F.date(2026, 9, 1), includeYear = false))
        assertEquals("vendredi 1er janvier 2027", formatter.day(F.date(2027, 1, 1), includeYear = true))
        assertEquals("dimanche 16 août", formatter.day(F.date(2026, 8, 16), includeYear = false))
        assertEquals("lundi 2 février", formatter.day(F.date(2026, 2, 2), includeYear = false))
        assertEquals("samedi 12 décembre", formatter.day(F.date(2026, 12, 12), includeYear = false))
    }

    @Test
    fun relativeWording() {
        val reference = F.date(2026, 9, 24, 10, 0)
        assertEquals("aujourd’hui à 20:00", formatter.relativeDateTime(F.date(2026, 9, 24, 20, 0), reference))
        assertEquals("demain à 08:30", formatter.relativeDateTime(F.date(2026, 9, 25, 8, 30), reference))
        assertEquals("hier à 23:59", formatter.relativeDateTime(F.date(2026, 9, 23, 23, 59), reference))
        assertEquals("lundi à 09:00", formatter.relativeDateTime(F.date(2026, 9, 28, 9, 0), reference))
        assertEquals(
            "vendredi 1er janvier 2027 à 10:00",
            formatter.relativeDateTime(F.date(2027, 1, 1, 10, 0), reference),
        )
        assertEquals(
            "dimanche 20 septembre à 10:00",
            formatter.relativeDateTime(F.date(2026, 9, 20, 10, 0), reference),
        )
    }

    /** 2 to 6 days ahead: the weekday alone; from 7 days ahead and for past days: the full day (review UX-04). */
    @Test
    fun nextDaysShowTheWeekdayOnly() {
        val reference = F.date(2026, 9, 24, 10, 0) // Thursday
        assertEquals("samedi", formatter.relativeDay(F.date(2026, 9, 26, 9, 0), reference))
        assertEquals("dimanche", formatter.relativeDay(F.date(2026, 9, 27, 9, 0), reference))
        assertEquals("mercredi", formatter.relativeDay(F.date(2026, 9, 30, 23, 59), reference))
        assertEquals("jeudi 1er octobre", formatter.relativeDay(F.date(2026, 10, 1, 0, 0), reference))
        assertEquals("mardi 22 septembre", formatter.relativeDay(F.date(2026, 9, 22, 9, 0), reference))
        // Across the new year, the weekday alone as well (no year needed within the week).
        val newYearsEve = F.date(2026, 12, 30, 10, 0)
        assertEquals("samedi à 18:00", formatter.relativeDateTime(F.date(2027, 1, 2, 18, 0), newYearsEve))
        assertEquals(
            "mercredi 6 janvier 2027 à 18:00",
            formatter.relativeDateTime(F.date(2027, 1, 6, 18, 0), newYearsEve),
        )
    }

    /** In the middle of a sentence: « Créée par Lucas Bernard le lundi 14 septembre à 10:00 » (review UX-03). */
    @Test
    fun relativeWordingInASentence() {
        val reference = F.date(2026, 9, 24, 10, 0)
        assertEquals("aujourd’hui à 09:00", formatter.relativeDateTimeInSentence(F.date(2026, 9, 24, 9, 0), reference))
        assertEquals("hier à 23:59", formatter.relativeDateTimeInSentence(F.date(2026, 9, 23, 23, 59), reference))
        assertEquals("demain à 08:30", formatter.relativeDateTimeInSentence(F.date(2026, 9, 25, 8, 30), reference))
        assertEquals(
            "le mardi 22 septembre à 10:00",
            formatter.relativeDateTimeInSentence(F.date(2026, 9, 22, 10, 0), reference),
        )
        assertEquals(
            "le lundi 14 septembre à 10:00",
            formatter.relativeDateTimeInSentence(F.date(2026, 9, 14, 10, 0), reference),
        )
        assertEquals(
            "le lundi 28 septembre à 09:00",
            formatter.relativeDateTimeInSentence(F.date(2026, 9, 28, 9, 0), reference),
        )
        assertEquals(
            "le mercredi 31 décembre 2025 à 10:00",
            formatter.relativeDateTimeInSentence(F.date(2025, 12, 31, 10, 0), reference),
        )
    }

    @Test
    fun midnightBoundaries() {
        val reference = F.date(2026, 9, 24, 23, 59, 59)
        assertEquals("demain", formatter.relativeDay(F.date(2026, 9, 25, 0, 0), reference))
        assertEquals("aujourd’hui", formatter.relativeDay(F.date(2026, 9, 24, 0, 0), reference))
    }

    @Test
    fun dayOffsetAcrossDaylightSavingTransitions() {
        // Spring forward: Sunday 29 March 2026 has 23 hours in Paris.
        val saturdayNight = F.date(2026, 3, 28, 23, 30)
        assertEquals(1, formatter.dayOffset(F.date(2026, 3, 29, 23, 30), saturdayNight))
        assertEquals(2, formatter.dayOffset(F.date(2026, 3, 30, 0, 30), saturdayNight))
        // Fall back: Sunday 25 October 2026 has 25 hours in Paris.
        val sundayEarly = F.date(2026, 10, 25, 0, 30)
        val sundayLate = sundayEarly.plus(Duration.ofHours(24)) // 23:30 the same day
        assertEquals("23:30", formatter.time(sundayLate))
        assertEquals("aujourd’hui", formatter.relativeDay(sundayLate, sundayEarly))
        assertEquals("demain à 09:00", formatter.relativeDateTime(F.date(2026, 10, 26, 9, 0), sundayEarly))
    }

    /**
     * Zones whose spring-forward transition skips midnight (Azores, Chile…): the day starts at 01:00, so the next day
     * starts only 23 hours later; the offset must still count calendar days.
     */
    @Test
    fun dayOffsetOnDaysWhoseMidnightIsSkippedInTheAzores() {
        checkDayWhoseMidnightIsSkipped("Atlantic/Azores")
    }

    @Test
    fun dayOffsetOnDaysWhoseMidnightIsSkippedInChile() {
        checkDayWhoseMidnightIsSkipped("America/Santiago")
    }

    private fun checkDayWhoseMidnightIsSkipped(zoneId: String) {
        val zone = ZoneId.of(zoneId)
        val formatter = FrenchDateFormatter(zone)
        val firstDay = LocalDate.of(2026, 1, 1)
        val transition = (0L until 366L).map { firstDay.plusDays(it) }.firstOrNull { it.atStartOfDay(zone).hour != 0 }
        assertNotNull("no skipped midnight in 2026 for $zoneId", transition)
        val noon = transition!!.atTime(12, 0).atZone(zone)
        val ten = transition.atTime(10, 0).atZone(zone)
        val tomorrow = ten.plusDays(1).toInstant()
        val inTwoDays = ten.plusDays(2).toInstant()
        val yesterday = ten.minusDays(1).toInstant()
        assertEquals(1, formatter.dayOffset(tomorrow, noon.toInstant()))
        assertEquals(2, formatter.dayOffset(inTwoDays, noon.toInstant()))
        assertEquals(-1, formatter.dayOffset(yesterday, noon.toInstant()))
        assertEquals(-1, formatter.dayOffset(noon.toInstant(), tomorrow))
        assertEquals("demain à 10:00", formatter.relativeDateTime(tomorrow, noon.toInstant()))
        assertEquals("aujourd’hui à 10:00", formatter.relativeDateTime(ten.toInstant(), noon.toInstant()))
    }

    @Test
    fun capitalizesFirstLetter() {
        assertEquals("Aujourd’hui à 20:00", FrenchDateFormatter.capitalizingFirstLetter("aujourd’hui à 20:00"))
        assertEquals("École", FrenchDateFormatter.capitalizingFirstLetter("école"))
        assertEquals("", FrenchDateFormatter.capitalizingFirstLetter(""))
    }

    /** The hand-written names (identical to the iOS app's whatever the locale data) are java.time's French names. */
    @Test
    fun namesAreTheFrenchNamesOfJavaTime() {
        val weekdays = listOf(DayOfWeek.SUNDAY) + DayOfWeek.values().filter { it != DayOfWeek.SUNDAY }
        assertEquals(weekdays.map { it.getDisplayName(TextStyle.FULL, Locale.FRENCH) }, FrenchDateFormatter.WEEKDAY_NAMES)
        assertEquals(Month.values().map { it.getDisplayName(TextStyle.FULL, Locale.FRENCH) }, FrenchDateFormatter.MONTH_NAMES)
    }
}
