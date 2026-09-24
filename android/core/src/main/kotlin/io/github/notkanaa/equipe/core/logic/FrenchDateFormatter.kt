package io.github.notkanaa.equipe.core.logic

import io.github.notkanaa.equipe.core.AppCalendar
import java.time.Instant
import java.time.ZoneId
import java.time.temporal.ChronoUnit

// Port of TeamTasksCore/Logic/FrenchDateFormatter.swift.

/**
 * French wording of dates and times ("aujourd’hui à 20:00", "mardi 1er septembre 2027").
 *
 * Written by hand with java.time instead of relying on `DateTimeFormatter` patterns, so the output is identical to the
 * iOS app's whatever the platform's locale data (no narrow no-break spaces, no locale surprises); the day and month
 * names are those of java.time for `Locale.FRENCH` (checked by the tests). Only the time zone is configurable; the
 * calendar is always Gregorian (ISO chronology). Days are compared as calendar dates of [zone], so every wording is
 * correct across daylight-saving transitions (Europe/Paris, and zones whose midnight is skipped).
 */
data class FrenchDateFormatter(val zone: ZoneId) {
    /** The French Gregorian calendar in [zone], used for every computation. */
    val calendar: AppCalendar get() = AppCalendar.frenchGregorian(zone)

    /** 24-hour wall-clock time, e.g. `08:05`, `20:00`. */
    fun time(date: Instant): String {
        val local = date.atZone(zone)
        return "${twoDigits(local.hour)}:${twoDigits(local.minute)}"
    }

    /**
     * Full day, e.g. `jeudi 24 septembre`, `mardi 1er septembre`.
     * The year is appended (`vendredi 1er janvier 2027`) when [includeYear] is true.
     */
    fun day(date: Instant, includeYear: Boolean): String {
        val local = date.atZone(zone).toLocalDate()
        val weekday = WEEKDAY_NAMES[local.dayOfWeek.value % 7]
        val dayText = if (local.dayOfMonth == 1) "1er" else local.dayOfMonth.toString()
        val month = MONTH_NAMES[local.monthValue - 1]
        val text = "$weekday $dayText $month"
        return if (includeYear) "$text ${local.year}" else text
    }

    /**
     * Number of calendar days from [reference]'s day to [date]'s day (0 = same day, 1 = tomorrow, -1 = yesterday).
     * Correct across daylight-saving transitions, including those that skip midnight (Azores, Chile…): the days are
     * compared as calendar dates, never as instants of the local time zone.
     */
    fun dayOffset(date: Instant, reference: Instant): Int {
        val start = reference.atZone(zone).toLocalDate()
        val end = date.atZone(zone).toLocalDate()
        return ChronoUnit.DAYS.between(start, end).toInt()
    }

    /**
     * Day relative to [reference]: `aujourd’hui`, `demain`, `hier`, the weekday alone for the next days (`dimanche`,
     * 2 to 6 days ahead), otherwise the full day (with the year when it differs from the reference's year). Lowercase,
     * to be embedded in a sentence.
     */
    fun relativeDay(date: Instant, reference: Instant): String = when (dayOffset(date, reference)) {
        0 -> "aujourd’hui"
        1 -> "demain"
        -1 -> "hier"
        in 2..6 -> weekdayName(date)
        else -> fullDay(date, reference)
    }

    /**
     * Day and time relative to [reference], e.g. `aujourd’hui à 20:00`, `demain à 08:30`, `lundi à 09:00` (2 to 6 days
     * ahead), `jeudi 1er octobre à 09:00`, `vendredi 1er janvier 2027 à 10:00`. Lowercase.
     */
    fun relativeDateTime(date: Instant, reference: Instant): String =
        "${relativeDay(date, reference)} à ${time(date)}"

    /**
     * Day and time for the middle of a sentence: `aujourd’hui à 09:00`, `hier à 10:00`, `demain à 08:30`, otherwise
     * `le lundi 14 septembre à 10:00` (with the year when it differs from the reference's year), as in « Créée par
     * Lucas Bernard le lundi 14 septembre à 10:00 ». Lowercase.
     */
    fun relativeDateTimeInSentence(date: Instant, reference: Instant): String =
        if (dayOffset(date, reference) in -1..1) {
            relativeDateTime(date, reference)
        } else {
            "le ${fullDay(date, reference)} à ${time(date)}"
        }

    /** Weekday name alone, e.g. `dimanche`. */
    private fun weekdayName(date: Instant): String = WEEKDAY_NAMES[date.atZone(zone).dayOfWeek.value % 7]

    /** Full day, with the year when it differs from [reference]'s year. */
    private fun fullDay(date: Instant, reference: Instant): String {
        val sameYear = date.atZone(zone).year == reference.atZone(zone).year
        return day(date, includeYear = !sameYear)
    }

    companion object {
        /** Weekday names, Sunday first (index = Swift `Calendar.Component.weekday - 1`, or `DayOfWeek.value % 7`). */
        val WEEKDAY_NAMES: List<String> = listOf("dimanche", "lundi", "mardi", "mercredi", "jeudi", "vendredi", "samedi")

        /** Month names indexed by `month - 1`. */
        val MONTH_NAMES: List<String> = listOf(
            "janvier", "février", "mars", "avril", "mai", "juin",
            "juillet", "août", "septembre", "octobre", "novembre", "décembre",
        )

        /** The formatter of [calendar]'s time zone. */
        fun of(calendar: AppCalendar): FrenchDateFormatter = FrenchDateFormatter(calendar.zone)

        /**
         * Uppercases the first character, for strings starting a sentence or a label
         * (`aujourd’hui à 20:00` → `Aujourd’hui à 20:00`).
         */
        fun capitalizingFirstLetter(text: String): String {
            if (text.isEmpty()) return text
            val firstLength = Character.charCount(text.codePointAt(0))
            return text.substring(0, firstLength).uppercase() + text.substring(firstLength)
        }

        private fun twoDigits(value: Int): String = if (value in 0..9) "0$value" else value.toString()
    }
}
