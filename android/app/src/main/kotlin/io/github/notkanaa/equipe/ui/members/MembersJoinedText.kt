package io.github.notkanaa.equipe.ui.members

import io.github.notkanaa.equipe.core.AppCalendar
import io.github.notkanaa.equipe.core.logic.FrenchDateFormatter
import java.time.Instant

// Port of App/Sources/Features/Members/MembersJoinedText.swift.

/**
 * « Membre depuis le 14 septembre » under a member's name: the day only (the time of joining does not matter), with
 * its article, short enough for one caption line.
 */
internal object MembersJoinedText {
    /**
     * « Membre depuis aujourd’hui », « … hier », « … le 14 septembre », « … le 1er décembre 2025 » (the year when it
     * is not the current one).
     */
    fun sentence(joinedAt: Instant, now: Instant, calendar: AppCalendar): String =
        "Membre depuis ${day(joinedAt, now, calendar)}"

    private fun day(date: Instant, now: Instant, calendar: AppCalendar): String {
        val formatter = FrenchDateFormatter.of(calendar)
        val offset = formatter.dayOffset(date, now)
        return when {
            // Today, or « tomorrow » from a clock set late: never « depuis demain ».
            offset >= 0 -> "aujourd’hui"
            offset == -1 -> "hier"
            else -> {
                val day = calendar.localDate(date)
                val dayNumber = if (day.dayOfMonth == 1) "1er" else day.dayOfMonth.toString()
                val month = FrenchDateFormatter.MONTH_NAMES[day.monthValue - 1]
                val text = "le $dayNumber $month"
                if (day.year != calendar.localDate(now).year) "$text ${day.year}" else text
            }
        }
    }
}
