package io.github.notkanaa.equipe.core.logic

import io.github.notkanaa.equipe.core.AppCalendar
import io.github.notkanaa.equipe.core.TaskItem
import io.github.notkanaa.equipe.core.TaskStatus
import java.time.DayOfWeek
import java.time.Instant

// Port of TeamTasksCore/Logic/DueBucket.swift.

/** Due-date section of a task list ("Mes tâches"), in display order (the natural enum order). */
enum class DueBucket(val title: String) {
    /** Not done, due strictly before now. */
    OVERDUE("En retard"),

    /** Not done, due from now until the end of today. */
    TODAY("Aujourd’hui"),

    /** Not done, due after today and before the start of next week (per the first day of the week). */
    THIS_WEEK("Cette semaine"),

    /** Not done, due from the start of next week on. */
    LATER("Plus tard"),

    /** Not done, without due date. */
    NO_DUE_DATE("Sans échéance"),

    /** Done tasks, whatever their due date. */
    DONE("Terminées"),
    ;

    /** Swift raw value (display rank). */
    val rawValue: Int get() = ordinal

    val id: Int get() = ordinal

    companion object {
        /**
         * Bucket of one task. Build a [DueBucketBoundaries] once when classifying many tasks.
         * @param firstDayOfWeek defaults to the calendar's (Monday with French conventions).
         */
        fun bucket(
            task: TaskItem,
            now: Instant,
            calendar: AppCalendar,
            firstDayOfWeek: DayOfWeek = calendar.weekFields.firstDayOfWeek,
        ): DueBucket = DueBucketBoundaries(now, calendar, firstDayOfWeek).bucket(task)

        /**
         * Groups tasks into ordered, non-empty sections.
         * @param sort order inside the not-done sections (default: due date, then priority, then title).
         *   The "Terminées" section lists the most recently completed first, then follows [sort].
         */
        fun sections(
            tasks: List<TaskItem>,
            now: Instant,
            calendar: AppCalendar,
            sort: TaskSort = TaskSort.DUE_DATE,
            firstDayOfWeek: DayOfWeek = calendar.weekFields.firstDayOfWeek,
        ): List<DueSection> = DueBucketBoundaries(now, calendar, firstDayOfWeek).sections(tasks, sort)
    }
}

/** A non-empty section of tasks sharing a [DueBucket]. */
data class DueSection(
    val bucket: DueBucket,
    val tasks: List<TaskItem>,
) {
    val id: DueBucket get() = bucket
    val title: String get() = bucket.title
}

/**
 * Day boundaries used to classify due dates, computed once from [now] and the injected calendar (time zone) and first
 * day of the week. Correct across daylight-saving transitions: boundaries are calendar midnights (the first instant of
 * the day when midnight is skipped), not multiples of 24 hours.
 *
 * @param firstDayOfWeek defaults to the calendar's (Monday with French conventions); Swift reads it from the injected
 *   `Calendar.firstWeekday`.
 */
class DueBucketBoundaries(
    val now: Instant,
    calendar: AppCalendar,
    firstDayOfWeek: DayOfWeek = calendar.weekFields.firstDayOfWeek,
) {
    /** First instant of today. */
    val startOfToday: Instant

    /** First instant of tomorrow (end of the "Aujourd’hui" bucket). */
    val startOfTomorrow: Instant

    /**
     * First instant of next week (end of the "Cette semaine" bucket). Equals [startOfTomorrow] on the last day of the
     * week (Sunday with French conventions), making "Cette semaine" empty.
     */
    val startOfNextWeek: Instant

    init {
        val today = calendar.localDate(now)
        startOfToday = calendar.startOfDay(today)
        val daysSinceWeekStart = Math.floorMod(today.dayOfWeek.value - firstDayOfWeek.value, 7)
        startOfTomorrow = calendar.startOfDay(today.plusDays(1))
        startOfNextWeek = calendar.startOfDay(today.plusDays((7 - daysSinceWeekStart).toLong()))
    }

    fun bucket(task: TaskItem): DueBucket {
        if (task.status == TaskStatus.DONE) return DueBucket.DONE
        val dueAt = task.dueAt ?: return DueBucket.NO_DUE_DATE
        return when {
            dueAt < now -> DueBucket.OVERDUE
            dueAt < startOfTomorrow -> DueBucket.TODAY
            dueAt < startOfNextWeek -> DueBucket.THIS_WEEK
            else -> DueBucket.LATER
        }
    }

    /** See [DueBucket.sections]. */
    fun sections(tasks: List<TaskItem>, sort: TaskSort = TaskSort.DUE_DATE): List<DueSection> {
        val grouped = HashMap<DueBucket, MutableList<TaskItem>>()
        for (task in tasks) {
            grouped.getOrPut(bucket(task)) { ArrayList() }.add(task)
        }
        return DueBucket.entries.mapNotNull { bucket ->
            val bucketTasks = grouped[bucket]
            if (bucketTasks.isNullOrEmpty()) return@mapNotNull null
            val ordered = if (bucket == DueBucket.DONE) sortDone(bucketTasks, sort) else sort.sorted(bucketTasks)
            DueSection(bucket, ordered)
        }
    }

    override fun equals(other: Any?): Boolean =
        other is DueBucketBoundaries && now == other.now && startOfToday == other.startOfToday &&
            startOfTomorrow == other.startOfTomorrow && startOfNextWeek == other.startOfNextWeek

    override fun hashCode(): Int {
        var result = now.hashCode()
        result = 31 * result + startOfToday.hashCode()
        result = 31 * result + startOfTomorrow.hashCode()
        result = 31 * result + startOfNextWeek.hashCode()
        return result
    }

    override fun toString(): String =
        "DueBucketBoundaries(now=$now, startOfToday=$startOfToday, startOfTomorrow=$startOfTomorrow, " +
            "startOfNextWeek=$startOfNextWeek)"

    private companion object {
        /** Most recently completed first (unknown completion date last), ties broken by [sort] (stable sort). */
        fun sortDone(tasks: List<TaskItem>, sort: TaskSort): List<TaskItem> =
            sort.sorted(tasks).sortedWith { lhs, rhs ->
                val left = lhs.completedAt
                val right = rhs.completedAt
                when {
                    left != null && right != null -> right.compareTo(left)
                    left != null -> -1
                    right != null -> 1
                    else -> 0
                }
            }
    }
}
