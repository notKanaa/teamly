package io.github.notkanaa.equipe.core.logic

import io.github.notkanaa.equipe.core.AppCalendar
import io.github.notkanaa.equipe.core.KeyValueStore
import io.github.notkanaa.equipe.core.setValue
import io.github.notkanaa.equipe.core.value
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import java.time.Duration
import java.time.Instant

// Port of TeamTasksCore/Logic/ReminderLeadTime.swift.

/**
 * How long before a task's due date its reminder fires (Réglages › Rappels). Persisted in [KeyValueStore] under
 * [STORAGE_KEY] as a JSON string of [rawValue] (e.g. `"oneHour"`), like the iOS app.
 */
@Serializable
enum class ReminderLeadTime(val rawValue: String, val label: String) {
    @SerialName("atDueTime")
    AT_DUE_TIME("atDueTime", "À l’heure de l’échéance"),

    @SerialName("fifteenMinutes")
    FIFTEEN_MINUTES("fifteenMinutes", "15 minutes avant"),

    @SerialName("oneHour")
    ONE_HOUR("oneHour", "1 heure avant"),

    @SerialName("oneDay")
    ONE_DAY("oneDay", "1 jour avant"),

    /** No due-date reminders. */
    @SerialName("off")
    OFF("off", "Aucun rappel"),
    ;

    val id: String get() = rawValue

    val isEnabled: Boolean get() = this != OFF

    /**
     * When the reminder of a task due at [dueAt] fires, or null when reminders are off.
     * "1 jour avant" is one calendar day earlier at the same wall-clock time (23 or 25 hours across a daylight-saving
     * transition), per [calendar]'s time zone.
     */
    fun fireDate(dueAt: Instant, calendar: AppCalendar): Instant? = when (this) {
        AT_DUE_TIME -> dueAt
        FIFTEEN_MINUTES -> dueAt.minus(Duration.ofMinutes(15))
        ONE_HOUR -> dueAt.minus(Duration.ofHours(1))
        ONE_DAY -> dueAt.atZone(calendar.zone).minusDays(1).toInstant()
        OFF -> null
    }

    fun save(store: KeyValueStore) {
        store.setValue(STORAGE_KEY, this)
    }

    companion object {
        /** Default when nothing is stored: 1 hour before. */
        val DEFAULT: ReminderLeadTime = ONE_HOUR

        /** [KeyValueStore] key. */
        const val STORAGE_KEY: String = "settings.reminderLeadTime"

        /** The lead time whose raw value is [rawValue], or null. */
        fun fromRawValue(rawValue: String): ReminderLeadTime? = entries.firstOrNull { it.rawValue == rawValue }

        /** Stored value, or [DEFAULT] when missing or unreadable. */
        fun load(store: KeyValueStore): ReminderLeadTime = store.value<ReminderLeadTime>(STORAGE_KEY) ?: DEFAULT
    }
}
